"""Índice vectorial por colección: un SQLite con sqlite-vec por colección, fuera de los repos."""

from __future__ import annotations

import hashlib
import os
import re
import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import sqlite_vec

from .config import NATIVE_DIM
from .inputs import InputError
from .paths import is_under, path_key

SCHEMA_VERSION = "1"
_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")


def default_collection_name(root: Path) -> str:
    base = re.sub(r"[^a-z0-9]+", "-", root.name.lower()).strip("-")[:40] or "raiz"
    digest = hashlib.sha1(path_key(root).encode("utf-8")).hexdigest()[:6]
    return f"{base}-{digest}"


def validate_name(name: str) -> str:
    if not _NAME_RE.match(name):
        raise InputError("nombre de colección no válido: minúsculas, números, - y _ (máx. 64)")
    return name


@dataclass
class ChunkRecord:
    modality: str  # text | image | audio | video
    loc_unit: str | None  # lines | s | page | None
    loc_start: float | None
    loc_end: float | None
    preview: str


@dataclass
class Hit:
    collection: str
    path: str
    kind: str
    modality: str
    loc_unit: str | None
    loc_start: float | None
    loc_end: float | None
    preview: str
    score: float

    def as_dict(self) -> dict:
        return {
            "collection": self.collection,
            "path": self.path,
            "kind": self.kind,
            "modality": self.modality,
            "location": format_location(self.loc_unit, self.loc_start, self.loc_end),
            "loc_unit": self.loc_unit,
            "loc_start": self.loc_start,
            "loc_end": self.loc_end,
            "score": round(self.score, 4),
            "preview": self.preview,
        }


def _mmss(seconds: float) -> str:
    total = int(round(seconds))
    h, rest = divmod(total, 3600)
    m, s = divmod(rest, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def format_location(unit: str | None, start: float | None, end: float | None) -> str | None:
    if unit is None or start is None:
        return None
    if unit == "lines":
        return f"líneas {int(start)}-{int(end or start)}"
    if unit == "page":
        return f"página {int(start)}"
    if unit == "s":
        return f"{_mmss(start)}-{_mmss(end if end is not None else start)}"
    return None


class Store:
    def __init__(self, db_path: Path, name: str, model: str = "", dim: int = NATIVE_DIM, create: bool = False):
        self.name = name
        self.db_path = db_path
        self.dim = dim
        if not create and not db_path.exists():
            raise FileNotFoundError(f"no existe la colección «{name}»")
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(db_path, timeout=30, check_same_thread=False)
        self.conn.enable_load_extension(True)
        sqlite_vec.load(self.conn)
        self.conn.enable_load_extension(False)
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA foreign_keys=ON")
        self.conn.execute("PRAGMA busy_timeout=30000")
        self._init_schema(model)

    # -- esquema -------------------------------------------------------------
    def _init_schema(self, model: str) -> None:
        c = self.conn
        c.executescript(
            f"""
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS roots(key TEXT PRIMARY KEY, path TEXT NOT NULL, added_at REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS files(
                id INTEGER PRIMARY KEY,
                key TEXT NOT NULL UNIQUE,
                path TEXT NOT NULL,
                kind TEXT NOT NULL,
                size INTEGER NOT NULL,
                mtime REAL NOT NULL,
                indexed_at REAL NOT NULL,
                status TEXT NOT NULL DEFAULT 'ok',
                error TEXT
            );
            CREATE TABLE IF NOT EXISTS chunks(
                id INTEGER PRIMARY KEY,
                file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                modality TEXT NOT NULL,
                loc_unit TEXT,
                loc_start REAL,
                loc_end REAL,
                preview TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS chunks_file ON chunks(file_id);
            CREATE VIRTUAL TABLE IF NOT EXISTS vec USING vec0(
                chunk_id INTEGER PRIMARY KEY,
                embedding float[{self.dim}] distance_metric=cosine,
                kind TEXT
            );
            """
        )
        existing = dict(c.execute("SELECT key, value FROM meta").fetchall())
        if not existing:
            with c:
                c.executemany(
                    "INSERT INTO meta(key, value) VALUES (?, ?)",
                    [
                        ("schema", SCHEMA_VERSION),
                        ("model", model),
                        ("dim", str(self.dim)),
                        ("created_at", str(time.time())),
                    ],
                )
        elif model and existing.get("model") and existing["model"] != model:
            raise InputError(
                f"la colección «{self.name}» se creó con {existing['model']}; reíndexala para usar {model}"
            )

    def close(self) -> None:
        self.conn.close()

    def __enter__(self) -> "Store":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    # -- raíces y ficheros ---------------------------------------------------
    def add_root(self, path: Path) -> None:
        with self.conn:
            self.conn.execute(
                "INSERT OR IGNORE INTO roots(key, path, added_at) VALUES (?, ?, ?)",
                (path_key(path), str(path), time.time()),
            )

    def roots(self) -> list[str]:
        return [r[0] for r in self.conn.execute("SELECT path FROM roots ORDER BY path")]

    def file_state(self, path: Path) -> tuple[int, int, float, str] | None:
        row = self.conn.execute(
            "SELECT id, size, mtime, status FROM files WHERE key = ?", (path_key(path),)
        ).fetchone()
        return tuple(row) if row else None  # type: ignore[return-value]

    def files_under(self, root: Path) -> dict[str, int]:
        """Clave → id de los ficheros indexados bajo `root`."""
        prefix = path_key(root)
        out: dict[str, int] = {}
        for fid, key in self.conn.execute("SELECT id, key FROM files"):
            if is_under(key, prefix):
                out[key] = fid
        return out

    def _delete_chunks(self, file_id: int) -> None:
        ids = [r[0] for r in self.conn.execute("SELECT id FROM chunks WHERE file_id = ?", (file_id,))]
        if ids:
            self.conn.executemany("DELETE FROM vec WHERE chunk_id = ?", [(i,) for i in ids])
            self.conn.execute("DELETE FROM chunks WHERE file_id = ?", (file_id,))

    def replace_file(
        self,
        path: Path,
        kind: str,
        size: int,
        mtime: float,
        chunks: list[ChunkRecord],
        vectors: np.ndarray,
    ) -> None:
        if len(chunks) != len(vectors):
            raise ValueError("cada trozo necesita su vector")
        vectors = np.asarray(vectors, dtype=np.float32)
        if len(vectors) and vectors.shape[1] != self.dim:
            raise ValueError(f"vectores de {vectors.shape[1]} dimensiones en un índice de {self.dim}")
        key = path_key(path)
        with self.conn:
            row = self.conn.execute("SELECT id FROM files WHERE key = ?", (key,)).fetchone()
            if row:
                file_id = row[0]
                self._delete_chunks(file_id)
                self.conn.execute(
                    "UPDATE files SET path=?, kind=?, size=?, mtime=?, indexed_at=?, status='ok', error=NULL WHERE id=?",
                    (str(path), kind, size, mtime, time.time(), file_id),
                )
            else:
                file_id = self.conn.execute(
                    "INSERT INTO files(key, path, kind, size, mtime, indexed_at) VALUES (?, ?, ?, ?, ?, ?)",
                    (key, str(path), kind, size, mtime, time.time()),
                ).lastrowid
            for chunk, vector in zip(chunks, vectors):
                chunk_id = self.conn.execute(
                    "INSERT INTO chunks(file_id, modality, loc_unit, loc_start, loc_end, preview) VALUES (?, ?, ?, ?, ?, ?)",
                    (file_id, chunk.modality, chunk.loc_unit, chunk.loc_start, chunk.loc_end, chunk.preview),
                ).lastrowid
                self.conn.execute(
                    "INSERT INTO vec(chunk_id, embedding, kind) VALUES (?, ?, ?)",
                    (chunk_id, vector.tobytes(), kind),
                )

    def mark_error(self, path: Path, kind: str, size: int, mtime: float, error: str) -> None:
        key = path_key(path)
        with self.conn:
            row = self.conn.execute("SELECT id FROM files WHERE key = ?", (key,)).fetchone()
            if row:
                self._delete_chunks(row[0])
                self.conn.execute(
                    "UPDATE files SET kind=?, size=?, mtime=?, indexed_at=?, status='error', error=? WHERE id=?",
                    (kind, size, mtime, time.time(), error[:500], row[0]),
                )
            else:
                self.conn.execute(
                    "INSERT INTO files(key, path, kind, size, mtime, indexed_at, status, error) VALUES (?, ?, ?, ?, ?, ?, 'error', ?)",
                    (key, str(path), kind, size, mtime, time.time(), error[:500]),
                )

    def remove_files(self, file_ids: list[int]) -> None:
        with self.conn:
            for fid in file_ids:
                self._delete_chunks(fid)
                self.conn.execute("DELETE FROM files WHERE id = ?", (fid,))

    # -- consultas -----------------------------------------------------------
    def search(
        self,
        vector: np.ndarray,
        k: int = 10,
        kinds: list[str] | None = None,
        path_prefix: str | Path | None = None,
        exclude_path: str | Path | None = None,
    ) -> list[Hit]:
        vector = np.asarray(vector, dtype=np.float32).reshape(-1)
        if vector.shape[0] != self.dim:
            raise ValueError(f"consulta de {vector.shape[0]} dimensiones en un índice de {self.dim}")
        filtering = path_prefix is not None or exclude_path is not None
        fetch = min(4096, max(k * (10 if filtering else 2), k + 8))
        sql = "SELECT chunk_id, distance FROM vec WHERE embedding MATCH ? AND k = ?"
        params: list[object] = [vector.tobytes(), fetch]
        if kinds:
            sql += f" AND kind IN ({','.join('?' for _ in kinds)})"
            params.extend(kinds)
        sql += " ORDER BY distance"
        rows = self.conn.execute(sql, params).fetchall()
        prefix = path_key(path_prefix) if path_prefix is not None else None
        excluded = path_key(exclude_path) if exclude_path is not None else None
        hits: list[Hit] = []
        seen: set[tuple] = set()
        for chunk_id, distance in rows:
            info = self.conn.execute(
                "SELECT f.key, f.path, f.kind, c.modality, c.loc_unit, c.loc_start, c.loc_end, c.preview "
                "FROM chunks c JOIN files f ON f.id = c.file_id WHERE c.id = ?",
                (chunk_id,),
            ).fetchone()
            if not info:
                continue
            key = info[0]
            if prefix is not None and not is_under(key, prefix):
                continue
            if excluded is not None and key == excluded:
                continue
            dedupe = (key, info[4], info[5])
            if dedupe in seen:
                continue
            seen.add(dedupe)
            hits.append(
                Hit(
                    collection=self.name,
                    path=info[1],
                    kind=info[2],
                    modality=info[3],
                    loc_unit=info[4],
                    loc_start=info[5],
                    loc_end=info[6],
                    preview=info[7],
                    score=1.0 - float(distance),
                )
            )
            if len(hits) >= k:
                break
        return hits

    def file_vector(self, path: Path) -> np.ndarray | None:
        """Vector medio (normalizado) de un fichero indexado, para buscar parecidos."""
        rows = self.conn.execute(
            "SELECT v.embedding FROM vec v JOIN chunks c ON c.id = v.chunk_id JOIN files f ON f.id = c.file_id "
            "WHERE f.key = ?",
            (path_key(path),),
        ).fetchall()
        if not rows:
            return None
        mat = np.stack([np.frombuffer(r[0], dtype=np.float32) for r in rows])
        mean = mat.mean(axis=0)
        norm = np.linalg.norm(mean)
        return (mean / norm).astype(np.float32) if norm else mean.astype(np.float32)

    def stats(self) -> dict:
        kinds = dict(
            self.conn.execute("SELECT kind, COUNT(*) FROM files WHERE status='ok' GROUP BY kind").fetchall()
        )
        errors = self.conn.execute("SELECT COUNT(*) FROM files WHERE status='error'").fetchone()[0]
        chunks = self.conn.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
        last = self.conn.execute("SELECT MAX(indexed_at) FROM files").fetchone()[0]
        meta = dict(self.conn.execute("SELECT key, value FROM meta").fetchall())
        return {
            "name": self.name,
            "roots": self.roots(),
            "files": kinds,
            "errors": errors,
            "chunks": chunks,
            "model": meta.get("model"),
            "dim": int(meta.get("dim", self.dim)),
            "updated_at": last,
            "size_mb": round(self.db_path.stat().st_size / 2**20, 2) if self.db_path.exists() else 0,
        }

    def errors(self, limit: int = 20) -> list[dict]:
        return [
            {"path": p, "error": e}
            for p, e in self.conn.execute(
                "SELECT path, error FROM files WHERE status='error' ORDER BY indexed_at DESC LIMIT ?", (limit,)
            )
        ]


class Catalog:
    """Las colecciones que hay en `data_dir` (un `.db` por colección)."""

    def __init__(self, data_dir: Path, model: str):
        self.data_dir = data_dir
        self.model = model
        data_dir.mkdir(parents=True, exist_ok=True)

    def path_for(self, name: str) -> Path:
        return self.data_dir / f"{validate_name(name)}.db"

    def names(self) -> list[str]:
        return sorted(p.stem for p in self.data_dir.glob("*.db") if _NAME_RE.match(p.stem))

    def open(self, name: str, create: bool = False) -> Store:
        return Store(self.path_for(name), name, model=self.model, create=create)

    def drop(self, name: str) -> bool:
        path = self.path_for(name)
        found = path.exists()
        for suffix in ("", "-wal", "-shm"):
            target = Path(str(path) + suffix)
            if target.exists():
                target.unlink()
        return found

    def collection_for_path(self, path: Path) -> str | None:
        """La colección cuya raíz contiene `path` (la más profunda gana)."""
        key = path_key(path)
        best: tuple[int, str] | None = None
        for name in self.names():
            try:
                with self.open(name) as store:
                    roots = store.roots()
            except (sqlite3.Error, ValueError, FileNotFoundError):
                continue
            for root in roots:
                rk = path_key(root)
                if is_under(key, rk):
                    if best is None or len(rk) > best[0]:
                        best = (len(rk), name)
        return best[1] if best else None
