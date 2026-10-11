"""Lógica del servicio, independiente de HTTP: embeddings, similitud, indexado y búsqueda."""

from __future__ import annotations

import time
from pathlib import Path
from typing import Any

import numpy as np

from .config import MODEL_ALIAS, Config
from .files import classify
from .access import local_file_path
from .indexer import Indexer, Job, wait_for
from .inputs import (
    InputError,
    item_modality,
    make_items,
    validate_dim,
    validate_soft_tokens,
)
from .store import Catalog, Hit, is_under, path_key
from .vectors import cosine_matrix, truncate_normalize

VIDEO_OVERFLOW = ("uniform", "truncate")


def encode_options(
    image_tokens: int | None = None,
    video_tokens: int | None = None,
    video_fps: float | None = None,
    video_max_frames: int | None = None,
    video_overflow: str | None = None,
    video_timestamps: bool = False,
) -> dict:
    if video_fps is not None and not 0 < video_fps <= 30:
        raise InputError("video_fps debe estar entre 0 y 30")
    if video_max_frames is not None and not 1 <= video_max_frames <= 114:
        raise InputError("video_max_frames debe estar entre 1 y 114")
    if video_overflow is not None and video_overflow not in VIDEO_OVERFLOW:
        raise InputError(f"video_overflow debe ser {VIDEO_OVERFLOW}")
    return {
        "image_tokens": validate_soft_tokens(image_tokens, "image_tokens"),
        "video_tokens": validate_soft_tokens(video_tokens, "video_tokens"),
        "video_fps": video_fps,
        "video_max_frames": video_max_frames,
        "video_overflow": video_overflow,
        "video_timestamps": bool(video_timestamps),
    }


class Service:
    def __init__(self, cfg: Config, engine: Any, catalog: Catalog | None = None):
        self.cfg = cfg
        self.engine = engine
        self.catalog = catalog or Catalog(cfg.data_path, cfg.model)
        self.indexer = Indexer(cfg, self.catalog, engine.encode, engine)
        self.started_at = time.time()
        self._last_refresh: dict[str, float] = {}

    # -- embeddings ------------------------------------------------------------
    def embed(
        self,
        raw_inputs: Any,
        task: str | None = None,
        title: str | None = None,
        dimensions: int | None = None,
        options: dict | None = None,
    ) -> tuple[np.ndarray, int, list[dict]]:
        dim = validate_dim(dimensions)
        items = make_items(raw_inputs, task=task, title=title)
        for item in items:
            for part in item["parts"]:
                source = part.get("src")
                if source and not source.startswith(("https://", "http://", "data:")):
                    local_file_path(source)
        result = self.engine.encode(items, options or {})
        return truncate_normalize(result["vectors"], dim), int(result.get("text_tokens", 0)), items

    def similarity(
        self,
        a: Any,
        b: Any,
        task_a: str | None = None,
        task_b: str | None = None,
        options: dict | None = None,
    ) -> dict:
        va, _, items_a = self.embed(a, task=task_a, options=options)
        vb, _, items_b = self.embed(b, task=task_b, options=options)
        return {
            "scores": np.round(cosine_matrix(va, vb), 4).tolist(),
            "a_modalities": [item_modality(i) for i in items_a],
            "b_modalities": [item_modality(i) for i in items_b],
        }

    # -- indexado ----------------------------------------------------------------
    def index(self, path: str, collection: str | None = None, wait: float = 0) -> Job:
        job = self.indexer.submit(Path(path), collection)
        wait_for(job, wait)
        return job

    def collections(self) -> list[dict]:
        out = []
        for name in self.catalog.names():
            try:
                with self.catalog.open(name) as store:
                    info = store.stats()
            except Exception as exc:  # noqa: BLE001 — una colección rota no tumba el listado
                info = {"name": name, "error": str(exc)}
            running = self.indexer.running_for(name)
            info["indexing"] = running.as_dict() if running else None
            out.append(info)
        return out

    def collection(self, name: str) -> dict:
        with self.catalog.open(name) as store:
            info = store.stats()
            info["recent_errors"] = store.errors()
        return info

    def drop(self, name: str) -> bool:
        if self.indexer.running_for(name):
            raise InputError(f"la colección «{name}» se está indexando; espera o cancela el trabajo")
        return self.catalog.drop(name)

    # -- búsqueda ----------------------------------------------------------------
    def _target_collections(self, collection: str | None, path: str | None) -> list[str]:
        if collection:
            if collection not in self.catalog.names():
                raise InputError(f"no existe la colección «{collection}»")
            return [collection]
        if path:
            found = self.catalog.collection_for_path(Path(path))
            if not found:
                raise InputError(
                    f"«{path}» no está indexado. Indexa la carpeta del proyecto primero (index_path) o pasa refresh"
                )
            return [found]
        names = self.catalog.names()
        if not names:
            raise InputError("no hay nada indexado todavía: usa index_path con la carpeta que quieras buscar")
        return names

    def _refresh(self, path: str | None, collection: str | None, wait: float) -> dict | None:
        """Pone al día el índice antes de buscar (incremental). Devuelve el trabajo si no terminó a tiempo."""
        if not path:
            return None
        target = local_file_path(path, directory=True)
        name = collection or self.catalog.collection_for_path(target)
        root = target
        if name:
            with self.catalog.open(name) as store:
                roots = [Path(r) for r in store.roots()]
            covering = [r for r in roots if is_under(path_key(target), path_key(r))]
            if covering:
                root = max(covering, key=lambda r: len(str(r)))
            last = self._last_refresh.get(path_key(root), 0)
            if time.time() - last < 30:
                return None
        job = self.index(str(root), name, wait=wait)
        self._last_refresh[path_key(root)] = time.time()
        return None if job.done_event.is_set() else job.as_dict()

    def _query_vector(self, query: str | None, file: str | None, task: str | None, kinds: list[str] | None) -> np.ndarray:
        if bool(query) == bool(file):
            raise InputError("pasa «query» (texto) o «file» (ruta de un fichero), uno de los dos")
        if query:
            if task is None:
                task = "code_query" if kinds and set(kinds) <= {"code"} else "query"
            vectors, _, _ = self.embed(query, task=task)
            return vectors[0]
        return self._file_vector(Path(str(file)).expanduser())

    def _file_vector(self, path: Path) -> np.ndarray:
        path = local_file_path(path)
        if not path.is_file():
            raise InputError(f"no existe el fichero «{path}»")
        name = self.catalog.collection_for_path(path)
        if name:
            with self.catalog.open(name) as store:
                stored = store.file_vector(path)
            if stored is not None:
                return stored
        kind = classify(path)
        if kind == "image":
            raw: Any = {"image": str(path)}
        elif kind == "audio":
            raw = {"audio": {"src": str(path), "start": 0, "end": self.cfg.audio_window_s}}
        elif kind == "video":
            raw = {"video": {"src": str(path), "start": 0, "end": self.cfg.video_window_s}}
        elif kind == "pdf":
            raw = {"pdf": {"src": str(path), "page": 1}}
        elif kind in ("code", "doc"):
            from .files import read_text_file
            text = read_text_file(path, self.cfg.max_text_file_kb * 1024)
            if text is None:
                raise InputError("El archivo de consulta supera el tamaño máximo o no es texto")
            text = text[: self.cfg.chunk_max_chars]
            raw = {"text": text, "title": path.name}
            vectors, _, _ = self.embed(raw, task="document")
            return vectors[0]
        else:
            raise InputError(f"no sé leer «{path.name}» como consulta")
        vectors, _, _ = self.embed(raw)
        return vectors[0]

    def search(
        self,
        query: str | None = None,
        file: str | None = None,
        collection: str | None = None,
        path: str | None = None,
        k: int = 10,
        kinds: list[str] | None = None,
        task: str | None = None,
        refresh: bool = False,
        wait: float = 60,
    ) -> dict:
        if not 1 <= k <= 200:
            raise InputError("k debe estar entre 1 y 200")
        pending = self._refresh(path, collection, wait) if refresh else None
        names = self._target_collections(collection, path)
        vector = self._query_vector(query, file, task, kinds)
        hits: list[Hit] = []
        for name in names:
            with self.catalog.open(name) as store:
                hits.extend(
                    store.search(
                        vector,
                        k=k,
                        kinds=kinds,
                        path_prefix=path if path and Path(path).exists() else None,
                        exclude_path=file,
                    )
                )
        hits.sort(key=lambda h: h.score, reverse=True)
        return {
            "collections": names,
            "results": [h.as_dict() for h in hits[:k]],
            "indexing": pending,
        }

    def status(self) -> dict:
        return {
            "status": "ok",
            "model": self.cfg.model,
            "alias": MODEL_ALIAS,
            "uptime_s": round(time.time() - self.started_at),
            "engine": self.engine.status(),
            "config": {
                "host": self.cfg.host,
                "port": self.cfg.port,
                "device": self.cfg.device,
                "dtype": self.cfg.dtype,
                "modalities": self.cfg.modalities,
                "idle_unload_minutes": self.cfg.idle_unload_minutes,
                "data_dir": str(self.cfg.data_path),
            },
            "collections": len(self.catalog.names()),
            "jobs": [j.as_dict() for j in self.indexer.jobs() if j.status in ("queued", "running")],
        }
