"""Hook de inicio de sesión para los asistentes: recuerda al modelo que tiene búsqueda semántica local.

Tiene que ser rápido y no fallar nunca: si algo va mal, no dice nada. Si el servicio no responde, lo
arranca en segundo plano sin esperar.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

from .config import load_config
from .paths import is_under, path_key


def _cwd_from_stdin(raw: str) -> Path:
    try:
        data = json.loads(raw) if raw.strip() else {}
        cwd = data.get("cwd") if isinstance(data, dict) else None
    except ValueError:
        cwd = None
    return Path(cwd or os.getcwd())


def _skip(cwd: Path) -> bool:
    try:
        resolved = cwd.resolve()
    except OSError:
        return True
    return resolved == Path.home().resolve() or resolved == resolved.parent


def message_for(cwd: Path, collections: list[dict] | None, base_url: str) -> str:
    key = path_key(cwd)
    covering: tuple[int, dict] | None = None
    for col in collections or []:
        for root in col.get("roots", []):
            rk = path_key(root)
            if is_under(key, rk) and (covering is None or len(rk) > covering[0]):
                covering = (len(rk), col)
    integrate = (
        "Si el proyecto necesita embeddings, búsqueda semántica, RAG o recomendaciones, usa la herramienta "
        "`integration_guide` o la skill `embeddinggemma` e intégralo."
    )
    if covering:
        col = covering[1]
        files = ", ".join(f"{v} {k}" for k, v in (col.get("files") or {}).items()) or "sin ficheros"
        return (
            f"EmbeddingGemma 2 (búsqueda semántica local) tiene indexada esta carpeta en la colección «{col['name']}» "
            f"({files}). Para buscar por significado —código sin saber su nombre, imágenes, audio, vídeo o PDF— usa "
            f"la herramienta MCP `semantic_search` con path={cwd} (se pone al día sola). {integrate}"
        )
    return (
        f"EmbeddingGemma 2 (embeddings multimodales locales) está disponible por MCP (`embeddinggemma`) y en "
        f"{base_url}/v1 (compatible con OpenAI). Si necesitas buscar por significado en esta carpeta (código sin "
        f"saber su nombre, imágenes, audio, vídeo o PDF), `semantic_search` con path={cwd} la indexa al vuelo. "
        f"{integrate}"
    )


def session_start(fmt: str = "claude", stdin_text: str = "") -> str:
    cwd = _cwd_from_stdin(stdin_text)
    if _skip(cwd):
        return ""
    cfg = load_config()
    collections: list[dict] | None = None
    try:
        from .client import Client

        with Client(cfg, timeout=2) as client:
            if client.health(timeout=1) is None:
                client.start_detached()
            else:
                resp = client.http.get("/collections", timeout=2)
                if resp.status_code == 200:
                    collections = resp.json()
    except Exception:  # El hook continúa sin indexado si la identidad o el acceso no son válidos.
        pass
    text = message_for(cwd, collections, cfg.base_url)
    if fmt == "claude":
        return json.dumps(
            {"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": text}}, ensure_ascii=False
        )
    return text


def main(fmt: str) -> int:
    try:
        raw = "" if sys.stdin is None or sys.stdin.isatty() else sys.stdin.read()
    except (OSError, ValueError):
        raw = ""
    try:
        out = session_start(fmt, raw)
    except Exception:  # noqa: BLE001 — un hook nunca debe romper el inicio de sesión
        out = ""
    if out:
        sys.stdout.write(out + "\n")
        sys.stdout.flush()
    return 0
