"""Utilidades de rutas sin dependencias pesadas (las usa también el hook de inicio de sesión)."""

from __future__ import annotations

import os
from pathlib import Path


def path_key(path: str | Path) -> str:
    return os.path.normcase(os.path.abspath(str(path)))


def is_under(key: str, root_key: str) -> bool:
    """¿`key` es `root_key` o está dentro? Ambas normalizadas con `path_key`.

    Compara con separador: `C:\\proj-old` no está dentro de `C:\\proj`.
    """
    return key == root_key or key.startswith(root_key.rstrip("\\/") + os.sep)
