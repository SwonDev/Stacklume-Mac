"""Único adaptador de EmbeddingGemma 2: MLX BF16 y procesador oficial de la PR."""
import fcntl
import json
import os
import time

import numpy as np

from .config import MLX_MODEL_ID
MODELO = MLX_MODEL_ID
REVISION = "1a4ffddb7905d3f63486748deabe091a01fb6201"


class Motor:
    def __init__(self, config):
        self.config = config
        self.modelo = self.procesador = None
        self.audio = False
        self.cargas = 0
        self.cargas_audio = 0
        self.segundos_carga = 0
        self.cerrojo_pesos = None

    def cargar(self, audio=False):
        if self.modelo is not None and (self.audio or not audio):
            return
        if self.cerrojo_pesos is None:
            from pathlib import Path
            from .config import home_dir
            base = home_dir() / "locks"
            base.mkdir(mode=0o700,exist_ok=True)
            self.cerrojo_pesos=(base/"pesos.lock").open("a")
            try:
                fcntl.flock(self.cerrojo_pesos,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError:
                self.cerrojo_pesos.close();self.cerrojo_pesos=None
                raise RuntimeError("Otro demonio ya tiene los pesos cargados; no se duplica el modelo")
        import mlx.core as mx
        mx.set_cache_limit(32 * 2**20)
        from huggingface_hub import snapshot_download
        from mlx_vlm.embedding_loader import load_embedding_model
        from mlx_vlm.models.embedding_gemma2 import EmbeddingGemma2Processor
        inicio = time.monotonic()
        path = snapshot_download(MODELO, revision=self.config.datos.get("revision", REVISION),
                                 cache_dir=os.environ.get("HF_HUB_CACHE"), local_files_only=True)
        from pathlib import Path
        conf = json.loads(Path(path, "config.json").read_text())
        if self.modelo is not None:
            self._anadir_audio(Path(path), conf, mx)
            self.segundos_carga += time.monotonic() - inicio
            return
        # El núcleo se carga una vez; el audio se añade cuando llega su primera petición.
        conf["audio_config"] = None
        try:
            self.modelo = load_embedding_model(Path(path), config=conf)
            self._comprobar_bf16(mx)
            self.procesador = EmbeddingGemma2Processor.from_pretrained(path, local_files_only=True)
        except Exception:
            self.modelo = self.procesador = None
            raise
        self.cargas += 1
        if audio:
            self._anadir_audio(Path(path), json.loads(Path(path, "config.json").read_text()), mx)
        self.segundos_carga += time.monotonic() - inicio

    def _comprobar_bf16(self, mx):
        from mlx.utils import tree_flatten
        if any(v.dtype!=mx.bfloat16 for _,v in tree_flatten(self.modelo.parameters())
               if mx.issubdtype(v.dtype,mx.floating)):
            raise ValueError("Los pesos flotantes deben ser BF16; no se cambia la precisión")

    def _anadir_audio(self, path, conf, mx):
        from mlx_vlm.models.embedding_gemma2.config import ModelConfig
        from mlx_vlm.models.gemma4.audio import AudioEncoder
        from mlx_vlm.models.gemma4.gemma4 import MultimodalEmbedder
        anterior = self.modelo.config.audio_config
        cfg = ModelConfig.from_dict(conf).audio_config
        if cfg is None:
            raise ValueError("La revisión autorizada no contiene audio_config")
        try:
            self.modelo.config.audio_config = cfg
            self.modelo.audio_tower = AudioEncoder(cfg)
            self.modelo.embed_audio = MultimodalEmbedder(
                cfg.output_proj_dims or cfg.hidden_size, self.modelo.config.text_config.hidden_size,
                cfg.rms_norm_eps)
            pesos = {}
            for archivo in sorted(path.glob("*.safetensors")):
                pesos.update({k:v for k,v in mx.load(str(archivo)).items()
                              if k.removeprefix("model.").startswith(("audio_tower.","embed_audio."))})
            pesos = self.modelo.sanitize(pesos)
            for nombre in ("audio_tower","embed_audio"):
                modulo = getattr(self.modelo,nombre)
                prefijo = nombre + "."
                modulo.load_weights([(k.removeprefix(prefijo),v) for k,v in pesos.items()
                                     if k.startswith(prefijo)],strict=True)
                modulo.eval()
            self._comprobar_bf16(mx)
            mx.eval(self.modelo.audio_tower.parameters(), self.modelo.embed_audio.parameters())
        except Exception:
            self.modelo.audio_tower = self.modelo.embed_audio = None
            self.modelo.config.audio_config = anterior
            raise
        self.audio = True
        self.cargas_audio += 1

    def codificar(self, muestras, tarea="documento"):
        from pathlib import Path
        from .files import AUDIO_EXT as AUDIO, VIDEO_EXT as VIDEO
        requiere_audio = any(Path(m.get("archivo", "")).suffix.lower() in AUDIO for m in muestras)
        self.cargar(requiere_audio or self.audio)
        import mlx.core as mx
        from PIL import Image
        vectores = []
        if all("archivo" not in m for m in muestras):
            textos = [formatear(m,tarea) for m in muestras]
            inputs = self.procesador.tokenizer(textos, padding=True, return_tensors="np")
            if inputs["input_ids"].shape[1] > 8192:
                raise ValueError("La entrada supera los 8 192 tokens; divídela en fragmentos")
            v = self.modelo(**{k: mx.array(v) for k,v in inputs.items()}).text_embeds
            mx.eval(v)
            vectores = np.asarray(v).astype("float32")
        else:
            for m in muestras:
                p = Path(m["archivo"])
                kwargs = {"return_tensors": "mlx"}
                if p.suffix.lower() in AUDIO:
                    kwargs["audio"] = [str(p)]
                elif p.suffix.lower() in VIDEO:
                    kwargs.update(videos=[str(p)], fps=1, max_frames=self.config.datos.get("max_frames",8),
                                  overflow_strategy="uniform", add_timestamps=True, max_soft_tokens=140)
                else:
                    with Image.open(p) as im:
                        kwargs["images"] = [im.convert("RGB")]
                    kwargs["max_soft_tokens"] = 280
                # Los medios puros no llevan prefijo. Las entradas mixtas conservan el texto.
                texto = m.get("texto") or None
                if texto:
                    token = "audio" if "audio" in kwargs else ("video" if "videos" in kwargs else "image")
                    texto = formatear(m,tarea) + f" <|{token}|>"
                inputs = self.procesador(text=texto, **kwargs)
                if inputs["input_ids"].shape[1] > 8192:
                    raise ValueError("Los medios superan el contexto de 8 192 tokens")
                v = self.modelo(**inputs).text_embeds
                mx.eval(v)
                vectores.append(np.asarray(v[0]).astype("float32"))
        salida = np.asarray(vectores, dtype="float32")[:, :self.config.dim]
        if not np.isfinite(salida).all():
            raise ValueError("El modelo produjo un vector no finito")
        normas = np.linalg.norm(salida, axis=1, keepdims=True)
        if (normas < 1e-12).any():
            raise ValueError("El modelo produjo un vector nulo")
        return salida / normas

    def estado(self):
        if self.modelo is None:
            return {"cargado": False, "cargas": self.cargas}
        import mlx.core as mx
        return {"cargado": True, "audio_cargado": self.audio, "cargas": self.cargas,
                "cargas_audio": self.cargas_audio,
                "instancia_modelo": id(self.modelo), "instancia_texto": id(self.modelo.language_model),
                "instancia_vision": id(self.modelo.vision_tower),
                "segundos_carga": self.segundos_carga, "mlx_activos_bytes": mx.get_active_memory(),
                "mlx_pico_bytes": mx.get_peak_memory()}


def formatear(muestra,tarea):
    prefijos = {"consulta":"search result","codigo":"code retrieval",
                "similitud":"sentence similarity","agrupar":"clustering"}
    if tarea == "documento":
        return f"title: {muestra.get('titulo','none')} | text: {muestra.get('texto','')}"
    return f"task: {prefijos[tarea]} | query: {muestra['texto']}"
