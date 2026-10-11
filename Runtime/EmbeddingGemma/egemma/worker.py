"""Proceso hijo que carga EmbeddingGemma 2 y atiende peticiones del servidor por stdin/stdout.

Vive en un proceso aparte para poder cerrarlo cuando no se usa y devolver toda la VRAM (incluido el
contexto CUDA), sin tirar el servidor HTTP.
"""

from __future__ import annotations

import dataclasses
import gc
import json
import os
import sys
import time
import traceback
from typing import Any

import numpy as np

from . import media, protocol
from .config import NATIVE_DIM, Config, home_dir
from .inputs import InputError

CONTEXT_TOKENS = 8192
TOKENS_PER_AUDIO_SECOND = 25
DEFAULT_IMAGE_TOKENS = 280
DEFAULT_FRAME_TOKENS = 140


def _log(msg: str) -> None:
    print(f"[worker {time.strftime('%H:%M:%S')}] {msg}", file=sys.stderr, flush=True)


class ModelRunner:
    def __init__(self, cfg: Config):
        import torch
        from sentence_transformers import SentenceTransformer

        self.cfg = cfg
        self.torch = torch
        started = time.time()
        self.device = self._pick_device(cfg.device)
        self.dtype = self._pick_dtype(cfg.dtype, self.device)
        config_kwargs: dict[str, Any] = {}
        if "audio" not in cfg.modalities:
            config_kwargs["audio_config"] = None
        if "image" not in cfg.modalities and "video" not in cfg.modalities:
            config_kwargs["vision_config"] = None
        self.model = SentenceTransformer(
            cfg.model,
            device=self.device,
            model_kwargs={"dtype": self.dtype},
            config_kwargs=config_kwargs,
        )
        self.model.eval()
        self.load_seconds = round(time.time() - started, 2)
        self.resolver_max_bytes = cfg.max_media_file_mb * 2**20
        self.tmp_root = home_dir() / "tmp"
        media.clean_tmp_root(self.tmp_root)
        _log(f"modelo cargado en {self.load_seconds} s ({self.device}, {self.dtype})")

    def _pick_device(self, wanted: str) -> str:
        torch = self.torch
        if wanted != "auto":
            return wanted
        if torch.cuda.is_available():
            return "cuda"
        if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
            return "mps"
        return "cpu"

    def _pick_dtype(self, wanted: str, device: str):
        torch = self.torch
        if wanted == "float32":
            return torch.float32
        if wanted == "bfloat16":
            return torch.bfloat16
        # auto: bf16 donde hay soporte nativo (CUDA); float32 en el resto, también en Apple Silicon, donde
        # bf16 no es nativo en todas las GPU y el modelo (740M) cabe de sobra. Nunca float16: da NaN.
        if device == "cuda" and torch.cuda.is_bf16_supported():
            return torch.bfloat16
        return torch.float32

    def _empty_cache(self) -> None:
        torch = self.torch
        if self.device == "cuda":
            torch.cuda.empty_cache()
        elif self.device == "mps":
            torch.mps.empty_cache()

    def info(self) -> dict:
        torch = self.torch
        vram = None
        if self.device == "cuda":
            vram = round(torch.cuda.memory_allocated() / 2**30, 2)
        elif self.device == "mps":
            vram = round(torch.mps.current_allocated_memory() / 2**30, 2)
        return {
            "model": self.cfg.model,
            "device": self.device,
            "gpu": torch.cuda.get_device_name(0) if self.device == "cuda" else None,
            "dtype": str(self.dtype).replace("torch.", ""),
            "modalities": list(self.cfg.modalities),
            "load_seconds": self.load_seconds,
            "vram_gb": vram,
            "pid": os.getpid(),
        }

    # -- preparación de entradas ---------------------------------------------
    def _check_modalities(self, item: dict) -> None:
        for part in item["parts"]:
            kind = "image" if part["type"] == "pdf_page" else part["type"]
            if kind not in self.cfg.modalities:
                raise InputError(f"la modalidad «{kind}» está desactivada en config.json (modalities)")

    def _to_model_input(self, item: dict, resolver: media.MediaResolver, opts: dict) -> tuple[Any, int]:
        """Elemento interno → entrada de sentence-transformers, más una estimación de tokens multimodales."""
        self._check_modalities(item)
        image_tokens = opts.get("image_tokens") or DEFAULT_IMAGE_TOKENS
        frame_tokens = opts.get("video_tokens") or DEFAULT_FRAME_TOKENS
        values: dict[str, list] = {}
        texts: list[str] = []
        segments: list[str] = []  # texto con marcadores en el orden original
        budget = 0
        has_text = any(p["type"] == "text" for p in item["parts"])
        user_placeholders = has_text and any(
            tag in p.get("text", "") for p in item["parts"] for tag in ("<|image|>", "<|audio|>", "<|video|>")
        )
        for part in item["parts"]:
            kind = part["type"]
            if kind == "text":
                texts.append(part["text"])
                segments.append(part["text"])
                continue
            path = resolver.local_path(part["src"])
            if kind == "image":
                value: Any = media.load_image(path)
                budget += image_tokens
                tag = "image"
            elif kind == "pdf_page":
                value = media.load_pdf_page(path, part["page"])
                budget += image_tokens
                tag = "image"
            elif kind == "audio":
                room = max(1.0, (CONTEXT_TOKENS - budget) / TOKENS_PER_AUDIO_SECOND)
                samples = media.load_audio(path, part.get("start"), part.get("end"), max_seconds=room)
                budget += int(len(samples) / media.SAMPLE_RATE * TOKENS_PER_AUDIO_SECOND)
                value = {"array": samples, "sampling_rate": media.SAMPLE_RATE}
                tag = "audio"
            elif kind == "video":
                value = media.load_video(
                    path,
                    part.get("start"),
                    part.get("end"),
                    fps=float(opts.get("video_fps") or 1.0),
                    max_frames=int(opts.get("video_max_frames") or 32),
                    overflow=opts.get("video_overflow") or "uniform",
                )
                budget += len(value["array"]) * frame_tokens
                tag = "video"
            else:
                raise InputError(f"tipo de parte desconocido: {kind}")
            values.setdefault(tag, []).append(value)
            segments.append(f"<|{tag}|>")
        text_estimate = sum(len(t) for t in texts) // 3
        if budget + text_estimate > CONTEXT_TOKENS:
            raise InputError(
                f"la entrada ocupa unos {budget + text_estimate} tokens y el contexto es de {CONTEXT_TOKENS}: "
                "usa tramos (start/end), menos fotogramas (video_max_frames) o menos tokens por imagen"
            )
        if not values:
            return " ".join(texts), budget
        if has_text:
            text = " ".join(texts) if user_placeholders else " ".join(segments)
            return {"text": text, **values}, budget
        return {k: (v[0] if len(v) == 1 else v) for k, v in values.items()}, budget

    def _batch_size(self, cls: str) -> int:
        base = max(1, int(self.cfg.batch_size))
        return {"text": base, "image": max(1, base // 2), "audio": min(4, base), "video": 1}[cls]

    @staticmethod
    def _class(item: dict) -> str:
        kinds = {p["type"] for p in item["parts"]}
        if "video" in kinds:
            return "video"
        if "audio" in kinds:
            return "audio"
        if kinds & {"image", "pdf_page"}:
            return "image"
        return "text"

    # -- operaciones -----------------------------------------------------------
    def encode(self, items: list[dict], opts: dict) -> dict:
        processing: dict[str, dict] = {"video": {"do_sample_frames": False}}
        if opts.get("image_tokens"):
            processing["image"] = {"max_soft_tokens": int(opts["image_tokens"])}
        if opts.get("video_tokens"):
            processing["video"]["max_soft_tokens"] = int(opts["video_tokens"])
        if opts.get("video_timestamps"):
            processing["video"]["add_timestamps"] = True

        out = np.zeros((len(items), NATIVE_DIM), dtype=np.float32)
        groups: dict[tuple[str | None, str], list[int]] = {}
        for i, item in enumerate(items):
            groups.setdefault((item.get("prompt"), self._class(item)), []).append(i)

        text_tokens = 0
        with media.MediaResolver(self.resolver_max_bytes, self.tmp_root) as resolver:
            for (prompt, cls), indices in groups.items():
                batch_inputs = []
                for i in indices:
                    value, _ = self._to_model_input(items[i], resolver, opts)
                    batch_inputs.append(value)
                    text_tokens += sum(
                        len(self.model.tokenizer(p["text"], add_special_tokens=False)["input_ids"])
                        for p in items[i]["parts"]
                        if p["type"] == "text"
                    )
                vectors = self._encode_batch(batch_inputs, prompt, cls, processing)
                out[indices] = vectors
        if not np.isfinite(out).all():
            raise RuntimeError("el modelo devolvió NaN o infinitos (¿float16?)")
        # sentence-transformers normaliza en el dtype del modelo (bf16): la norma queda a ±0,4 % de 1.
        # La receta oficial normaliza en float32.
        norms = np.linalg.norm(out, axis=1, keepdims=True)
        norms[norms == 0] = 1.0
        out = (out / norms).astype(np.float32)
        self._empty_cache()
        return {"vectors": out, "text_tokens": text_tokens}

    def _encode_batch(self, inputs: list, prompt: str | None, cls: str, processing: dict) -> np.ndarray:
        torch = self.torch
        batch_size = self._batch_size(cls)
        kwargs: dict[str, Any] = {
            "batch_size": batch_size,
            "convert_to_numpy": True,
            "normalize_embeddings": True,
            "show_progress_bar": False,
        }
        if prompt:
            kwargs["prompt"] = prompt
        if cls in ("image", "video"):
            kwargs["processing_kwargs"] = processing
        try:
            with torch.inference_mode():
                return np.asarray(self.model.encode(inputs, **kwargs), dtype=np.float32)
        except torch.OutOfMemoryError:
            if batch_size == 1:
                raise
            _log(f"sin memoria con lotes de {batch_size}; reintento de uno en uno")
            gc.collect()
            self._empty_cache()
            kwargs["batch_size"] = 1
            with torch.inference_mode():
                return np.asarray(self.model.encode(inputs, **kwargs), dtype=np.float32)


def _config_from_env() -> Config:
    raw = json.loads(os.environ.get("EGEMMA_WORKER_CONFIG", "{}"))
    names = {f.name for f in dataclasses.fields(Config)}
    return Config(**{k: v for k, v in raw.items() if k in names})


def main() -> int:
    out = sys.stdout.buffer
    inp = sys.stdin.buffer
    sys.stdout = sys.stderr  # nada de prints en el canal del protocolo
    cfg = _config_from_env()
    try:
        if cfg.backend == "mlx":
            from .mlx_runner import MLXRunner
            runner = MLXRunner(cfg)
        else:
            runner = ModelRunner(cfg)
    except Exception as exc:  # noqa: BLE001 — cualquier fallo de carga se informa al servidor
        traceback.print_exc()
        protocol.send(out, {"ok": False, "kind": "load", "error": f"{type(exc).__name__}: {exc}"})
        return 1
    protocol.send(out, {"ok": True, "result": runner.info()})
    while True:
        try:
            request = protocol.recv(inp)
        except EOFError:
            break
        op = request.get("op")
        try:
            if op == "encode":
                result: Any = runner.encode(request["items"], request.get("options") or {})
                result["_worker_info"] = runner.info()
            elif op in ("probe", "pdf_pages"):
                with media.MediaResolver(runner.resolver_max_bytes, runner.tmp_root) as resolver:
                    path = resolver.local_path(request["path"])
                    result = media.probe(path) if op == "probe" else media.pdf_page_count(path)
            elif op == "info":
                result = runner.info()
            elif op == "exit":
                protocol.send(out, {"ok": True, "result": None})
                break
            else:
                raise InputError(f"operación desconocida: {op}")
            protocol.send(out, {"ok": True, "result": result})
        except InputError as exc:
            protocol.send(out, {"ok": False, "kind": "bad_input", "error": str(exc)})
        except Exception as exc:  # noqa: BLE001
            kind = "oom" if "OutOfMemory" in type(exc).__name__ else "internal"
            traceback.print_exc()
            protocol.send(out, {"ok": False, "kind": kind, "error": f"{type(exc).__name__}: {exc}"})
    return 0


if __name__ == "__main__":
    sys.exit(main())
