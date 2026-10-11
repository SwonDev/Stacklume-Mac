"""Gestión del worker del modelo desde el servidor: arranque bajo demanda y cierre por inactividad."""

from __future__ import annotations

import dataclasses
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any

from . import protocol
from .config import Config, home_dir
from .inputs import InputError


class WorkerError(RuntimeError):
    def __init__(self, message: str, kind: str = "internal"):
        super().__init__(message)
        self.kind = kind


def _python_executable() -> str:
    """python.exe del venv aunque el servidor corra con pythonw.exe (sin consola)."""
    exe = Path(sys.executable)
    if exe.name.lower() == "pythonw.exe":
        candidate = exe.with_name("python.exe")
        if candidate.exists():
            return str(candidate)
    return str(exe)


def _model_cached(model: str) -> bool:
    try:
        from huggingface_hub import snapshot_download

        snapshot_download(model, local_files_only=True)
        return True
    except Exception:  # noqa: BLE001 — cualquier fallo significa «no está en caché»
        return False


class Engine:
    """Un único worker; las peticiones se atienden de una en una (la GPU no se comparte bien)."""

    def __init__(self, cfg: Config, log_dir: Path | None = None):
        self.cfg = cfg
        self.log_dir = log_dir or home_dir() / "logs"
        self._lock = threading.Lock()
        self._proc: subprocess.Popen | None = None
        self._info: dict | None = None
        self._last_used = 0.0
        self._started_at = 0.0
        self._loads = 0
        self._stop = threading.Event()
        self._releasing = threading.Event()
        self._watcher = threading.Thread(target=self._idle_loop, name="egemma-idle", daemon=True)
        self._watcher.start()

    # -- ciclo de vida -------------------------------------------------------
    def _spawn(self) -> None:
        self.log_dir.mkdir(parents=True, exist_ok=True)
        env = os.environ.copy()
        env["EGEMMA_WORKER_CONFIG"] = json.dumps(dataclasses.asdict(self.cfg))
        env.setdefault("TOKENIZERS_PARALLELISM", "false")
        env.setdefault("TRANSFORMERS_VERBOSITY", "error")
        env.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
        env.setdefault("PYTHONIOENCODING", "utf-8")
        # Apple Silicon: si a MPS le falta alguna operación del modelo, la hace la CPU en vez de fallar.
        env.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
        if _model_cached(self.cfg.mlx_model if self.cfg.backend == "mlx" else self.cfg.model):
            env.setdefault("HF_HUB_OFFLINE", "1")  # sin consultas a la red en cada carga
        log = open(self.log_dir / "worker.log", "ab")  # noqa: SIM115 — lo hereda el hijo
        try:
            self._proc = subprocess.Popen(
                [_python_executable(), "-m", "egemma.worker"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=log,
                env=env,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
        finally:
            log.close()
        try:
            ready = protocol.recv(self._proc.stdout)
        except EOFError as exc:
            self._kill()
            raise WorkerError("el worker se cerró al arrancar; mira logs/worker.log", "load") from exc
        if not ready.get("ok"):
            self._kill()
            raise WorkerError(f"no se pudo cargar el modelo: {ready.get('error')}", "load")
        self._info = ready["result"]
        self._started_at = time.time()
        self._loads += 1

    def _kill(self) -> None:
        proc, self._proc, self._info = self._proc, None, None
        if proc is None:
            return
        try:
            if proc.poll() is None:
                try:
                    protocol.send(proc.stdin, {"op": "exit"})
                    proc.wait(timeout=10)
                except (OSError, EOFError, subprocess.TimeoutExpired):
                    proc.kill()
                    proc.wait(timeout=10)
        finally:
            for stream in (proc.stdin, proc.stdout):
                try:
                    stream.close()
                except OSError:
                    pass

    def unload(self) -> bool:
        with self._lock:
            was_running = self._proc is not None
            self._kill()
            return was_running

    def release_memory(self) -> bool:
        """Libera también un worker ocupado, sin esperar el timeout de inferencia."""
        self._releasing.set()
        acquired = False
        try:
            acquired = self._lock.acquire(timeout=0.5)
            if not acquired:
                proc = self._proc
                if proc is not None and proc.poll() is None:
                    proc.kill()
                acquired = self._lock.acquire(timeout=5)
            if not acquired:
                raise WorkerError("El worker no pudo liberar la memoria a tiempo", "memory")
            self._kill()
            return not self.status()["loaded"]
        finally:
            if acquired:
                self._lock.release()
            self._releasing.clear()

    def close(self) -> None:
        self._stop.set()
        if self._lock.acquire(timeout=5):
            try:
                self._kill()
            finally:
                self._lock.release()
        else:
            # Hay una petición colgada con el lock: se mata el worker y su recv() termina con EOF.
            proc = self._proc
            if proc is not None and proc.poll() is None:
                proc.kill()

    def _idle_loop(self) -> None:
        while not self._stop.wait(15):
            minutes = float(self.cfg.idle_unload_minutes or 0)
            if minutes <= 0 or self._proc is None:
                continue
            if time.time() - self._last_used < minutes * 60:
                continue
            if self._lock.acquire(blocking=False):
                try:
                    if self._proc is not None and time.time() - self._last_used >= minutes * 60:
                        self._kill()
                finally:
                    self._lock.release()

    # -- peticiones ----------------------------------------------------------
    def request(self, op: str, **payload: Any) -> Any:
        with self._lock:
            if self._stop.is_set():
                raise WorkerError("El motor se está cerrando; reintenta al abrir la biblioteca", "memory")
            if self._releasing.is_set():
                raise WorkerError("El modelo está liberando memoria; reintenta la operación", "memory")
            if self._proc is None or self._proc.poll() is not None:
                self._kill()
                self._spawn()
            proc = self._proc
            assert proc is not None
            # Si una petición se cuelga (p. ej., una URL que no termina de descargarse), se mata el worker:
            # la tubería se cierra, recv() lanza EOFError y el lock se libera para las demás peticiones.
            watchdog = threading.Timer(float(self.cfg.request_timeout_s), proc.kill)
            watchdog.daemon = True
            watchdog.start()
            timed_out = False
            try:
                protocol.send(proc.stdin, {"op": op, **payload})
                reply = protocol.recv(proc.stdout)
                if reply.get("ok") and isinstance(reply.get("result"), dict):
                    self._info = reply["result"].pop("_worker_info", self._info)
            except (EOFError, OSError) as exc:
                releasing = self._releasing.is_set()
                timed_out = not watchdog.is_alive()
                self._kill()
                if releasing:
                    raise WorkerError("El worker se ha cerrado para liberar memoria", "memory") from exc
                if timed_out:
                    raise WorkerError(
                        f"la petición superó {self.cfg.request_timeout_s:.0f} s y se canceló; el modelo se relanzará", "timeout"
                    ) from exc
                raise WorkerError("el worker del modelo se cayó (¿sin memoria?); se relanzará en la próxima petición") from exc
            finally:
                watchdog.cancel()
                self._last_used = time.time()
        if reply.get("ok"):
            return reply["result"]
        if reply.get("kind") == "bad_input":
            raise InputError(reply.get("error", "entrada no válida"))
        raise WorkerError(reply.get("error", "error interno del worker"), reply.get("kind", "internal"))

    def encode(self, items: list[dict], options: dict | None = None) -> dict:
        return self.request("encode", items=items, options=options or {})

    def status(self) -> dict:
        proc = self._proc
        running = proc is not None and proc.poll() is None
        return {
            "loaded": running,
            "worker": self._info if running else None,
            "loaded_since": self._started_at if running else None,
            "idle_seconds": round(time.time() - self._last_used, 1) if self._last_used else None,
            "idle_unload_minutes": self.cfg.idle_unload_minutes,
            "loads": self._loads,
        }
