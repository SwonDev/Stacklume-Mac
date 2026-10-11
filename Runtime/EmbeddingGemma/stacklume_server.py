"""Frontera de instalación y ciclo de vida de Stacklume; el motor egemma se conserva."""
import hashlib
import json
import os
import signal
import socket
import threading
import time
import sqlite3
from contextlib import asynccontextmanager
from pathlib import Path

os.environ["TOKENIZERS_PARALLELISM"] = "false"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
os.umask(0o077)

REVISION = "1a4ffddb7905d3f63486748deabe091a01fb6201"
MODEL = "mlx-community/embeddinggemma-2-bf16"
home = Path(os.environ["EGEMMA_HOME"]).resolve()
home.mkdir(parents=True, exist_ok=True, mode=0o700)
status_file = home / "status.json"


def state(phase, **values):
    target = status_file.with_suffix(".tmp")
    target.write_text(json.dumps({"phase": phase, **values}, ensure_ascii=False), encoding="utf-8")
    target.replace(status_file)


def verify_snapshot(path):
    for name in ("config.json", "tokenizer_config.json", "tokenizer.json", "preprocessor_config.json", "model.safetensors"):
        if not (path / name).is_file():
            raise FileNotFoundError("La revisión del modelo está incompleta")
    expected = {"model.safetensors": "ffaf2604b011ad0634022529bac930a4f6a2feba22687d8d5890434d186b459c",
                "tokenizer.json": "4d777ef5bdc1aa36227abdfb77c3e49e7b9c892d16e1b6bda41c393504828be4"}
    for name, digest in expected.items():
        with (path / name).open("rb") as file:
            if hashlib.file_digest(file, "sha256").hexdigest() != digest:
                raise ValueError("Los archivos de EmbeddingGemma 2 están dañados")


def download_model():
    from huggingface_hub import snapshot_download
    state("downloading", message="Descargando EmbeddingGemma 2…")
    # Reutiliza una revisión completa existente sin copiar ni modificar sus pesos.
    shared = Path.home() / ".cache/huggingface/hub"
    try:
        path = Path(snapshot_download(MODEL, revision=REVISION, cache_dir=shared, local_files_only=True))
        verify_snapshot(path)
    except Exception:
        os.environ["HF_HUB_CACHE"] = str(home / "models")
        path = Path(snapshot_download(MODEL, revision=REVISION, cache_dir=home / "models"))
        verify_snapshot(path)
    os.environ["HF_HUB_CACHE"] = str(path.parents[2])
    os.environ["HF_HUB_OFFLINE"] = "1"
    return path


def main():
    # Grupo propio: una recuperación forzada solo alcanza este servidor y sus workers.
    if os.getpgrp() != os.getpid():
        os.setsid()
    from egemma.config import Config
    from egemma.server import create_app
    from egemma.service import Service
    from egemma.engine import Engine
    import uvicorn
    import uuid
    from pydantic import BaseModel, Field
    from typing import Literal
    parent = int(os.environ["STACKLUME_PARENT_PID"])
    token = os.environ["STACKLUME_EMBEDDING_TOKEN"]
    # El socket se reserva antes de publicar el puerto: no hay carrera con otras apps.
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    cfg = Config(port=port, data_dir=str(home / "index"), idle_unload_minutes=1)
    engine = Engine(cfg)
    service = Service(cfg, engine)
    app = create_app(cfg, service, api_key=token)
    @asynccontextmanager
    async def lifespan(_app):
        try:
            yield
        finally:
            # Uvicorn reenvía SIGTERM antes de retornar de run(); la limpieza debe
            # ocurrir dentro de lifespan, antes de ese reenvío.
            for job in service.indexer.jobs():
                service.indexer.cancel(job.id)
            engine.close()
    app.router.lifespan_context = lifespan

    @app.post("/stacklume/release")
    def release():
        return {"released": engine.release_memory()}

    def query_vector(request):
        if request.file:
            return service._query_vector(request.query, request.file, request.task, None), False
        import numpy as np
        key = hashlib.sha256(json.dumps([REVISION, request.task, request.query], ensure_ascii=False).encode()).hexdigest()
        database = home / "query-vectors.sqlite"
        with sqlite3.connect(database, timeout=30) as cache:
            cache.execute("PRAGMA journal_mode=WAL")
            cache.execute("CREATE TABLE IF NOT EXISTS queries(key TEXT PRIMARY KEY, vector BLOB NOT NULL, used REAL NOT NULL)")
            found = cache.execute("SELECT vector FROM queries WHERE key=?", (key,)).fetchone()
            if found:
                vector = np.frombuffer(found[0], dtype=np.float32)
                if len(vector) == 768 and np.isfinite(vector).all():
                    cache.execute("UPDATE queries SET used=? WHERE key=?", (time.time(), key))
                    return vector, True
        vector = service._query_vector(request.query, None, request.task, None)
        with sqlite3.connect(database, timeout=30) as cache:
            cache.execute("INSERT OR REPLACE INTO queries VALUES(?,?,?)", (key, vector.astype("float32").tobytes(), time.time()))
            cache.execute("DELETE FROM queries WHERE key NOT IN (SELECT key FROM queries ORDER BY used DESC LIMIT 1024)")
        return vector, False
    class VectorsRequest(BaseModel):
        ids: list[uuid.UUID] = Field(max_length=256)
        task: Literal["document", "classification", "clustering", "similarity"] = "document"

    class SearchRequest(BaseModel):
        query: str | None = Field(None, max_length=16000)
        file: str | None = None
        task: str = "query"
        ids: list[uuid.UUID] | None = Field(None, max_length=50000)
        k: int = Field(100, ge=1, le=200)

    @app.post("/stacklume/search")
    def search(request: SearchRequest):
        from egemma.inputs import InputError
        from egemma.files import classify
        from egemma.store import Hit
        cached = False
        if request.file and request.query:
            from egemma.access import local_file_path
            path = local_file_path(request.file)
            kind = classify(path)
            if kind in ("code", "doc"):
                from egemma.files import read_text_file
                text = read_text_file(path, cfg.max_text_file_kb * 1024)
                if text is None:
                    raise InputError("El archivo no contiene texto legible o es demasiado grande")
                raw = {"text": request.query + "\n" + text[:cfg.chunk_max_chars]}
            else:
                part = {"pdf": {"src": str(path), "page": 1}} if kind == "pdf" else {kind: str(path)}
                raw = {"text": request.query, **part}
            vector = service.embed(raw, task=request.task)[0][0]
        else:
            vector, cached = query_vector(request)
        corpus = home / "corpus"
        prefix = str(corpus) + os.sep
        with service.catalog.open("stacklume-library") as store:
            scope_join = ""
            if request.ids is not None:
                store.conn.execute("CREATE TEMP TABLE scope(id TEXT PRIMARY KEY)")
                store.conn.executemany("INSERT OR IGNORE INTO scope VALUES(?)", [(str(value).upper(),) for value in request.ids])
                scope_join = f" JOIN scope ON scope.id=substr(f.path,{len(prefix)+1},36)"
            rows = store.conn.execute(
                "WITH ranked AS MATERIALIZED (SELECT c.id,f.path,f.kind,c.modality,c.loc_unit,c.loc_start,c.loc_end,c.preview,"
                f"substr(f.path,{len(prefix)+1},36) AS bookmark,vec_distance_cosine(v.embedding,?) AS distance "
                "FROM files f JOIN chunks c ON c.file_id=f.id JOIN vec v ON v.chunk_id=c.id"
                + scope_join + f" WHERE substr(f.path,1,{len(prefix)})=?), winners AS (SELECT *,"
                "ROW_NUMBER() OVER(PARTITION BY bookmark ORDER BY distance) AS rn FROM ranked) "
                "SELECT path,kind,modality,loc_unit,loc_start,loc_end,preview,distance FROM winners "
                "WHERE rn=1 ORDER BY distance LIMIT ?", (vector.astype("float32").tobytes(), prefix, request.k))
            hits = [Hit("stacklume-library", *row[:-1], score=1-float(row[-1])).as_dict() for row in rows]
        return {"results": hits, "query_cached": cached}

    @app.post("/stacklume/vectors")
    def vectors(request: VectorsRequest):
        import numpy as np
        paths = []
        corpus = home / "corpus"
        for value in request.ids:
            folder = corpus / str(value).upper()
            if folder.is_dir():
                paths.extend(str(file) for file in folder.iterdir() if file.is_file())
        grouped = {}
        if paths:
            with service.catalog.open("stacklume-library") as store:
                placeholders = ",".join("?" for _ in paths)
                rows = store.conn.execute(
                    "SELECT f.path,c.modality,v.embedding FROM files f "
                    "JOIN chunks c ON c.file_id=f.id JOIN vec v ON v.chunk_id=c.id "
                    f"WHERE f.key IN ({placeholders})", paths)
                indexed = list(rows)
                if request.task == "document":
                    for path, modality, data in indexed:
                        key = Path(path).parent.name
                        grouped.setdefault(key, {}).setdefault(modality, []).append(np.frombuffer(data, dtype=np.float32))
                else:
                    from egemma.files import Candidate
                    from egemma.inputs import prompt_for
                    store.conn.execute("CREATE TABLE IF NOT EXISTS task_vectors("
                        "file_id INTEGER REFERENCES files(id) ON DELETE CASCADE,task TEXT,stamp REAL,"
                        "modality TEXT,embedding BLOB,PRIMARY KEY(file_id,task,modality))")
                    files = list(store.conn.execute(
                        f"SELECT id,path,kind,size,mtime,indexed_at FROM files WHERE key IN ({placeholders}) AND status='ok'", paths))
                    for file_id, path, kind, size, mtime, stamp in files:
                        cached = list(store.conn.execute(
                            "SELECT modality,embedding FROM task_vectors WHERE file_id=? AND task=? AND stamp=?",
                            (file_id, request.task, stamp)))
                        if not cached:
                            units = service.indexer._plan(Candidate(Path(path), kind, size, mtime, False), corpus)
                            for unit in units:
                                parts = unit.item["parts"]
                                for part in parts:
                                    if part["type"] == "text" and part["text"].startswith("title: "):
                                        part["text"] = part["text"].split(" | text: ", 1)[-1]
                                unit.item["prompt"] = prompt_for(request.task) if any(p["type"] == "text" for p in parts) else None
                            encoded = service.indexer._embed_units(units, kind)
                            by_modality = {}
                            for unit, value in zip(units, encoded):
                                by_modality.setdefault(unit.record.modality, []).append(value)
                            with store.conn:
                                store.conn.execute("DELETE FROM task_vectors WHERE file_id=? AND task=?", (file_id, request.task))
                                for modality, values in by_modality.items():
                                    value = np.mean(values, axis=0).astype(np.float32)
                                    norm = np.linalg.norm(value)
                                    if norm <= 1e-12:
                                        continue
                                    data = (value / norm).tobytes()
                                    store.conn.execute("INSERT INTO task_vectors VALUES(?,?,?,?,?)", (file_id, request.task, stamp, modality, data))
                                    cached.append((modality, data))
                        for modality, data in cached:
                            key = Path(path).parent.name
                            grouped.setdefault(key, {}).setdefault(modality, []).append(np.frombuffer(data, dtype=np.float32))
        output = {}
        for key, modalities in grouped.items():
            means = []
            for values in modalities.values():
                mean = np.mean(values, axis=0)
                norm = np.linalg.norm(mean)
                if norm > 1e-12:
                    means.append(mean / norm)
            if means:
                mean = np.mean(means, axis=0)
                norm = np.linalg.norm(mean)
                if np.isfinite(mean).all() and norm > 1e-12:
                    output[key] = (mean / norm).tolist()
        return {"model": "google/embeddinggemma-2", "revision": REVISION, "embeddings": output}
    server = uvicorn.Server(uvicorn.Config(app, log_level="warning", timeout_graceful_shutdown=2))
    def prepare():
        try:
            download_model()
            state("ready", port=port, revision=REVISION)
        except Exception as error:
            state("failed", message=str(error))
    def watch_parent():
        while not server.should_exit:
            time.sleep(2)
            if os.getppid() != parent:
                engine.close()
                os._exit(0)
    threading.Thread(target=watch_parent, daemon=True).start()
    threading.Thread(target=prepare, daemon=True).start()
    try:
        server.run(sockets=[sock])
    finally:
        engine.close()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        state("failed", message=str(error))
        raise
