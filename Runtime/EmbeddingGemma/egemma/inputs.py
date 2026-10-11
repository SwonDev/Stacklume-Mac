"""Normalización de entradas: de los formatos de la API al formato interno que entiende el worker.

Formato interno de un elemento (serializable y apto para pickle)::

    {"parts": [Part, ...], "prompt": str | None}

    Part = {"type": "text", "text": str}
         | {"type": "image", "src": str}
         | {"type": "audio", "src": str, "start": float | None, "end": float | None}
         | {"type": "video", "src": str, "start": float | None, "end": float | None}
         | {"type": "pdf_page", "src": str, "page": int}

`src` es una ruta local, una URL http(s) o una data URI (`data:image/png;base64,...`).
"""

from __future__ import annotations

from typing import Any

from .config import MRL_DIMS, NATIVE_DIM


class InputError(ValueError):
    """Entrada mal formada: la API la devuelve como 400."""


# Prefijos oficiales (config_sentence_transformers.json del modelo).
TASK_PROMPTS: dict[str, str] = {
    "query": "task: search result | query: ",
    "document": "title: none | text: ",
    "code_query": "task: code retrieval | query: ",
    "question": "task: question answering | query: ",
    "fact_check": "task: fact checking | query: ",
    "classification": "task: classification | query: ",
    "clustering": "task: clustering | query: ",
    "similarity": "task: sentence similarity | query: ",
}

# Nombres de prompt de sentence-transformers / MTEB → tarea propia.
TASK_ALIASES: dict[str, str] = {
    "searchquery": "query",
    "retrieval-query": "query",
    "retrieval": "query",
    "reranking": "query",
    "bitextmining": "query",
    "search": "query",
    "retrieval-document": "document",
    "doc": "document",
    "passage": "document",
    "coderetrieval": "code_query",
    "instructionretrieval": "code_query",
    "code": "code_query",
    "questionanswering": "question",
    "qa": "question",
    "factchecking": "fact_check",
    "multilabelclassification": "classification",
    "sentencesimilarity": "similarity",
    "sts": "similarity",
    "pairclassification": "similarity",
    "summarization": "similarity",
}

MEDIA_TYPES = ("image", "audio", "video", "pdf_page")
MAX_SOFT_TOKENS = (70, 140, 280, 560, 1120)


def resolve_task(task: str | None) -> str | None:
    """Devuelve el nombre canónico de la tarea, o None si no se quiere prefijo."""
    if task is None:
        return None
    key = task.strip()
    if key == "" or key.lower() in ("none", "raw", "ninguna"):
        return None
    if key in TASK_PROMPTS:
        return key
    alias = TASK_ALIASES.get(key.lower().replace(" ", "").replace("_", ""))
    if alias is None:
        alias = TASK_ALIASES.get(key.lower())
    if alias is None:
        raise InputError(
            f"Tarea «{task}» desconocida. Usa una de: {', '.join(TASK_PROMPTS)} o none"
        )
    return alias


def prompt_for(task: str | None, title: str | None = None) -> str | None:
    """Prefijo de texto para una tarea. Con `document` y título usa `title: {title} | text: `."""
    canonical = resolve_task(task)
    if canonical is None:
        return None
    if canonical == "document" and title:
        clean = " ".join(str(title).split())
        return f"title: {clean} | text: "
    return TASK_PROMPTS[canonical]


def split_task_suffix(model: str | None) -> tuple[str | None, str | None]:
    """`embeddinggemma-2:query` → (`embeddinggemma-2`, `query`). Útil para clientes que solo dejan elegir el modelo."""
    if not model or ":" not in model:
        return model, None
    base, _, suffix = model.partition(":")
    return base, suffix or None


def validate_dim(dim: int | None) -> int:
    if dim is None:
        return NATIVE_DIM
    if dim not in MRL_DIMS:
        raise InputError(f"dimensions debe ser una de {list(MRL_DIMS)} (Matryoshka); has pedido {dim}")
    return dim


def validate_soft_tokens(value: int | None, field: str) -> int | None:
    if value is None:
        return None
    if value not in MAX_SOFT_TOKENS:
        raise InputError(f"{field} debe ser uno de {list(MAX_SOFT_TOKENS)}")
    return value


def _media_src(value: Any, field: str, family: str = "image") -> str:
    if isinstance(value, str) and value.strip():
        return value.strip()
    if isinstance(value, dict):
        for key in ("url", "src", "path", "data"):
            inner = value.get(key)
            if isinstance(inner, str) and inner.strip():
                if key == "data" and not inner.startswith("data:"):
                    fmt = value.get("format") or value.get("mime")
                    if not fmt:
                        raise InputError(f"{field}: base64 sin «format»/«mime»; usa una data URI")
                    mime = fmt if "/" in fmt else f"{family}/{fmt}"
                    return f"data:{mime};base64,{inner}"
                return inner.strip()
    raise InputError(f"{field}: se esperaba una ruta, una URL o una data URI")


def _time(value: Any, field: str) -> float | None:
    if value is None:
        return None
    try:
        out = float(value)
    except (TypeError, ValueError) as exc:
        raise InputError(f"{field} debe ser un número de segundos") from exc
    if out < 0:
        raise InputError(f"{field} no puede ser negativo")
    return out


def _timed_part(kind: str, raw: Any, field: str) -> dict:
    part: dict[str, Any] = {"type": kind, "src": _media_src(raw, field, kind), "start": None, "end": None}
    if isinstance(raw, dict):
        part["start"] = _time(raw.get("start"), f"{field}.start")
        part["end"] = _time(raw.get("end"), f"{field}.end")
        if part["start"] is not None and part["end"] is not None and part["end"] <= part["start"]:
            raise InputError(f"{field}: end debe ser mayor que start")
    return part


def _as_list(value: Any) -> list:
    return value if isinstance(value, list) else [value]


def parse_native_item(raw: Any) -> list[dict]:
    """Elemento nativo: texto suelto o dict con `text`/`image`/`audio`/`video`/`pdf` (valores sueltos o listas).

    Si el texto lleva marcadores `<|image|>`, `<|audio|>` o `<|video|>`, el contenido se intercala en esas
    posiciones; si no, el orden es el de las claves del dict.
    """
    if isinstance(raw, str):
        if not raw:
            raise InputError("texto vacío")
        return [{"type": "text", "text": raw}]
    if not isinstance(raw, dict) or not raw:
        raise InputError("cada entrada debe ser un texto o un objeto con text/image/audio/video/pdf")
    if "content" in raw and isinstance(raw["content"], list):
        return parse_content_parts(raw["content"])
    allowed = {"text", "image", "audio", "video", "pdf", "title"}
    unknown = set(raw) - allowed
    if unknown:
        raise InputError(f"claves desconocidas: {sorted(unknown)}; usa {sorted(allowed - {'title'})}")
    media: dict[str, list[dict]] = {"image": [], "audio": [], "video": []}
    order: list[tuple[str, Any]] = []
    for key, value in raw.items():
        if key == "title":
            continue
        for i, v in enumerate(_as_list(value)):
            order.append((key, (v, f"{key}[{i}]")))
    text_values = [v for k, (v, _) in order if k == "text"]
    if any(not isinstance(t, str) for t in text_values):
        raise InputError("text debe ser un texto")
    joined_text = " ".join(text_values)
    placeholders = any(tag in joined_text for tag in ("<|image|>", "<|audio|>", "<|video|>"))
    parts: list[dict] = []
    for key, (value, field) in order:
        if key == "text":
            if value:
                parts.append({"type": "text", "text": value})
        elif key == "image":
            parts.append({"type": "image", "src": _media_src(value, field)})
        elif key in ("audio", "video"):
            parts.append(_timed_part(key, value, field))
        elif key == "pdf":
            page = value.get("page") if isinstance(value, dict) else None
            if not isinstance(page, int) or page < 1:
                raise InputError(f"{field}: indica la página con {{\"src\": ..., \"page\": N}} (desde 1)")
            parts.append({"type": "pdf_page", "src": _media_src(value, field), "page": page})
    if placeholders:
        for p in parts:
            if p["type"] in media:
                media[p["type"]].append(p)
        _check_placeholder_counts(joined_text, media)
    if not parts:
        raise InputError("entrada vacía")
    return parts


def _check_placeholder_counts(text: str, media: dict[str, list[dict]]) -> None:
    for kind in ("image", "audio", "video"):
        tags = text.count(f"<|{kind}|>")
        if tags and tags != len(media[kind]):
            raise InputError(f"hay {tags} marcadores <|{kind}|> pero {len(media[kind])} elementos de {kind}")


def parse_content_parts(content: list) -> list[dict]:
    """Partes estilo OpenAI/llama.cpp: `text`, `image_url`, `input_audio`, `video_url`, más `image`/`audio`/`video`."""
    parts: list[dict] = []
    for i, part in enumerate(content):
        field = f"content[{i}]"
        if not isinstance(part, dict) or "type" not in part:
            raise InputError(f"{field}: cada parte necesita «type»")
        kind = part["type"]
        if kind in ("text", "input_text"):
            text = part.get("text")
            if not isinstance(text, str):
                raise InputError(f"{field}: falta «text»")
            parts.append({"type": "text", "text": text})
        elif kind in ("image_url", "image", "input_image"):
            raw = part.get("image_url", part.get("image", part.get("url")))
            parts.append({"type": "image", "src": _media_src(raw, field)})
        elif kind in ("input_audio", "audio", "audio_url"):
            raw = part.get("input_audio", part.get("audio", part.get("audio_url", part.get("url"))))
            parts.append(_timed_part("audio", raw, field))
        elif kind in ("video_url", "video", "input_video"):
            raw = part.get("video_url", part.get("video", part.get("url")))
            parts.append(_timed_part("video", raw, field))
        else:
            raise InputError(f"{field}: tipo «{kind}» no soportado")
    if not parts:
        raise InputError("content vacío")
    return parts


def make_items(raw_inputs: Any, task: str | None = None, title: str | None = None) -> list[dict]:
    """Convierte la entrada de la API en elementos internos con su prefijo ya resuelto.

    El prefijo de tarea solo se aplica a elementos con texto: imagen, audio y vídeo sueltos van sin
    prefijo, como recomienda la ficha del modelo.
    """
    if isinstance(raw_inputs, (str, dict)):
        raw_inputs = [raw_inputs]
    if not isinstance(raw_inputs, list) or not raw_inputs:
        raise InputError("input debe ser un texto, un objeto o una lista no vacía")
    if all(isinstance(x, int) for x in raw_inputs) or any(
        isinstance(x, list) and x and all(isinstance(y, int) for y in x) for x in raw_inputs
    ):
        raise InputError("no se aceptan tokens ya tokenizados: envía texto")
    items: list[dict] = []
    for raw in raw_inputs:
        parts = parse_native_item(raw)
        item_title = raw.get("title") if isinstance(raw, dict) else None
        has_text = any(p["type"] == "text" for p in parts)
        prompt = prompt_for(task, item_title or title) if has_text else None
        items.append({"parts": parts, "prompt": prompt})
    return items


def _absolute(src: str, base: str) -> str:
    if src.startswith(("data:", "http://", "https://", "file://")):
        return src
    import os

    expanded = os.path.expanduser(src)
    return expanded if os.path.isabs(expanded) else os.path.normpath(os.path.join(base, expanded))


def absolutize_media(raw: Any, base: str) -> Any:
    """Convierte las rutas relativas de los medios en absolutas respecto a `base` (la carpeta del cliente).

    El servicio corre en otro proceso con otra carpeta de trabajo, así que el cliente debe resolverlas.
    """
    if isinstance(raw, list):
        return [absolutize_media(x, base) for x in raw]
    if not isinstance(raw, dict):
        return raw
    out = dict(raw)
    for key in ("image", "audio", "video", "pdf"):
        if key not in out:
            continue
        values = out[key] if isinstance(out[key], list) else [out[key]]
        fixed = []
        for value in values:
            if isinstance(value, str):
                fixed.append(_absolute(value, base))
            elif isinstance(value, dict):
                value = dict(value)
                for field in ("src", "path", "url"):
                    if isinstance(value.get(field), str):
                        value[field] = _absolute(value[field], base)
                fixed.append(value)
            else:
                fixed.append(value)
        out[key] = fixed if isinstance(out[key], list) else fixed[0]
    return out


def item_modality(item: dict) -> str:
    """`text`, `image`, `audio`, `video` o `mixed`."""
    kinds = {"image" if p["type"] == "pdf_page" else p["type"] for p in item["parts"]}
    return kinds.pop() if len(kinds) == 1 else "mixed"


def modalities_needed(items: list[dict]) -> set[str]:
    needed: set[str] = set()
    for item in items:
        for p in item["parts"]:
            needed.add("image" if p["type"] == "pdf_page" else p["type"])
    return needed
