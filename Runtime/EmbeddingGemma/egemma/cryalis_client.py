"""Compatibilidad del índice de Cryalis con el único worker global de egemma."""
from __future__ import annotations

from pathlib import Path
import numpy as np
from .client import Client
from .files import AUDIO_EXT, VIDEO_EXT
from .motor_mlx import Motor as LocalMotor, formatear


class Motor(LocalMotor):
    def __init__(self, config):
        super().__init__(config)
        self.client = Client(timeout=5500)
        self._uso_global = False

    def codificar(self, muestras, tarea="documento"):
        inputs = []
        for muestra in muestras:
            if "archivo" not in muestra:
                inputs.append(formatear(muestra, tarea))
                continue
            path = Path(muestra["archivo"])
            kind = "audio" if path.suffix.lower() in AUDIO_EXT else ("video" if path.suffix.lower() in VIDEO_EXT else "image")
            value = {kind: str(path)}
            if muestra.get("texto"):
                value["text"] = formatear(muestra, tarea) + f" <|{kind}|>"
            inputs.append(value)
        result = self.client.post("/embed", {
            "inputs": inputs, "task": None, "dimensions": self.config.dim,
            "video_max_frames": self.config.datos.get("max_frames", 8),
            "video_tokens": 140, "video_timestamps": True,
        })
        self._uso_global = True
        return np.asarray(result["embeddings"], dtype=np.float32)

    def estado(self):
        if not self._uso_global:
            return {**super().estado(), "servicio_global": self.client.base_url}
        engine = (self.client.health() or {}).get("engine", {})
        info = engine.get("worker") or {}
        state = info.get("motor") or {}
        return {
            "cargado": bool(engine.get("loaded")),
            "cargas": engine.get("loads", 0),
            "audio_cargado": state.get("audio_cargado", False),
            "cargas_audio": state.get("cargas_audio", 0),
            "instancia_modelo": state.get("instancia_modelo"),
            "instancia_texto": state.get("instancia_texto"),
            "instancia_vision": state.get("instancia_vision"),
            "segundos_carga": info.get("load_seconds", 0),
            "mlx_activos_bytes": state.get("mlx_activos_bytes", 0),
            "mlx_pico_bytes": state.get("mlx_pico_bytes", 0),
            "servicio_global": self.client.base_url,
            "pid_worker": info.get("pid"),
        }
