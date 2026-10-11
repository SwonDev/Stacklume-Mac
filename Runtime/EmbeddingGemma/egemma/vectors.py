"""Operaciones sobre vectores: recorte Matryoshka, normalización y codificación base64."""

from __future__ import annotations

import base64

import numpy as np


def truncate_normalize(vectors: np.ndarray, dim: int) -> np.ndarray:
    """Recorta a las `dim` primeras dimensiones y vuelve a normalizar (L2) en float32.

    Recortar un vector unitario no conserva la norma: sin renormalizar, el coseno da valores
    verosímiles pero el orden de los resultados se degrada en silencio.
    """
    vectors = np.asarray(vectors, dtype=np.float32)
    if vectors.ndim == 1:
        vectors = vectors[None, :]
    cut = vectors[:, :dim]
    norms = np.linalg.norm(cut, axis=1, keepdims=True)
    norms[norms == 0] = 1.0
    return (cut / norms).astype(np.float32)


def to_base64(vector: np.ndarray) -> str:
    """Formato `encoding_format=base64` de OpenAI: float32 little-endian."""
    return base64.b64encode(np.asarray(vector, dtype="<f4").tobytes()).decode("ascii")


def cosine_matrix(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    """Similitud coseno entre filas; asume vectores ya normalizados."""
    return np.asarray(a, dtype=np.float32) @ np.asarray(b, dtype=np.float32).T
