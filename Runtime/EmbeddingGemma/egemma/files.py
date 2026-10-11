"""Qué ficheros se indexan, de qué tipo son y cómo se trocea el texto."""

from __future__ import annotations

import fnmatch
import os
import shutil
import stat
import subprocess
from dataclasses import dataclass
from pathlib import Path

CODE_EXT = {
    ".gml", ".fsh", ".vsh", ".yy", ".yyp",
    ".py", ".pyi", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".rs", ".go", ".java", ".kt", ".kts",
    ".swift", ".m", ".mm", ".c", ".h", ".cc", ".cpp", ".cxx", ".hpp", ".hh", ".cs", ".fs", ".vb", ".rb",
    ".php", ".lua", ".gd", ".gdshader", ".glsl", ".vert", ".frag", ".hlsl", ".wgsl", ".shader", ".metal",
    ".sql", ".sh", ".bash", ".zsh", ".fish", ".ps1", ".psm1", ".bat", ".cmd", ".r", ".jl", ".dart",
    ".scala", ".clj", ".ex", ".exs", ".erl", ".hs", ".ml", ".nim", ".zig", ".sol", ".vue", ".svelte",
    ".astro", ".html", ".htm", ".css", ".scss", ".sass", ".less", ".graphql", ".gql", ".proto", ".tf",
    ".prisma", ".dockerfile", ".cmake", ".gradle", ".groovy", ".pl", ".pm", ".asm", ".s",
}
DOC_EXT = {
    ".md", ".mdx", ".markdown", ".txt", ".rst", ".adoc", ".org", ".tex", ".json", ".jsonc", ".json5",
    ".yaml", ".yml", ".toml", ".ini", ".cfg", ".conf", ".xml", ".csv", ".tsv", ".svg", ".srt", ".vtt",
    ".ipynb", ".env.example",
}
IMAGE_EXT = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".tif", ".tiff"}
AUDIO_EXT = {".wav", ".mp3", ".flac", ".ogg", ".oga", ".m4a", ".aac", ".opus", ".wma", ".aiff", ".aif", ".caf"}
VIDEO_EXT = {".mp4", ".mov", ".webm", ".mkv", ".avi", ".m4v", ".wmv", ".mpg", ".mpeg", ".3gp"}
PDF_EXT = {".pdf"}
SPECIAL_TEXT_NAMES = {"dockerfile", "makefile", "justfile", "procfile", "gemfile", "rakefile", "readme", "license"}

KINDS = ("code", "doc", "image", "audio", "video", "pdf")

EXCLUDED_DIRS = {
    ".git", ".hg", ".svn", "node_modules", ".venv", "venv", "env", "__pycache__", ".mypy_cache",
    ".pytest_cache", ".ruff_cache", ".tox", "dist", "build", "out", ".next", ".nuxt", ".svelte-kit",
    ".astro", ".turbo", ".vercel", ".netlify", ".cache", ".parcel-cache", "coverage", "target",
    ".gradle", ".idea", "bower_components", "vendor", "Pods", ".expo", ".angular", ".tgrep",
    "$RECYCLE.BIN", "System Volume Information",
}
# Nunca se indexan: credenciales y ruido.
EXCLUDED_FILE_GLOBS = (
    ".env", ".env.*", "*.pem", "*.key", "*.p12", "*.pfx", "*.keystore", "*.jks", "id_rsa*", "id_ed25519*",
    "*.kdbx", "credentials*", "*secret*", "*.token", ".npmrc", ".pypirc", ".netrc", ".git-credentials*",
    "*.min.js", "*.min.css", "*.map", "*.lock", "package-lock.json", "pnpm-lock.yaml", "yarn.lock",
    "bun.lockb", "*.log", "*.tsbuildinfo", "*.pyc", "*.db", "*.sqlite", "*.sqlite3", "*.db-wal", "*.db-shm",
)
ALLOWED_DESPITE_GLOBS = {".env.example", ".env.sample", ".env.template"}

# Atributos de Windows de los ficheros «solo en la nube» de OneDrive.
_FILE_ATTRIBUTE_OFFLINE = 0x1000
_FILE_ATTRIBUTE_RECALL_ON_OPEN = 0x40000
_FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS = 0x400000
_CLOUD_ONLY_MASK = _FILE_ATTRIBUTE_OFFLINE | _FILE_ATTRIBUTE_RECALL_ON_OPEN | _FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS
# macOS (File Provider: iCloud Drive, OneDrive, Dropbox…): contenido no descargado.
_SF_DATALESS = 0x40000000


def classify(path: Path) -> str | None:
    """Tipo de fichero (`code`, `doc`, `image`, `audio`, `video`, `pdf`) o None si no se indexa."""
    name = path.name.lower()
    ext = path.suffix.lower()
    if name in ALLOWED_DESPITE_GLOBS:
        return "doc"
    if ext in CODE_EXT:
        return "code"
    if ext in DOC_EXT:
        return "doc"
    if ext in IMAGE_EXT:
        return "image"
    if ext in AUDIO_EXT:
        return "audio"
    if ext in VIDEO_EXT:
        return "video"
    if ext in PDF_EXT:
        return "pdf"
    if name in SPECIAL_TEXT_NAMES or path.stem.lower() in SPECIAL_TEXT_NAMES:
        return "doc"
    return None


def is_excluded_name(name: str, extra_globs: list[str] | tuple[str, ...] = ()) -> bool:
    lower = name.lower()
    if lower in ALLOWED_DESPITE_GLOBS:
        return False
    return any(fnmatch.fnmatch(lower, g.lower()) for g in (*EXCLUDED_FILE_GLOBS, *extra_globs))


def is_cloud_only(st: os.stat_result) -> bool:
    """True si el fichero está solo en la nube (OneDrive en Windows; iCloud/OneDrive «dataless» en macOS).

    Leerlo lo descargaría.
    """
    attrs = getattr(st, "st_file_attributes", 0)
    flags = getattr(st, "st_flags", 0)
    return bool(attrs & _CLOUD_ONLY_MASK) or bool(flags & _SF_DATALESS)


def looks_binary(sample: bytes) -> bool:
    return b"\x00" in sample


@dataclass
class Candidate:
    path: Path
    kind: str
    size: int
    mtime: float
    cloud_only: bool


def _git_files(root: Path) -> list[Path] | None:
    git = shutil.which("git")
    if not git or not (root / ".git").exists():
        return None
    try:
        out = subprocess.run(
            [git, "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            capture_output=True,
            timeout=120,
            check=True,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        ).stdout
    except (subprocess.SubprocessError, OSError):
        return None
    return [root / p for p in out.decode("utf-8", "replace").split("\0") if p]


def _walk(root: Path, extra_globs: list[str]) -> list[Path]:
    found: list[Path] = []
    stack = [root]
    while stack:
        current = stack.pop()
        try:
            entries = list(os.scandir(current))
        except OSError:
            continue
        for entry in entries:
            name = entry.name
            try:
                if entry.is_dir(follow_symlinks=False):
                    if name in EXCLUDED_DIRS or (name.startswith(".") and name not in (".github", ".claude")):
                        continue
                    if any(fnmatch.fnmatch(name.lower(), g.lower()) for g in extra_globs):
                        continue
                    stack.append(Path(entry.path))
                elif entry.is_file(follow_symlinks=False):
                    found.append(Path(entry.path))
            except OSError:
                continue
    return found


def list_candidates(root: Path, extra_globs: list[str] | None = None) -> list[Candidate]:
    """Ficheros indexables bajo `root`. En repos git respeta `.gitignore` (git ls-files)."""
    extra = list(extra_globs or [])
    from .access import local_file_path
    from .inputs import InputError
    root = local_file_path(root, directory=root.is_dir())
    if root.is_file():
        paths = [root]
    else:
        paths = _git_files(root) or _walk(root, extra)
    out: list[Candidate] = []
    for path in paths:
        try:
            path.relative_to(root)
            path = local_file_path(path)
            if not path.is_relative_to(root) and path != root:
                continue
        except (ValueError, OSError, InputError):
            continue
        parent_parts = path.relative_to(root).parts[:-1] if path != root else ()
        if any(part in EXCLUDED_DIRS for part in parent_parts):
            continue
        if is_excluded_name(path.name, extra):
            continue
        kind = classify(path)
        if kind is None:
            continue
        try:
            st = path.stat()
        except OSError:
            continue
        if not stat.S_ISREG(st.st_mode):
            continue
        out.append(Candidate(path=path, kind=kind, size=st.st_size, mtime=st.st_mtime, cloud_only=is_cloud_only(st)))
    out.sort(key=lambda c: str(c.path).lower())
    return out


@dataclass
class TextChunk:
    text: str
    start_line: int  # 1-based, inclusive
    end_line: int


def chunk_text(text: str, max_lines: int = 60, overlap: int = 10, max_chars: int = 3000) -> list[TextChunk]:
    """Trocea por líneas con solape. Corta antes si un trozo supera `max_chars`.

    En Markdown prefiere empezar trozo en un encabezado cuando cae dentro de la ventana.
    """
    lines = text.splitlines()
    if not lines:
        return []
    chunks: list[TextChunk] = []
    start = 0
    n = len(lines)
    overlap = max(0, min(overlap, max_lines - 1))
    while start < n:
        end = start
        chars = 0
        while end < n and end - start < max_lines:
            line_len = len(lines[end]) + 1
            if chars + line_len > max_chars and end > start:
                break
            chars += line_len
            end += 1
        # Una línea gigante (minificado): se parte por caracteres.
        if end == start + 1 and len(lines[start]) > max_chars:
            long_line = lines[start]
            for i in range(0, len(long_line), max_chars):
                chunks.append(TextChunk(long_line[i : i + max_chars], start + 1, start + 1))
            start += 1
            continue
        # Cortar en el último encabezado de la segunda mitad, si lo hay.
        if end < n:
            for j in range(end - 1, start + (end - start) // 2, -1):
                if lines[j].lstrip().startswith("#") and lines[j].lstrip("#").startswith(" "):
                    end = j
                    break
        body = "\n".join(lines[start:end]).strip("\n")
        if body.strip():
            chunks.append(TextChunk(body, start + 1, end))
        if end >= n:
            break
        start = max(end - overlap, start + 1)
    return chunks


def read_text_file(path: Path, max_bytes: int) -> str | None:
    """Lee texto UTF-8 (con reserva latin-1). None si es binario o demasiado grande."""
    try:
        from .access import local_file_path
        path = local_file_path(path)
        size = path.stat().st_size
        if size > max_bytes:
            return None
        from .access import open_local_file
        with open_local_file(path) as file:
            raw = file.read(max_bytes + 1)
        if len(raw) > max_bytes:
            return None
    except OSError:
        return None
    if looks_binary(raw[:8192]):
        return None
    try:
        return raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        return raw.decode("latin-1")


def notebook_text(raw: str) -> str:
    """Celdas de un .ipynb como texto plano (sin salidas)."""
    import json

    try:
        nb = json.loads(raw)
    except ValueError:
        return raw
    if not isinstance(nb, dict) or not isinstance(nb.get("cells"), list):
        return raw
    cells = []
    for cell in nb["cells"]:
        if not isinstance(cell, dict):
            continue
        src = cell.get("source", "")
        cells.append("".join(src) if isinstance(src, list) else str(src))
    return "\n\n".join(cells)
