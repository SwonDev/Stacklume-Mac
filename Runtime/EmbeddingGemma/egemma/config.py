"""Configuración del servicio: valores por defecto, `config.json` y variables de entorno."""

from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass, field, fields
from pathlib import Path

MODEL_ID = "google/embeddinggemma-2"
MODEL_ALIAS = "embeddinggemma-2"
MLX_MODEL_ID = "mlx-community/embeddinggemma-2-bf16"
NATIVE_DIM = 768
MRL_DIMS = (768, 512, 256, 128)
MODALITIES = ("text", "image", "audio", "video")


def home_dir() -> Path:
    return Path(os.environ.get("EGEMMA_HOME", Path.home() / ".embeddinggemma")).expanduser()


@dataclass
class Config:
    backend: str = "mlx" if sys.platform == "darwin" else "torch"
    mlx_model: str = MLX_MODEL_ID
    mlx_revision: str = "1a4ffddb7905d3f63486748deabe091a01fb6201"
    host: str = "127.0.0.1"
    port: int = 8737
    model: str = MODEL_ID
    # auto | cuda | mps | cpu
    device: str = "auto"
    # auto | bfloat16 | float32. float16 está prohibido: el modelo da NaN o vectores degradados.
    dtype: str = "auto"
    # Torres que se cargan. Quitar "audio" ahorra 300M parámetros; quitar "image" y "video", 170M.
    modalities: list[str] = field(default_factory=lambda: list(MODALITIES))
    # Minutos sin uso antes de cerrar el proceso del modelo y liberar la VRAM. 0 = nunca.
    idle_unload_minutes: float = 10.0
    # Tiempo máximo de una petición al modelo; si se supera, se mata el worker y se relanza.
    request_timeout_s: float = 900.0
    batch_size: int = 16
    data_dir: str = ""
    # Leer un fichero de OneDrive «solo en la nube» lo descarga. Por defecto se salta.
    allow_onedrive_hydration: bool = False
    # Indexado
    max_text_file_kb: int = 1024
    max_media_file_mb: int = 2048
    chunk_lines: int = 60
    chunk_overlap_lines: int = 10
    chunk_max_chars: int = 3000
    audio_window_s: float = 30.0
    audio_overlap_s: float = 5.0
    video_window_s: float = 32.0
    extra_exclude: list[str] = field(default_factory=list)

    @property
    def data_path(self) -> Path:
        return Path(self.data_dir).expanduser() if self.data_dir else home_dir() / "data"

    @property
    def base_url(self) -> str:
        return f"http://{self.host}:{self.port}"

    def validate(self) -> None:
        if self.backend not in ("mlx", "torch"):
            raise ValueError("backend debe ser mlx o torch")
        if self.backend == "mlx" and (self.model != MODEL_ID or self.mlx_model != MLX_MODEL_ID):
            raise ValueError("MLX solo admite google/embeddinggemma-2 con pesos mlx-community/embeddinggemma-2-bf16; no se sustituye el modelo elegido")
        if self.dtype not in ("auto", "bfloat16", "float32"):
            raise ValueError(
                f"dtype «{self.dtype}» no válido: usa auto, bfloat16 o float32 (float16 da NaN en este modelo)"
            )
        if self.device not in ("auto", "cuda", "mps", "cpu"):
            raise ValueError(f"device «{self.device}» no válido: usa auto, cuda, mps o cpu")
        unknown = set(self.modalities) - set(MODALITIES)
        if unknown or "text" not in self.modalities:
            raise ValueError(f"modalities debe incluir «text» y solo puede tener {MODALITIES}")


_ENV_PREFIX = "EGEMMA_"


def load_config(path: Path | None = None) -> Config:
    """Carga `config.json` (si existe) y aplica encima las variables `EGEMMA_<CAMPO>`."""
    cfg = Config()
    path = path or home_dir() / "config.json"
    if path.exists():
        data = json.loads(path.read_text(encoding="utf-8"))
        names = {f.name for f in fields(Config)}
        for key, value in data.items():
            if key in names:
                setattr(cfg, key, value)
    for f in fields(Config):
        raw = os.environ.get(_ENV_PREFIX + f.name.upper())
        if raw is None:
            continue
        current = getattr(cfg, f.name)
        if isinstance(current, bool):
            value: object = raw.strip().lower() in ("1", "true", "yes", "si", "sí")
        elif isinstance(current, int):
            value = int(raw)
        elif isinstance(current, float):
            value = float(raw)
        elif isinstance(current, list):
            value = [x.strip() for x in raw.split(",") if x.strip()]
        else:
            value = raw
        setattr(cfg, f.name, value)
    cfg.validate()
    return cfg
