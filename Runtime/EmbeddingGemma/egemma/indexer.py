"""Indexado incremental de carpetas: código, documentos, PDF, imágenes, audio y vídeo."""

from __future__ import annotations

import itertools
import os
import threading
import time
import traceback
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol

import numpy as np

from .config import Config
from .engine import WorkerError
from .files import Candidate, chunk_text, list_candidates, notebook_text, read_text_file
from .inputs import InputError
from .store import Catalog, ChunkRecord, default_collection_name, path_key

MAX_FILES_PER_ROOT = 50_000
MAX_PDF_PAGES = 1_000
PDF_TEXT_MIN_CHARS = 200
ITEMS_PER_CALL = {"code": 32, "doc": 32, "pdf": 16, "image": 16, "audio": 8, "video": 4}


class EmbedFn(Protocol):
    def __call__(self, items: list[dict], options: dict | None = None) -> dict: ...


class WorkerOps(Protocol):
    def request(self, op: str, **payload: object) -> object: ...


@dataclass
class Unit:
    item: dict
    record: ChunkRecord


@dataclass
class Job:
    id: str
    collection: str
    root: str
    status: str = "queued"  # queued | running | done | error | cancelled
    created_at: float = field(default_factory=time.time)
    started_at: float | None = None
    finished_at: float | None = None
    files_total: int = 0
    files_done: int = 0
    indexed: int = 0
    unchanged: int = 0
    cloud_only: int = 0
    removed: int = 0
    failed: int = 0
    skipped: int = 0  # modalidad desactivada en config.json
    chunks: int = 0
    current: str | None = None
    error: str | None = None
    errors: list[dict] = field(default_factory=list)
    done_event: threading.Event = field(default_factory=threading.Event, repr=False)

    def as_dict(self) -> dict:
        data = {k: v for k, v in self.__dict__.items() if k != "done_event"}
        if self.started_at:
            data["elapsed_s"] = round((self.finished_at or time.time()) - self.started_at, 1)
        return data


def guard_root(root: Path) -> None:
    """Evita indexar por error carpetas enormes: el perfil, la raíz de un disco o OneDrive entero."""
    if str(root).startswith(("\\\\", "//")):
        raise InputError("no se indexan rutas de red (UNC): copia los ficheros a un disco local")
    resolved = root.resolve()
    home = Path.home().resolve()
    forbidden = {home, Path(resolved.anchor)}
    for env in ("OneDrive", "OneDriveCommercial", "OneDriveConsumer"):
        if os.environ.get(env):
            forbidden.add(Path(os.environ[env]).resolve())
    if resolved in forbidden or resolved == resolved.parent:
        raise InputError(
            f"no indexo «{resolved}» entero: elige la carpeta del proyecto o de los recursos concretos"
        )


class Indexer:
    """Cola de trabajos de indexado; se procesan de uno en uno en un hilo."""

    def __init__(self, cfg: Config, catalog: Catalog, embed: EmbedFn, worker: WorkerOps):
        self.cfg = cfg
        self.catalog = catalog
        self.embed = embed
        self.worker = worker
        self._jobs: dict[str, Job] = {}
        self._order: deque[str] = deque(maxlen=100)
        self._queue: deque[str] = deque()
        self._cv = threading.Condition()
        self._ids = itertools.count(1)
        self._thread = threading.Thread(target=self._loop, name="egemma-indexer", daemon=True)
        self._thread.start()

    # -- cola ------------------------------------------------------------------
    def submit(self, root: Path, collection: str | None = None) -> Job:
        guard_root(root.expanduser())  # antes de resolve(): resolver una ruta UNC ya tocaría la red
        from .access import local_file_path
        root = local_file_path(root, directory=root.is_dir())
        if not root.exists():
            raise InputError(f"no existe «{root}»")
        name = collection or self.catalog.collection_for_path(root) or default_collection_name(
            root if root.is_dir() else root.parent
        )
        self.catalog.path_for(name)  # valida el nombre
        with self._cv:
            for job_id in list(self._queue) + [j.id for j in self._jobs.values() if j.status == "running"]:
                job = self._jobs[job_id]
                if job.collection == name and path_key(job.root) == path_key(root):
                    return job
            job = Job(id=f"j{next(self._ids)}", collection=name, root=str(root))
            self._jobs[job.id] = job
            self._order.append(job.id)
            for old in list(self._jobs):
                if old not in self._order:
                    del self._jobs[old]
            self._queue.append(job.id)
            self._cv.notify()
        return job

    def get(self, job_id: str) -> Job | None:
        return self._jobs.get(job_id)

    def jobs(self) -> list[Job]:
        jobs = self._jobs
        return [jobs[j] for j in list(self._order) if j in jobs]

    def running_for(self, collection: str) -> Job | None:
        for job in list(self._jobs.values()):
            if job.collection == collection and job.status in ("queued", "running"):
                return job
        return None

    def cancel(self, job_id: str) -> bool:
        job = self._jobs.get(job_id)
        if job and job.status in ("queued", "running"):
            job.status = "cancelled"
            return True
        return False

    def _loop(self) -> None:
        while True:
            with self._cv:
                while not self._queue:
                    self._cv.wait()
                job = self._jobs.get(self._queue.popleft())
            if job is None or job.status == "cancelled":
                if job:
                    job.done_event.set()
                continue
            try:
                self.run(job)
            except Exception as exc:  # noqa: BLE001
                job.status = "error"
                job.error = f"{type(exc).__name__}: {exc}"
                traceback.print_exc()
            finally:
                job.finished_at = time.time()
                job.current = None
                job.done_event.set()

    # -- trabajo -----------------------------------------------------------------
    def run(self, job: Job) -> None:
        job.status = "running"
        job.started_at = time.time()
        root = Path(job.root)
        candidates = list_candidates(root, self.cfg.extra_exclude)
        if len(candidates) > MAX_FILES_PER_ROOT:
            raise InputError(
                f"«{root}» tiene {len(candidates)} ficheros indexables (máx. {MAX_FILES_PER_ROOT}); elige una subcarpeta"
            )
        job.files_total = len(candidates)
        with self.catalog.open(job.collection, create=True) as store:
            store.add_root(root)
            seen: set[str] = set()
            for cand in candidates:
                if job.status == "cancelled":
                    return
                job.current = str(cand.path)
                key = path_key(cand.path)
                seen.add(key)
                state = store.file_state(cand.path)
                if state and state[3] == "ok" and state[1] == cand.size and abs(state[2] - cand.mtime) < 1e-6:
                    job.unchanged += 1
                    job.files_done += 1
                    continue
                if cand.cloud_only and not self.cfg.allow_onedrive_hydration:
                    job.cloud_only += 1
                    job.files_done += 1
                    continue
                if not self._kind_enabled(cand.kind):
                    # Sin guardar nada: si se reactiva la modalidad, el fichero entra en la siguiente pasada.
                    job.skipped += 1
                    job.files_done += 1
                    continue
                try:
                    units = self._plan(cand, root)
                    while True:
                        try:
                            vectors = self._embed_units(units, cand.kind, background=True)
                            break
                        except WorkerError as exc:
                            if exc.kind != "memory" or job.status == "cancelled":
                                raise
                            time.sleep(0.25)
                    store.replace_file(
                        cand.path, cand.kind, cand.size, cand.mtime, [u.record for u in units], vectors
                    )
                    job.indexed += 1
                    job.chunks += len(units)
                except WorkerError as exc:
                    if exc.kind == "load":
                        raise
                    # Fallo pasajero (worker caído, sin memoria, tiempo agotado): no se guarda, se reintenta.
                    self._record_failure(job, cand, exc)
                except InputError as exc:
                    # Fallo determinista del fichero: se guarda y no se reintenta hasta que cambie.
                    store.mark_error(cand.path, cand.kind, cand.size, cand.mtime, str(exc))
                    self._record_failure(job, cand, exc)
                except Exception as exc:  # noqa: BLE001 — un fichero raro no puede parar la carpeta entera
                    store.mark_error(cand.path, cand.kind, cand.size, cand.mtime, f"{type(exc).__name__}: {exc}")
                    self._record_failure(job, cand, exc)
                job.files_done += 1
            stale = [fid for key, fid in store.files_under(root).items() if key not in seen]
            if stale:
                store.remove_files(stale)
                job.removed = len(stale)
        job.status = "done"

    @staticmethod
    def _record_failure(job: Job, cand: Candidate, exc: Exception) -> None:
        job.failed += 1
        if len(job.errors) < 20:
            job.errors.append({"path": str(cand.path), "error": str(exc) or type(exc).__name__})

    def _kind_enabled(self, kind: str) -> bool:
        mods = set(self.cfg.modalities)
        needs = {"image": {"image"}, "audio": {"audio"}, "video": {"video", "audio"}}.get(kind)
        return needs is None or bool(needs & mods)

    def _embed_units(self, units: list[Unit], kind: str, background: bool = False) -> np.ndarray:
        if not units:
            return np.zeros((0, 768), dtype=np.float32)
        step = ITEMS_PER_CALL.get(kind, 16)
        parts = []
        for i in range(0, len(units), step):
            if background and os.environ.get("STACKLUME_PARENT_PID"):
                from .config import home_dir
                import ctypes
                marker = home_dir() / "text-inference-active"
                system = ctypes.CDLL(None)
                while True:
                    pressure = ctypes.c_int(1)
                    size = ctypes.c_size_t(ctypes.sizeof(pressure))
                    system.sysctlbyname(b"kern.memorystatus_vm_pressure_level", ctypes.byref(pressure), ctypes.byref(size), None, 0)
                    if not marker.exists() and pressure.value <= 1:
                        break
                    time.sleep(0.25)
            batch = units[i : i + step]
            parts.append(self.embed([u.item for u in batch])["vectors"])
        return np.concatenate(parts)

    # -- planificación por tipo ----------------------------------------------------
    def _plan(self, cand: Candidate, root: Path) -> list[Unit]:
        base = root if root.is_dir() else root.parent
        try:
            rel = cand.path.relative_to(base).as_posix()
        except ValueError:
            rel = cand.path.name
        if cand.kind in ("code", "doc"):
            return self._plan_text(cand, rel)
        if cand.kind == "pdf":
            return self._plan_pdf(cand, rel)
        if cand.kind == "image":
            return [Unit({"parts": [{"type": "image", "src": str(cand.path)}], "prompt": None},
                         ChunkRecord("image", None, None, None, rel))]
        if cand.kind == "audio":
            return self._plan_audio(cand, rel)
        if cand.kind == "video":
            return self._plan_video(cand, rel)
        return []

    def _plan_text(self, cand: Candidate, rel: str) -> list[Unit]:
        text = read_text_file(cand.path, self.cfg.max_text_file_kb * 1024)
        if text is None:
            raise InputError("binario o demasiado grande para indexarlo como texto")
        if cand.path.suffix.lower() == ".ipynb":
            text = notebook_text(text)
        units = []
        for chunk in chunk_text(text, self.cfg.chunk_lines, self.cfg.chunk_overlap_lines, self.cfg.chunk_max_chars):
            units.append(
                Unit(
                    {"parts": [{"type": "text", "text": f"title: {rel} | text: {chunk.text}"}], "prompt": None},
                    ChunkRecord("text", "lines", chunk.start_line, chunk.end_line, _preview(chunk.text)),
                )
            )
        return units

    def _plan_pdf(self, cand: Candidate, rel: str) -> list[Unit]:
        import pypdfium2 as pdfium

        from .access import open_local_file
        source = None
        try:
            source = open_local_file(cand.path)
            pdf = pdfium.PdfDocument(source, autoclose=True)
        except Exception as exc:  # noqa: BLE001 — PdfiumError
            if source is not None:
                source.close()
            raise InputError(f"PDF ilegible: {exc}") from exc
        units: list[Unit] = []
        try:
            for index in range(min(len(pdf), MAX_PDF_PAGES)):
                page_no = index + 1
                try:
                    page = pdf[index]
                    textpage = page.get_textpage()
                    text = textpage.get_text_bounded() or ""
                    textpage.close()
                    page.close()
                except Exception:  # noqa: BLE001 — PdfiumError en una página dañada: se salta esa página
                    continue
                if len(text.strip()) >= PDF_TEXT_MIN_CHARS:
                    for chunk in chunk_text(text, self.cfg.chunk_lines, self.cfg.chunk_overlap_lines, self.cfg.chunk_max_chars):
                        units.append(
                            Unit(
                                {"parts": [{"type": "text", "text": f"title: {rel} (página {page_no}) | text: {chunk.text}"}], "prompt": None},
                                ChunkRecord("text", "page", page_no, page_no, _preview(chunk.text)),
                            )
                        )
                elif "image" in self.cfg.modalities:
                    # Página escaneada o casi sin texto: se indexa como imagen (recuperación de documentos visuales).
                    units.append(
                        Unit(
                            {"parts": [{"type": "pdf_page", "src": str(cand.path), "page": page_no}], "prompt": None},
                            ChunkRecord("image", "page", page_no, page_no, _preview(text) or f"{rel} (página {page_no})"),
                        )
                    )
        finally:
            pdf.close()
        return units

    def _probe(self, cand: Candidate) -> dict:
        info = self.worker.request("probe", path=str(cand.path))
        assert isinstance(info, dict)
        return info

    def _windows(self, duration: float, window: float, overlap: float) -> list[tuple[float, float]]:
        step = max(1.0, window - overlap)
        out = []
        start = 0.0
        while start < duration:
            end = min(duration, start + window)
            if end - start >= 1.0 or not out:
                out.append((round(start, 3), round(end, 3)))
            start += step
        return out

    def _plan_audio(self, cand: Candidate, rel: str) -> list[Unit]:
        info = self._probe(cand)
        duration = info.get("duration") or 0.0
        if duration <= 0:
            raise InputError("duración desconocida")
        units = []
        for start, end in self._windows(duration, self.cfg.audio_window_s, self.cfg.audio_overlap_s):
            units.append(
                Unit(
                    {"parts": [{"type": "audio", "src": str(cand.path), "start": start, "end": end}], "prompt": None},
                    ChunkRecord("audio", "s", start, end, rel),
                )
            )
        return units

    def _plan_video(self, cand: Candidate, rel: str) -> list[Unit]:
        info = self._probe(cand)
        duration = info.get("duration") or 0.0
        if duration <= 0 or not info.get("has_video"):
            if info.get("has_audio"):
                return self._plan_audio(cand, rel)
            raise InputError("vídeo sin pistas legibles")
        units = []
        mods = set(self.cfg.modalities)
        audio_end = (info.get("audio_duration") or duration) if info.get("has_audio") else 0.0
        for start, end in self._windows(duration, self.cfg.video_window_s, 0.0):
            if "video" in mods:
                units.append(
                    Unit(
                        {"parts": [{"type": "video", "src": str(cand.path), "start": start, "end": end}], "prompt": None},
                        ChunkRecord("video", "s", start, end, rel),
                    )
                )
            if "audio" in mods and start < audio_end - 1.0:
                end = min(end, round(audio_end, 3))
                # La pista de sonido aparte: así una consulta encuentra lo que se dice, no solo lo que se ve.
                units.append(
                    Unit(
                        {"parts": [{"type": "audio", "src": str(cand.path), "start": start, "end": end}], "prompt": None},
                        ChunkRecord("audio", "s", start, end, rel),
                    )
                )
        return units


def _preview(text: str, limit: int = 280) -> str:
    flat = " ".join(text.split())
    return flat if len(flat) <= limit else flat[: limit - 1] + "…"


def wait_for(job: Job, seconds: float) -> bool:
    """Espera a que termine el trabajo hasta `seconds`. Devuelve True si terminó."""
    if seconds <= 0:
        return job.done_event.is_set()
    return job.done_event.wait(seconds)
