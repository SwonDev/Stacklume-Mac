"""Adaptador del worker global al motor MLX BF16 ya validado en Cryalis."""
from __future__ import annotations

import os
import time
from types import SimpleNamespace

import numpy as np

from . import media
from .config import Config, NATIVE_DIM
from .inputs import InputError
from .motor_mlx import Motor
from .worker import ModelRunner


class MLXRunner(ModelRunner):
    def __init__(self, cfg: Config):
        from .config import home_dir

        cfg.validate()
        self.cfg = cfg
        self.resolver_max_bytes = cfg.max_media_file_mb * 2**20
        self.tmp_root = home_dir() / "tmp"
        media.clean_tmp_root(self.tmp_root)
        self.motor = Motor(SimpleNamespace(datos={"revision": cfg.mlx_revision}, dim=NATIVE_DIM))
        started = time.monotonic()
        self.motor.cargar()
        self.load_seconds = round(time.monotonic() - started, 2)

    def info(self) -> dict:
        state = self.motor.estado()
        return {
            "model": self.cfg.model, "weights": self.cfg.mlx_model,
            "revision": self.cfg.mlx_revision, "backend": "mlx", "device": "mlx",
            "dtype": "bfloat16", "modalities": list(self.cfg.modalities),
            "load_seconds": self.load_seconds, "pid": os.getpid(),
            "vram_gb": round(state.get("mlx_activos_bytes", 0) / 2**30, 3),
            "motor": state,
        }

    def encode(self, items: list[dict], opts: dict) -> dict:
        import mlx.core as mx
        from transformers.video_utils import VideoMetadata

        self.motor.cargar(any(p["type"] == "audio" for item in items for p in item["parts"]))
        processor = self.motor.procesador
        out = np.zeros((len(items), NATIVE_DIM), dtype=np.float32)
        text_tokens = 0
        with media.MediaResolver(self.resolver_max_bytes, self.tmp_root) as resolver:
            for i, item in enumerate(items):
                value, _ = self._to_model_input(item, resolver, opts)
                kwargs = {"return_tensors": "mlx"}
                if isinstance(value, str):
                    text = (item.get("prompt") or "") + value
                    inputs = processor.tokenizer([text], padding=True, return_tensors="np")
                    inputs = {k: mx.array(v) for k, v in inputs.items()}
                else:
                    text = value.get("text")
                    if text:
                        text = (item.get("prompt") or "") + text
                    if "image" in value:
                        images = value["image"]
                        kwargs["images"] = images if isinstance(images, list) else [images]
                        kwargs["images_kwargs"] = {"max_soft_tokens": opts.get("image_tokens") or 280}
                    if "audio" in value:
                        audio = value["audio"]
                        audio = audio if isinstance(audio, list) else [audio]
                        kwargs["audio"] = [a["array"] for a in audio]
                        kwargs["sampling_rate"] = media.SAMPLE_RATE
                    if "video" in value:
                        videos = value["video"]
                        videos = videos if isinstance(videos, list) else [videos]
                        kwargs["videos"] = [v["array"] for v in videos]
                        kwargs["videos_kwargs"] = {
                            "video_metadata": [VideoMetadata(**v["video_metadata"]) for v in videos],
                            "do_sample_frames": False,
                            "max_soft_tokens": opts.get("video_tokens") or 140,
                            "add_timestamps": bool(opts.get("video_timestamps")),
                        }
                    inputs = processor(text=text, **kwargs)
                if inputs["input_ids"].shape[1] > 8192:
                    raise InputError("La entrada supera los 8 192 tokens; divídela en fragmentos")
                text_tokens += sum(
                    len(processor.tokenizer(p["text"], add_special_tokens=False)["input_ids"])
                    for p in item["parts"] if p["type"] == "text"
                )
                vector = self.motor.modelo(**inputs).text_embeds
                mx.eval(vector)
                out[i] = np.asarray(vector[0]).astype(np.float32)
        norms = np.linalg.norm(out, axis=1, keepdims=True)
        if not np.isfinite(out).all() or (norms < 1e-12).any():
            raise RuntimeError("El modelo devolvió un vector no finito o nulo")
        return {"vectors": (out / norms).astype(np.float32), "text_tokens": text_tokens}
