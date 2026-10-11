"""Identidad del servicio y autorización de archivos locales, sin cargar el modelo."""
from __future__ import annotations

import hashlib
import hmac
import os
import secrets
import stat
from pathlib import Path
from urllib.parse import unquote, urlparse

from .config import home_dir
from .inputs import InputError

SERVICE_ID = "embeddinggemma-2"


def api_key() -> str:
    explicit = os.environ.get("EGEMMA_API_KEY")
    if explicit:
        return explicit
    root = home_dir()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = root / "api-token"
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        pass
    else:
        with os.fdopen(fd, "w", encoding="utf-8") as file:
            file.write(secrets.token_urlsafe(48))
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "r", encoding="utf-8") as file:
        info = os.fstat(file.fileno())
        if not stat.S_ISREG(info.st_mode) or (os.name != "nt" and (info.st_mode & 0o077 or info.st_uid != os.getuid())):
            raise ValueError("La clave del servicio debe ser un archivo privado del usuario (0600)")
        value = file.read(256).strip()
    if len(value) < 32:
        raise ValueError("La clave del servicio está incompleta")
    return value


def identity_proof(key: str, challenge: str) -> str:
    if len(challenge) != 64 or any(c not in "0123456789abcdef" for c in challenge):
        raise InputError("La prueba de identidad no es válida")
    return hmac.new(key.encode(), (SERVICE_ID + ":" + challenge).encode(), hashlib.sha256).hexdigest()


def local_file_path(source: str | Path, *, directory: bool = False) -> Path:
    from .files import EXCLUDED_DIRS, is_excluded_name

    raw = str(source)
    if raw.startswith("file:"):
        uri = urlparse(raw)
        if uri.netloc not in ("", "localhost") or uri.query or uri.fragment:
            raise InputError("La ruta file debe referirse a un archivo local")
        raw = unquote(uri.path)
        if os.name == "nt" and raw.startswith("/") and len(raw) > 2 and raw[2] == ":":
            raw = raw[1:]
    if raw.startswith(("\\\\", "//")):
        raise InputError("No se aceptan rutas de red")
    path = Path(os.path.abspath(Path(raw).expanduser()))
    for part in (path, *path.parents):
        if part.is_symlink() and str(part) not in ("/var", "/tmp", "/etc"):
            raise InputError("No se leen enlaces simbólicos: elige el archivo local original")
    for alias, target in (("/var", "/private/var"), ("/tmp", "/private/tmp"), ("/etc", "/private/etc")):
        if path.is_relative_to(alias) and Path(alias).is_symlink():
            if str(Path(alias).resolve()) != target:
                raise InputError("La ruta del sistema no es válida")
            path = Path(target) / path.relative_to(alias)
            break
    excluded = {value.lower() for value in EXCLUDED_DIRS}
    private = {".ssh", ".aws", ".gnupg", ".azure", ".config", "keychains", "cookies"}
    if any(p.lower() in private or p.lower() in excluded for p in path.parts[:-1]):
        raise InputError("No se leen carpetas privadas o excluidas")
    if not directory and (is_excluded_name(path.name) or path.name.lower() == "api-token"):
        raise InputError("No se leen archivos de credenciales o excluidos")
    if directory and path.name.lower() in excluded | private:
        raise InputError("No se indexan carpetas privadas o excluidas")
    return path


def open_local_file(source: str | Path):
    """En macOS, fija cada directorio por descriptor y nunca sigue symlinks al abrir."""
    path = local_file_path(source)
    if os.open not in os.supports_dir_fd:
        return path.open("rb")
    directory = os.open(path.anchor, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            os.close(fd)
            raise InputError("El archivo debe ser regular")
        return os.fdopen(fd, "rb")
    finally:
        os.close(directory)
