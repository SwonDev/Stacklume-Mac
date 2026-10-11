"""Lectura de medios para el worker: rutas, URLs y data URIs; imagen, audio, vídeo y páginas de PDF.

El vídeo y el audio se decodifican con PyAV (trae FFmpeg dentro), así que no hace falta torchcodec
ni las DLL de FFmpeg en Windows. Se entregan al modelo como arrays con sus metadatos, igual que hace
sentence-transformers con sus decodificadores.
"""

from __future__ import annotations

import base64
import binascii
import mimetypes
import os
import shutil
import tempfile
import time
from pathlib import Path
from urllib.parse import unquote, urlparse

import numpy as np
from PIL import Image, ImageOps

from .inputs import InputError

SAMPLE_RATE = 16_000
MAX_FRAME_SIDE = 1024
DOWNLOAD_DEADLINE_S = 300

_MIME_EXT = {
    "image/png": ".png",
    "image/jpeg": ".jpg",
    "image/jpg": ".jpg",
    "image/webp": ".webp",
    "image/gif": ".gif",
    "image/bmp": ".bmp",
    "audio/wav": ".wav",
    "audio/x-wav": ".wav",
    "audio/wave": ".wav",
    "audio/mpeg": ".mp3",
    "audio/mp3": ".mp3",
    "audio/flac": ".flac",
    "audio/ogg": ".ogg",
    "audio/webm": ".webm",
    "audio/mp4": ".m4a",
    "audio/aac": ".aac",
    "video/mp4": ".mp4",
    "video/webm": ".webm",
    "video/quicktime": ".mov",
    "video/x-matroska": ".mkv",
    "application/pdf": ".pdf",
}


class MediaError(InputError):
    pass


def is_unc(path: str) -> bool:
    """Rutas de red (\\servidor\recurso): abrirlas haría que Windows enviase el hash NTLM al servidor."""
    return path.startswith(("\\\\", "//"))


def clean_tmp_root(root: Path) -> None:
    """Borra temporales huérfanos de workers anteriores (p. ej., si se mataron a mitad de una descarga)."""
    if root.exists():
        for child in root.glob("egemma-*"):
            shutil.rmtree(child, ignore_errors=True)


class MediaResolver:
    """Convierte `src` (ruta, URL o data URI) en una ruta local. Los temporales se borran al cerrar."""

    def __init__(self, max_bytes: int, tmp_root: Path | None = None):
        self.max_bytes = max_bytes
        if tmp_root is not None:
            tmp_root.mkdir(parents=True, exist_ok=True)
        self._tmp = tempfile.TemporaryDirectory(prefix="egemma-", dir=tmp_root)
        self._cache: dict[str, str] = {}

    def close(self) -> None:
        self._tmp.cleanup()

    def __enter__(self) -> "MediaResolver":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def _tmp_file(self, suffix: str) -> Path:
        fd, name = tempfile.mkstemp(suffix=suffix, dir=self._tmp.name)
        os.close(fd)
        return Path(name)

    def local_path(self, src: str) -> str:
        if src in self._cache:
            return self._cache[src]
        if src.startswith("data:"):
            out = self._from_data_uri(src)
        elif src.startswith(("http://", "https://")):
            out = self._download(src)
        else:
            from .access import local_file_path
            path = local_file_path(src)
            if not path.is_file():
                raise MediaError(f"no existe el fichero «{src}»")
            if path.stat().st_size > self.max_bytes:
                raise MediaError(f"«{src}» supera el máximo de {self.max_bytes // 2**20} MB")
            from .access import open_local_file
            snapshot = self._tmp_file(path.suffix)
            try:
                with open_local_file(path) as source, snapshot.open("wb") as target:
                    count = 0
                    while block := source.read(64 * 1024):
                        count += len(block)
                        if count > self.max_bytes:
                            raise MediaError("El archivo supera el tamaño máximo")
                        target.write(block)
            except Exception:
                snapshot.unlink(missing_ok=True)
                raise
            out = str(snapshot)
        self._cache[src] = out
        return out

    def _from_data_uri(self, uri: str) -> str:
        header, sep, payload = uri.partition(",")
        if not sep or ";base64" not in header:
            raise MediaError("data URI no válida: se esperaba data:<mime>;base64,<datos>")
        mime = header[5:].split(";")[0].lower()
        try:
            raw = base64.b64decode(payload, validate=False)
        except (binascii.Error, ValueError) as exc:
            raise MediaError("base64 no válido en la data URI") from exc
        if len(raw) > self.max_bytes:
            raise MediaError("la data URI supera el tamaño máximo")
        suffix = _MIME_EXT.get(mime) or mimetypes.guess_extension(mime) or ".bin"
        path = self._tmp_file(suffix)
        path.write_bytes(raw)
        return str(path)

    def _download(self, url: str) -> str:
        from .public_http import open_public
        import http.client

        suffix = Path(urlparse(url).path).suffix.lower()[:8]
        deadline = time.monotonic() + DOWNLOAD_DEADLINE_S
        conn = None
        path = None
        try:
            conn, resp = open_public(url)
            if not suffix:
                ctype = (resp.getheader("Content-Type") or "").split(";")[0].strip().lower()
                suffix = _MIME_EXT.get(ctype, ".bin")
            declared = resp.getheader("Content-Length")
            if declared is not None and (not declared.isdecimal() or int(declared) > self.max_bytes):
                raise MediaError("El medio supera el tamaño máximo o declara un tamaño no válido")
            path = self._tmp_file(suffix)
            size = 0
            with path.open("wb") as fh:
                while block := resp.read(64 * 1024):
                    size += len(block)
                    if time.monotonic() > deadline:
                        raise MediaError("La descarga del medio superó el tiempo máximo")
                    if size > self.max_bytes:
                        raise MediaError("El medio supera el tamaño máximo")
                    fh.write(block)
            return str(path)
        except (OSError, http.client.HTTPException) as exc:
            if path is not None:
                path.unlink(missing_ok=True)
            raise MediaError("No se pudo descargar el medio público") from exc
        except Exception:
            if path is not None:
                path.unlink(missing_ok=True)
            raise
        finally:
            if conn is not None:
                conn.close()


# -- imagen --------------------------------------------------------------------
def load_image(path: str) -> Image.Image:
    try:
        img = Image.open(path)
        img.seek(0)  # GIF/APNG: primer fotograma
        img = ImageOps.exif_transpose(img) or img
        if img.mode in ("RGBA", "LA", "P"):
            rgba = img.convert("RGBA")
            background = Image.new("RGB", rgba.size, (255, 255, 255))
            background.paste(rgba, mask=rgba.getchannel("A"))
            return background
        return img.convert("RGB")
    except (OSError, ValueError, Image.DecompressionBombError) as exc:
        raise MediaError(f"no se pudo abrir la imagen «{Path(path).name}»: {exc}") from exc


def pdf_page_count(path: str) -> int:
    import pypdfium2 as pdfium

    pdf = pdfium.PdfDocument(path)
    try:
        return len(pdf)
    finally:
        pdf.close()


def load_pdf_page(path: str, page: int, max_side: int = MAX_FRAME_SIDE) -> Image.Image:
    """Renderiza la página `page` (desde 1) como imagen, para documentos escaneados o muy visuales."""
    import pypdfium2 as pdfium

    try:
        pdf = pdfium.PdfDocument(path)
    except Exception as exc:  # pdfium lanza PdfiumError
        raise MediaError(f"no se pudo abrir el PDF «{Path(path).name}»: {exc}") from exc
    try:
        if not 1 <= page <= len(pdf):
            raise MediaError(f"el PDF tiene {len(pdf)} páginas; pediste la {page}")
        pg = pdf[page - 1]
        width, height = pg.get_size()
        scale = max_side / max(width, height, 1)
        bitmap = pg.render(scale=scale)
        return bitmap.to_pil().convert("RGB")
    finally:
        pdf.close()


# -- audio y vídeo -------------------------------------------------------------
def _open(path: str):
    import av

    try:
        return av.open(path)
    except Exception as exc:  # av.error.FFmpegError y derivados
        raise MediaError(f"no se pudo abrir «{Path(path).name}»: {exc}") from exc


def _real_video_stream(container):
    from av.stream import Disposition

    for stream in container.streams.video:
        try:
            if stream.disposition & Disposition.attached_pic:
                continue  # carátula de un mp3/m4a
        except (AttributeError, TypeError):
            pass
        return stream
    return None


def _duration(container, stream) -> float | None:
    if stream is not None and stream.duration is not None and stream.time_base is not None:
        return float(stream.duration * stream.time_base)
    if container.duration is not None:
        return float(container.duration) / 1_000_000
    return None


def probe(path: str) -> dict:
    container = _open(path)
    try:
        video = _real_video_stream(container)
        audio = container.streams.audio[0] if container.streams.audio else None
        duration = _duration(container, video or audio)
        return {
            "duration": duration,
            "audio_duration": _duration(container, audio) if audio is not None else None,
            "has_video": video is not None,
            "has_audio": audio is not None,
            "fps": float(video.average_rate) if video is not None and video.average_rate else None,
        }
    finally:
        container.close()


def load_audio(
    path: str, start: float | None = None, end: float | None = None, max_seconds: float | None = None
) -> np.ndarray:
    """Audio mono a 16 kHz en float32, opcionalmente solo el tramo [start, end).

    Con `max_seconds`, deja de decodificar en cuanto lo supera y avisa, en vez de cargar horas de audio
    en memoria para rechazarlas después.
    """
    import av

    container = _open(path)
    try:
        if not container.streams.audio:
            raise MediaError(f"«{Path(path).name}» no tiene pista de audio")
        stream = container.streams.audio[0]
        start = start or 0.0
        if start > 0:
            container.seek(int(start / stream.time_base), stream=stream, backward=True, any_frame=False)
        resampler = av.AudioResampler(format="flt", layout="mono", rate=SAMPLE_RATE)
        pieces: list[np.ndarray] = []
        first_t: float | None = None
        decoded = 0
        # Margen de 2 s: el decodificador puede empezar algo antes de `start` tras el seek.
        limit = None if max_seconds is None else int((max_seconds + 2.0) * SAMPLE_RATE)
        for frame in container.decode(stream):
            if frame.pts is not None and first_t is None:
                first_t = float(frame.pts * stream.time_base)
            if end is not None and frame.pts is not None and float(frame.pts * stream.time_base) >= end:
                break
            for out in resampler.resample(frame):
                piece = out.to_ndarray().reshape(-1)
                pieces.append(piece)
                decoded += piece.size
            if limit is not None and decoded > limit:
                raise MediaError(
                    f"el audio de «{Path(path).name}» pasa de {max_seconds:.0f} s, lo que cabe en el contexto: "
                    "pide un tramo con start/end o indexa el fichero, que ya lo trocea"
                )
        for out in resampler.resample(None):
            pieces.append(out.to_ndarray().reshape(-1))
    except av.error.FFmpegError as exc:
        raise MediaError(f"no se pudo decodificar el audio de «{Path(path).name}»: {exc}") from exc
    finally:
        container.close()
    if not pieces:
        raise MediaError(f"«{Path(path).name}» no tiene audio decodificable en ese tramo")
    samples = np.concatenate(pieces).astype(np.float32, copy=False)
    offset = int(round((start - (first_t or 0.0)) * SAMPLE_RATE))
    if offset > 0:
        samples = samples[offset:]
    if end is not None:
        samples = samples[: max(0, int(round((end - start) * SAMPLE_RATE)))]
    if samples.size < SAMPLE_RATE // 10:
        raise MediaError(f"el tramo de audio de «{Path(path).name}» es demasiado corto")
    return samples


def frame_times(
    start: float, end: float, fps: float, max_frames: int, overflow: str = "uniform"
) -> list[float]:
    """Instantes a muestrear en [start, end): `fps` por segundo y, si sobran, recorte uniforme o por la cola."""
    if fps <= 0:
        raise MediaError("fps debe ser mayor que 0")
    span = max(0.0, end - start)
    count = max(1, int(np.floor(span * fps + 1e-9)))
    times = [start + i / fps for i in range(count)]
    if len(times) > max_frames:
        if overflow == "truncate":
            times = times[:max_frames]
        else:
            idx = np.linspace(0, len(times) - 1, max_frames).round().astype(int)
            times = [times[i] for i in idx]
    return times


def load_video(
    path: str,
    start: float | None = None,
    end: float | None = None,
    fps: float = 1.0,
    max_frames: int = 32,
    overflow: str = "uniform",
    max_side: int = MAX_FRAME_SIDE,
) -> dict:
    """Fotogramas RGB del tramo pedido con sus metadatos, en el formato de sentence-transformers."""
    container = _open(path)
    try:
        stream = _real_video_stream(container)
        if stream is None:
            raise MediaError(f"«{Path(path).name}» no tiene pista de vídeo")
        native_fps = float(stream.average_rate) if stream.average_rate else 25.0
        duration = _duration(container, stream) or 0.0
        s = start or 0.0
        e = min(end, duration) if end is not None and duration else (end or duration)
        if not e or e <= s:
            e = s + 1.0 / fps
        targets = frame_times(s, e, fps, max_frames, overflow)
        frames, indices = _decode_at(container, stream, targets, max_side)
    finally:
        container.close()
    if not frames:
        raise MediaError(f"no se pudo extraer ningún fotograma de «{Path(path).name}»")
    return {
        "array": np.stack(frames),
        "video_metadata": {
            "fps": native_fps,
            "total_num_frames": max(int(round(duration * native_fps)), (indices[-1] + 1) if indices else 1),
            "duration": duration,
            "frames_indices": indices,
        },
    }


def _decode_at(container, stream, targets: list[float], max_side: int) -> tuple[list[np.ndarray], list[int]]:
    """Decodifica el fotograma más cercano a cada instante. Si hay mucho hueco entre instantes, salta (seek)."""
    import av

    native_fps = float(stream.average_rate) if stream.average_rate else 25.0
    frames: list[np.ndarray] = []
    indices: list[int] = []
    iterator = None
    last_t = -1.0
    for target in targets:
        if iterator is None or target - last_t > 5.0:
            container.seek(int(target / stream.time_base), stream=stream, backward=True, any_frame=False)
            iterator = container.decode(stream)
        picked = None
        try:
            for frame in iterator:
                if frame.pts is None:
                    continue
                t = float(frame.pts * stream.time_base)
                last_t = t
                if t + 0.5 / native_fps >= target:
                    picked = frame
                    break
        except av.error.FFmpegError:
            picked = None
        if picked is None:
            break
        w, h = picked.width, picked.height
        scale = min(1.0, max_side / max(w, h, 1))
        frames.append(
            picked.to_ndarray(format="rgb24", width=max(2, int(w * scale)) // 2 * 2, height=max(2, int(h * scale)) // 2 * 2)
        )
        indices.append(int(round(last_t * native_fps)))
    return frames, indices
