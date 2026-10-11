"""API HTTP: compatible con OpenAI (`/v1/embeddings`) más los extras multimodales y el índice semántico."""

from __future__ import annotations

import ipaddress
import logging
import secrets
import time
from typing import Any, Literal

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, PlainTextResponse
from pydantic import BaseModel, ConfigDict, Field
from starlette.middleware.trustedhost import TrustedHostMiddleware

from . import __version__, guides
from .access import SERVICE_ID, identity_proof
from .config import MODEL_ALIAS, Config
from .engine import WorkerError
from .inputs import InputError, item_modality, split_task_suffix
from .service import Service, encode_options
from .vectors import to_base64

log = logging.getLogger("egemma")


class MediaOptions(BaseModel):
    image_tokens: int | None = Field(None, description="Tokens de visión por imagen: 70, 140, 280 (defecto), 560 o 1120")
    video_tokens: int | None = Field(None, description="Tokens de visión por fotograma: 70, 140 (defecto), 280, 560 o 1120")
    video_fps: float | None = Field(None, description="Fotogramas por segundo a muestrear (defecto 1)")
    video_max_frames: int | None = Field(None, description="Máximo de fotogramas por vídeo (defecto 32)")
    video_overflow: Literal["uniform", "truncate"] | None = None
    video_timestamps: bool = False

    def options(self) -> dict:
        return encode_options(
            self.image_tokens, self.video_tokens, self.video_fps, self.video_max_frames, self.video_overflow, self.video_timestamps
        )


class OpenAIEmbeddingRequest(MediaOptions):
    model_config = ConfigDict(extra="allow")
    input: Any
    model: str | None = None
    dimensions: int | None = None
    encoding_format: Literal["float", "base64"] = "float"
    user: str | None = None
    task: str | None = Field(None, description="query, document, code_query, question, fact_check, classification, clustering, similarity o none")
    title: str | None = None


class EmbedRequest(MediaOptions):
    inputs: Any
    task: str | None = None
    title: str | None = None
    dimensions: int | None = None
    encoding_format: Literal["float", "base64"] = "float"


class SimilarityRequest(MediaOptions):
    a: Any
    b: Any
    task_a: str | None = None
    task_b: str | None = None


class IndexRequest(BaseModel):
    path: str
    collection: str | None = None
    wait: float = Field(0, ge=0, le=3600, description="Segundos a esperar a que termine (0 = en segundo plano)")


class SearchRequest(BaseModel):
    query: str | None = None
    file: str | None = None
    collection: str | None = None
    path: str | None = None
    k: int = Field(10, ge=1, le=200)
    kinds: list[Literal["code", "doc", "pdf", "image", "audio", "video"]] | None = None
    task: str | None = None
    refresh: bool = False
    wait: float = Field(60, ge=0, le=3600)


def _is_loopback(host: str) -> bool:
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def create_app(cfg: Config, service: Service, on_shutdown: Any = None, api_key: str | None = None) -> FastAPI:
    if not api_key:
        raise ValueError("El servicio requiere una clave de acceso")
    app = FastAPI(
        title="EmbeddingGemma 2 local",
        version=__version__,
        description="Embeddings multimodales (texto, código, imagen, audio y vídeo) con google/embeddinggemma-2.",
    )
    if _is_loopback(cfg.host):
        # Contra DNS rebinding: solo se aceptan peticiones dirigidas a la propia máquina.
        app.add_middleware(TrustedHostMiddleware, allowed_hosts=["127.0.0.1", "localhost", "[::1]"])

    own_origins = {f"http://127.0.0.1:{cfg.port}", f"http://localhost:{cfg.port}", f"http://[::1]:{cfg.port}"}

    @app.middleware("http")
    async def block_cross_site(request: Request, call_next: Any) -> Any:
        # Un navegador manda POST sin cuerpo (/shutdown, /unload) sin preflight: cualquier web abierta podría
        # pararlo. Los clientes legítimos (CLI, MCP, SDK, curl) no envían Origin ni Sec-Fetch-Site.
        site = request.headers.get("sec-fetch-site")
        origin = request.headers.get("origin")
        if (site and site not in ("same-origin", "none")) or (origin and origin not in own_origins):
            return _error(403, "petición desde otra web rechazada", "permission_error")
        return await call_next(request)

    @app.middleware("http")
    async def require_key(request: Request, call_next: Any) -> Any:
        if request.url.path not in ("/health", "/", "/docs", "/redoc", "/openapi.json", "/docs/oauth2-redirect"):
            sent = request.headers.get("authorization", "")
            if not secrets.compare_digest(sent, f"Bearer {api_key}"):
                return _error(401, "falta la clave (Authorization: Bearer …)", "authentication_error")
        return await call_next(request)

    @app.exception_handler(InputError)
    async def _bad_input(_: Request, exc: InputError) -> JSONResponse:
        return _error(400, str(exc), "invalid_request_error")

    @app.exception_handler(WorkerError)
    async def _worker(_: Request, exc: WorkerError) -> JSONResponse:
        return _error(503 if exc.kind == "load" else 500, str(exc), "server_error")

    @app.exception_handler(FileNotFoundError)
    async def _missing(_: Request, exc: FileNotFoundError) -> JSONResponse:
        return _error(404, str(exc), "not_found_error")

    @app.get("/")
    def root() -> dict:
        return {
            "service": "embeddinggemma-2",
            "docs": "/docs",
            "openai_base_url": f"{cfg.base_url}/v1",
            "llms_txt": f"{cfg.base_url}/llms.txt",
            "endpoints": ["/health", "/v1/embeddings", "/embed", "/similarity", "/index", "/search", "/collections", "/guide/apps"],
        }

    @app.get("/health")
    def health(request: Request, challenge: str | None = None) -> dict:
        if secrets.compare_digest(request.headers.get("authorization", ""), f"Bearer {api_key}"):
            return {**service.status(), "service": SERVICE_ID}
        result = {"service": SERVICE_ID}
        if challenge is not None:
            result["proof"] = identity_proof(api_key, challenge)
        return result

    @app.get("/llms.txt", response_class=PlainTextResponse)
    def llms() -> str:
        return guides.llms_txt(cfg.base_url)

    @app.get("/guide/{name}", response_class=PlainTextResponse)
    def guide(name: str, topic: str = "all") -> str:
        try:
            if name == "apps":
                return guides.integration_guide(topic)
            return guides.read(name)
        except ValueError as exc:
            raise InputError(str(exc)) from exc

    @app.get("/v1/models")
    def models() -> dict:
        return {
            "object": "list",
            "data": [{"id": MODEL_ALIAS, "object": "model", "created": int(service.started_at), "owned_by": "google"}],
        }

    @app.post("/v1/embeddings")
    def openai_embeddings(req: OpenAIEmbeddingRequest) -> dict:
        _, suffix_task = split_task_suffix(req.model)
        task = req.task or suffix_task
        vectors, tokens, _ = service.embed(req.input, task=task, title=req.title, dimensions=req.dimensions, options=req.options())
        data = [
            {
                "object": "embedding",
                "index": i,
                "embedding": to_base64(v) if req.encoding_format == "base64" else v.tolist(),
            }
            for i, v in enumerate(vectors)
        ]
        return {
            "object": "list",
            "data": data,
            "model": MODEL_ALIAS,
            "usage": {"prompt_tokens": tokens, "total_tokens": tokens},
        }

    @app.post("/embed")
    def embed(req: EmbedRequest) -> dict:
        started = time.time()
        vectors, tokens, items = service.embed(req.inputs, task=req.task, title=req.title, dimensions=req.dimensions, options=req.options())
        return {
            "model": MODEL_ALIAS,
            "dimensions": int(vectors.shape[1]),
            "embeddings": [to_base64(v) if req.encoding_format == "base64" else v.tolist() for v in vectors],
            "modalities": [item_modality(i) for i in items],
            "prompts": [i["prompt"] for i in items],
            "usage": {"text_tokens": tokens},
            "elapsed_ms": round((time.time() - started) * 1000, 1),
        }

    @app.post("/similarity")
    def similarity(req: SimilarityRequest) -> dict:
        return service.similarity(req.a, req.b, req.task_a, req.task_b, options=req.options())

    @app.post("/index")
    def index(req: IndexRequest) -> dict:
        return service.index(req.path, req.collection, wait=req.wait).as_dict()

    @app.get("/jobs")
    def jobs() -> list[dict]:
        return [j.as_dict() for j in service.indexer.jobs()]

    @app.get("/jobs/{job_id}")
    def job(job_id: str, wait: float = 0) -> dict:
        found = service.indexer.get(job_id)
        if not found:
            raise FileNotFoundError(f"no existe el trabajo «{job_id}»")
        if wait > 0:
            found.done_event.wait(min(wait, 3600))
        return found.as_dict()

    @app.delete("/jobs/{job_id}")
    def cancel(job_id: str) -> dict:
        return {"cancelled": service.indexer.cancel(job_id)}

    @app.post("/search")
    def search(req: SearchRequest) -> dict:
        return service.search(
            query=req.query,
            file=req.file,
            collection=req.collection,
            path=req.path,
            k=req.k,
            kinds=list(req.kinds) if req.kinds else None,
            task=req.task,
            refresh=req.refresh,
            wait=req.wait,
        )

    @app.get("/collections")
    def collections() -> list[dict]:
        return service.collections()

    @app.get("/collections/{name}")
    def collection(name: str) -> dict:
        return service.collection(name)

    @app.delete("/collections/{name}")
    def drop(name: str) -> dict:
        return {"dropped": service.drop(name)}

    @app.post("/unload")
    def unload() -> dict:
        return {"unloaded": service.engine.unload()}

    @app.post("/shutdown")
    def shutdown() -> dict:
        if on_shutdown:
            on_shutdown()
        return {"stopping": True}

    return app


def _error(status: int, message: str, kind: str) -> JSONResponse:
    return JSONResponse(status_code=status, content={"error": {"message": message, "type": kind}})
