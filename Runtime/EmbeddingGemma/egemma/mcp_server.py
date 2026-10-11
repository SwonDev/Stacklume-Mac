"""Servidor MCP (stdio) para Claude Code, Codex, OpenCode y oh-my-pi.

Es un cliente ligero del servicio HTTP: no importa torch, arranca en milisegundos y, si el servicio no
está levantado, lo lanza en segundo plano en la primera llamada.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any, Literal

from mcp.server import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp.types import ToolAnnotations

from .client import Client, ServiceError
from .inputs import absolutize_media

Kind = Literal["code", "doc", "pdf", "image", "audio", "video"]
# El cliente HTTP corta a los 600 s: las esperas largas devolverían un error en vez del id del trabajo.
MAX_WAIT_S = 540

mcp = MCPServer(
    "embeddinggemma",
    instructions=(
        "Búsqueda semántica local con EmbeddingGemma 2: encuentra por significado (no por palabras exactas) "
        "código, documentos, PDF, imágenes, audio y vídeo, y compara contenido entre modalidades "
        "(texto→imagen, texto→audio, imagen→imagen…). Úsalo sin esperar a que te lo pidan cuando no sepas "
        "cómo se llama lo que buscas, cuando haya que localizar un recurso por lo que muestra o suena, o al "
        "buscar duplicados: semantic_search con path=<carpeta del proyecto> lo indexa al vuelo. Si el proyecto "
        "necesita embeddings, búsqueda semántica, RAG o recomendaciones, consulta integration_guide e "
        "intégralo (API local compatible con OpenAI en http://127.0.0.1:8737/v1, modelo embeddinggemma-2). "
        "Para texto literal o un símbolo exacto, tg. Todo corre en local."
    ),
)
_client: Client | None = None


def client() -> Client:
    global _client
    if _client is None:
        _client = Client()
    return _client


def _abs(path: str | None) -> str | None:
    if not path:
        return None
    return str(Path(path).expanduser().resolve())


def _call(fn: Any, *args: Any) -> Any:
    try:
        return fn(*args)
    except ServiceError as exc:
        raise ToolError(str(exc)) from exc


def _compact(results: list[dict]) -> list[dict]:
    keep = ("path", "location", "score", "kind", "modality", "preview")
    return [{k: r[k] for k in keep if r.get(k) is not None} for r in results]


@mcp.tool(
    title="Búsqueda semántica (texto, código, imagen, audio, vídeo)",
    annotations=ToolAnnotations(read_only_hint=False, idempotent_hint=True, open_world_hint=False),
)
def semantic_search(
    query: str | None = None,
    file: str | None = None,
    path: str | None = None,
    collection: str | None = None,
    kinds: list[Kind] | None = None,
    k: int = 10,
    refresh: bool = True,
) -> dict:
    """Busca por significado en carpetas indexadas: código, documentos, PDF, imágenes, audio y vídeo.

    - `query`: descripción en lenguaje natural («dónde se regenera la vida del jugador», «sprite de un dragón
      azul eléctrico», «la parte de la reunión donde se habla del inventario»). Funciona en español y entre
      modalidades: un texto encuentra imágenes, audio y momentos de un vídeo.
    - `file`: en vez de texto, usa un fichero como consulta (una imagen para encontrar imágenes parecidas…).
    - `path`: carpeta del proyecto o de recursos donde buscar. Con `refresh` (por defecto) se indexa o se
      pone al día antes de buscar, de forma incremental. Sin `path` ni `collection` se usa la carpeta de
      trabajo y se pone al día si refresh está activo. No se mezclan proyectos implícitamente.
    - `kinds`: limita a code, doc, pdf, image, audio o video.
    Devuelve rutas con su ubicación (líneas, página o minuto:segundo) y una puntuación coseno (0-1).
    """
    target = _abs(path)
    if target is None and collection is None:
        target = _abs(os.getcwd())
        if Path(target) == Path.home() or Path(target).parent == Path(target):
            raise ToolError("Indica path con la carpeta del proyecto; no se indexa la carpeta personal al iniciar una sesión")
    payload = {
        "query": query,
        "file": _abs(file),
        "path": target,
        "collection": collection,
        "kinds": kinds,
        "k": max(1, min(int(k), 50)),
        "refresh": bool(refresh and target),
        "wait": 120,
    }
    res = _call(client().post, "/search", payload)
    out: dict[str, Any] = {"collections": res["collections"], "results": _compact(res["results"])}
    if res.get("indexing"):
        job = res["indexing"]
        out["note"] = (
            f"El indexado sigue en curso ({job.get('files_done')}/{job.get('files_total')} ficheros); "
            f"los resultados pueden estar incompletos. Consulta index_status con job_id={job.get('id')}."
        )
    return out


@mcp.tool(
    title="Ficheros parecidos",
    annotations=ToolAnnotations(read_only_hint=True, open_world_hint=False),
)
def find_similar(
    file: str,
    path: str | None = None,
    collection: str | None = None,
    kinds: list[Kind] | None = None,
    k: int = 10,
) -> dict:
    """Encuentra los ficheros más parecidos a uno dado (sprites o iconos duplicados, código que hace lo
    mismo, documentos redundantes, sonidos similares). `path` o `collection` acotan dónde buscar."""
    res = _call(
        client().post,
        "/search",
        {"file": _abs(file), "path": _abs(path), "collection": collection, "kinds": kinds, "k": max(1, min(int(k), 50))},
    )
    return {"collections": res["collections"], "results": _compact(res["results"])}


@mcp.tool(
    title="Indexar una carpeta",
    annotations=ToolAnnotations(read_only_hint=False, idempotent_hint=True, open_world_hint=False),
)
def index_path(path: str, collection: str | None = None, wait_seconds: float = 120) -> dict:
    """Indexa (o pone al día, de forma incremental) una carpeta o un fichero para la búsqueda semántica.

    Respeta .gitignore, nunca lee credenciales (.env, claves) y salta los ficheros de OneDrive que solo
    están en la nube. Los vídeos se trocean en tramos de 32 s (imagen y sonido por separado) y el audio en
    tramos de 30 s, así que la búsqueda devuelve el minuto exacto. Si tarda más de `wait_seconds`, sigue en
    segundo plano y devuelve el `id` del trabajo para index_status. No indexa el perfil ni un disco entero.
    """
    target = _abs(path)
    return _call(
        client().post, "/index", {"path": target, "collection": collection, "wait": max(0, min(wait_seconds, MAX_WAIT_S))}
    )


@mcp.tool(title="Estado del indexado", annotations=ToolAnnotations(read_only_hint=True, open_world_hint=False))
def index_status(job_id: str | None = None, wait_seconds: float = 0) -> Any:
    """Progreso de un trabajo de indexado (`job_id`) o, sin él, la lista de trabajos recientes."""
    if job_id:
        return _call(client().get, f"/jobs/{job_id}", wait=min(wait_seconds, MAX_WAIT_S) or None)
    return {"jobs": _call(client().get, "/jobs")}


@mcp.tool(
    title="Comparar contenido (similitud coseno)",
    annotations=ToolAnnotations(read_only_hint=True, open_world_hint=False),
)
def compare(a: list[Any], b: list[Any], task: str | None = "similarity") -> dict:
    """Matriz de similitud coseno entre dos listas de entradas, de cualquier modalidad.

    Cada entrada es un texto o un objeto con rutas, URLs o data URIs: {"image": "C:/a.png"},
    {"audio": "x.wav"} o {"audio": {"src": "x.mp4", "start": 60, "end": 90}}, {"video": "y.mp4"},
    {"pdf": {"src": "z.pdf", "page": 2}}, o mezclas como {"text": "zapatilla", "image": "z.jpg"}.
    `task` solo afecta al texto: similarity (defecto), query, document, classification, clustering o none.
    Útil para detectar duplicados, comprobar si una imagen encaja con una descripción o clasificar contra
    etiquetas.
    """
    base = os.getcwd()
    return _call(
        client().post,
        "/similarity",
        {"a": absolutize_media(a, base), "b": absolutize_media(b, base), "task_a": task, "task_b": task},
    )


@mcp.tool(title="Vectores de embedding", annotations=ToolAnnotations(read_only_hint=True, open_world_hint=False))
def embed(inputs: list[Any], task: str | None = None, dimensions: int = 768) -> dict:
    """Devuelve los vectores (768, 512, 256 o 128 dimensiones, normalizados) de hasta 16 entradas.

    Mismo formato de entrada que compare. Para usarlo desde una aplicación es mejor la API HTTP
    (http://127.0.0.1:8737/v1/embeddings, compatible con OpenAI); esto es para pruebas rápidas.
    """
    if len(inputs) > 16:
        raise ToolError("máximo 16 entradas por llamada; para lotes grandes usa la API HTTP")
    return _call(
        client().post, "/embed", {"inputs": absolutize_media(inputs, os.getcwd()), "task": task, "dimensions": dimensions}
    )


@mcp.tool(title="Guía de integración en apps", annotations=ToolAnnotations(read_only_hint=True, open_world_hint=False))
def integration_guide(
    topic: Literal["all", "node", "python", "multimodal", "browser", "llama.cpp", "android", "apple", "patterns", "api"] = "all",
) -> str:
    """Cómo integrar EmbeddingGemma 2 en el proyecto: dónde debe correr el modelo según la app, código probado
    (SDK de OpenAI contra la API local, Python, multimodal), transformers.js en el navegador, llama.cpp,
    Android/Apple, almacenamiento en SQLite con sqlite-vec y patrones (RAG, código, duplicados, clasificación).
    Úsala antes de añadir embeddings, búsqueda semántica, RAG o recomendaciones a una aplicación."""
    from . import guides

    try:
        return guides.integration_guide(topic)
    except ValueError as exc:
        raise ToolError(str(exc)) from exc


@mcp.tool(title="Colecciones indexadas", annotations=ToolAnnotations(read_only_hint=True, open_world_hint=False))
def list_collections() -> dict:
    """Colecciones indexadas: carpetas raíz, ficheros por tipo, trozos, errores y fecha de actualización."""
    return {"collections": _call(client().get, "/collections")}


@mcp.tool(
    title="Borrar una colección",
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=True, open_world_hint=False),
)
def drop_collection(name: str) -> dict:
    """Borra el índice de una colección (no toca los ficheros originales). Confírmalo con el usuario antes."""
    return _call(client().delete, f"/collections/{name}")


@mcp.tool(title="Estado del servicio", annotations=ToolAnnotations(read_only_hint=True, open_world_hint=False))
def service_status() -> dict:
    """Estado del servicio: si el modelo está cargado, GPU, VRAM, modalidades y URL de la API."""
    info = _call(client().ensure_running)
    info["api"] = {"openai_base_url": f"{client().base_url}/v1", "native": client().base_url}
    return info


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
