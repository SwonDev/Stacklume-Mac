"""Cliente HTTP del servicio, compartido por la CLI y el servidor MCP. Arranca el servicio si no está."""

from __future__ import annotations

import os
import secrets
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import httpx

from .config import Config, load_config
from .access import SERVICE_ID, api_key, identity_proof


class ServiceError(RuntimeError):
    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


def _server_command() -> list[str]:
    scripts = Path(sys.executable).parent
    gui = scripts / ("egemma-server.exe" if os.name == "nt" else "egemma-server")
    if gui.exists():
        return [str(gui)]
    python = scripts / ("pythonw.exe" if os.name == "nt" else "python")
    if not python.exists():
        python = Path(sys.executable)
    return [str(python), "-m", "egemma.cli", "serve", "--log-to-file"]


class Client:
    def __init__(self, cfg: Config | None = None, timeout: float = 600):
        self.cfg = cfg or load_config()
        self.base_url = os.environ.get("EGEMMA_URL", self.cfg.base_url).rstrip("/")
        headers = {}
        self.key = api_key()
        headers["Authorization"] = f"Bearer {self.key}"
        self.http = httpx.Client(base_url=self.base_url, timeout=timeout, headers=headers, trust_env=False)

    def close(self) -> None:
        self.http.close()

    def __enter__(self) -> "Client":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def health(self, timeout: float = 3) -> dict | None:
        try:
            challenge = secrets.token_hex(32)
            r = self.http.get("/health", params={"challenge": challenge}, headers={"Authorization": ""}, timeout=timeout)
            if r.status_code != 200:
                return None
            try:
                identity = r.json()
            except ValueError as exc:
                raise ServiceError("El puerto no ofrece una identidad válida") from exc
            if not isinstance(identity, dict) or not isinstance(identity.get("proof"), str):
                raise ServiceError("El puerto no ofrece una identidad válida")
            if identity.get("service") != SERVICE_ID or not secrets.compare_digest(identity.get("proof", ""), identity_proof(self.key, challenge)):
                raise ServiceError("El puerto responde con un servicio cuya identidad no coincide")
            r = self.http.get("/health", timeout=timeout)
        except httpx.HTTPError:
            return None
        return r.json() if r.status_code == 200 else None

    def start_detached(self) -> None:
        flags = 0
        if os.name == "nt":
            flags = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_NO_WINDOW
        subprocess.Popen(  # noqa: S603 — orden fija del propio venv
            _server_command(),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=flags,
            start_new_session=os.name != "nt",
            close_fds=True,
        )

    def ensure_running(self, timeout: float = 45) -> dict:
        info = self.health()
        if info:
            return info
        if os.environ.get("EGEMMA_URL"):
            raise ServiceError(f"el servicio de {self.base_url} no responde")
        self.start_detached()
        deadline = time.time() + timeout
        while time.time() < deadline:
            time.sleep(0.5)
            info = self.health()
            if info:
                return info
        raise ServiceError(
            f"el servicio no arrancó en {timeout:.0f} s; mira {Path(self.cfg.data_path).parent / 'logs' / 'server.log'}"
        )

    def _call(self, method: str, path: str, **kwargs: Any) -> Any:
        self.ensure_running()
        try:
            r = self.http.request(method, path, **kwargs)
        except httpx.TimeoutException as exc:
            raise ServiceError("la petición tardó demasiado; el trabajo puede seguir en segundo plano") from exc
        except httpx.HTTPError as exc:
            raise ServiceError(f"no se pudo hablar con el servicio: {exc}") from exc
        if r.status_code >= 400:
            try:
                message = r.json()["error"]["message"]
            except (ValueError, KeyError, TypeError):
                message = r.text[:500]
            raise ServiceError(message, r.status_code)
        return r.json()

    def get(self, path: str, **params: Any) -> Any:
        return self._call("GET", path, params={k: v for k, v in params.items() if v is not None})

    def post(self, path: str, payload: dict) -> Any:
        return self._call("POST", path, json={k: v for k, v in payload.items() if v is not None})

    def delete(self, path: str) -> Any:
        return self._call("DELETE", path)
