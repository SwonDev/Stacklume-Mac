"""Línea de órdenes `egemma`: servidor, indexado, búsqueda y arranque automático."""

from __future__ import annotations

import argparse
import json
import logging
import logging.handlers
import os
import sys
from pathlib import Path
from typing import Any

from .config import Config, home_dir, load_config

def _utf8_console() -> None:
    for stream in (sys.stdout, sys.stderr):
        if stream is not None and hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")


# -- servidor -----------------------------------------------------------------
def _setup_logging(to_file: bool) -> None:
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    if to_file:
        log_dir = home_dir() / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        handler: logging.Handler = logging.handlers.RotatingFileHandler(
            log_dir / "server.log", maxBytes=5 * 2**20, backupCount=3, encoding="utf-8"
        )
    else:
        handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    root.handlers[:] = [handler]


def serve(cfg: Config, log_to_file: bool = False) -> int:
    import uvicorn

    from .engine import Engine
    from .server import _is_loopback, create_app
    from .service import Service

    _setup_logging(log_to_file)
    log = logging.getLogger("egemma")
    from .access import api_key as service_key
    if not _is_loopback(cfg.host) and not os.environ.get("EGEMMA_API_KEY"):
        log.error("host %s no es local: define EGEMMA_API_KEY antes de exponer el servicio en la red", cfg.host)
        return 2
    api_key = service_key()
    engine = Engine(cfg)
    service = Service(cfg, engine)
    server_ref: dict[str, Any] = {}

    def stop() -> None:
        server = server_ref.get("server")
        if server is not None:
            server.should_exit = True

    app = create_app(cfg, service, on_shutdown=stop, api_key=api_key)
    config = uvicorn.Config(
        app, host=cfg.host, port=cfg.port, log_config=None, access_log=False, workers=1, timeout_graceful_shutdown=10
    )
    server = uvicorn.Server(config)
    server_ref["server"] = server
    log.info("EmbeddingGemma 2 en %s (modelo bajo demanda, descarga tras %s min sin uso)", cfg.base_url, cfg.idle_unload_minutes)
    try:
        server.run()
    finally:
        engine.close()
    return 0


def serve_gui() -> None:
    """Entrada sin consola (pythonw) para la tarea programada: todo va al log."""
    log_dir = home_dir() / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    stream = open(log_dir / "server.stderr.log", "a", encoding="utf-8", buffering=1)  # noqa: SIM115
    sys.stdout = stream
    sys.stderr = stream
    sys.exit(serve(load_config(), log_to_file=True))


# -- salida -------------------------------------------------------------------
def _print(data: Any, as_json: bool) -> None:
    if as_json or not isinstance(data, (dict, list)):
        print(json.dumps(data, ensure_ascii=False, indent=2) if not isinstance(data, str) else data)
    else:
        print(json.dumps(data, ensure_ascii=False, indent=2))


def _print_hits(res: dict, as_json: bool) -> None:
    if as_json:
        _print(res, True)
        return
    if not res["results"]:
        print("Sin resultados.")
    for hit in res["results"]:
        loc = f"  [{hit['location']}]" if hit.get("location") else ""
        print(f"{hit['score']:.3f}  {hit['path']}{loc}")
        if hit.get("preview") and hit["kind"] in ("code", "doc", "pdf"):
            print(f"       {hit['preview'][:160]}")
    if res.get("indexing"):
        job = res["indexing"]
        print(f"\n(indexado en curso: {job['files_done']}/{job['files_total']} ficheros, trabajo {job['id']})")


# -- órdenes -------------------------------------------------------------------
def main(argv: list[str] | None = None) -> int:
    _utf8_console()
    parser = argparse.ArgumentParser(prog="egemma", description="Servicio local de EmbeddingGemma 2")
    parser.add_argument("--json", action="store_true", help="salida en JSON")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("serve", help="arranca el servidor en primer plano")
    p.add_argument("--host")
    p.add_argument("--port", type=int)
    p.add_argument("--log-to-file", action="store_true")
    sub.add_parser("start", help="arranca el servidor en segundo plano si no está")
    sub.add_parser("stop", help="para el servidor")
    sub.add_parser("status", help="estado del servidor y del modelo")
    sub.add_parser("unload", help="descarga el modelo de la GPU ahora")

    p = sub.add_parser("index", help="indexa o pone al día una carpeta o fichero")
    p.add_argument("path")
    p.add_argument("-c", "--collection")
    p.add_argument("--no-wait", action="store_true", help="no esperar a que termine")

    p = sub.add_parser("search", help="búsqueda semántica")
    p.add_argument("query", nargs="?")
    p.add_argument("--file", help="usar un fichero como consulta")
    p.add_argument("-p", "--path", help="carpeta donde buscar (por defecto, todas las colecciones)")
    p.add_argument("-c", "--collection")
    p.add_argument("-k", type=int, default=10)
    p.add_argument("--kinds", help="code,doc,pdf,image,audio,video")
    p.add_argument("--refresh", action="store_true", help="poner al día el índice antes de buscar")

    p = sub.add_parser("similar", help="ficheros parecidos a uno dado")
    p.add_argument("file")
    p.add_argument("-p", "--path")
    p.add_argument("-k", type=int, default=10)
    p.add_argument("--kinds")

    p = sub.add_parser("embed", help="vectores de uno o varios textos")
    p.add_argument("texts", nargs="+")
    p.add_argument("--task")
    p.add_argument("--dim", type=int, default=768)

    sub.add_parser("collections", help="lista las colecciones")
    p = sub.add_parser("drop", help="borra el índice de una colección")
    p.add_argument("name")
    sub.add_parser("jobs", help="trabajos de indexado recientes")

    p = sub.add_parser("autostart", help="arranque automático al iniciar sesión (Windows, macOS, Linux)")
    p.add_argument("action", choices=["install", "uninstall", "status"])
    p = sub.add_parser("setup", help="instala skill, MCP, hook, regla y arranque en todos los asistentes detectados")
    p.add_argument("--only", help="solo estos: claude,codex,opencode,gemini,omp,cursor,antigravity,claude-desktop")
    p.add_argument("--no-autostart", action="store_true")
    p.add_argument("--no-model", action="store_true", help="no descargar el modelo")
    p.add_argument("--no-verify", action="store_true", help="no hacer la prueba real al final")
    p = sub.add_parser("hook", help="hooks de los asistentes")
    p.add_argument("event", choices=["session-start"])
    p.add_argument("--format", choices=["claude", "text"], default="claude")
    sub.add_parser("config", help="configuración efectiva y rutas")

    args = parser.parse_args(argv)
    cfg = load_config()

    if args.cmd == "serve":
        if args.host:
            cfg.host = args.host
        if args.port:
            cfg.port = args.port
        return serve(cfg, log_to_file=args.log_to_file)
    if args.cmd == "hook":
        from .hooks import main as hook_main

        return hook_main(args.format)
    if args.cmd == "autostart":
        from .setup import autostart

        ok, message = autostart(args.action)
        print(message)
        return 0 if ok else 1
    if args.cmd == "setup":
        from .setup import run_setup

        only = {x.strip() for x in args.only.split(",")} if args.only else None
        steps = run_setup(
            cfg, only, with_autostart=not args.no_autostart, with_model=not args.no_model, with_verify=not args.no_verify
        )
        if args.json:
            _print([s.__dict__ for s in steps], True)
        else:
            icons = {"hecho": "✔", "actualizado": "↻", "ya estaba": "·", "omitido": "–", "generado": "↻", "error": "✘"}
            for s in steps:
                detail = f" ({s.detail})" if s.detail else ""
                print(f"{icons.get(s.status, '?')} {s.target:<15} {s.what}: {s.status}{detail}")
        return 1 if any(s.status == "error" for s in steps) else 0
    if args.cmd == "config":
        import dataclasses

        _print({"home": str(home_dir()), "config_file": str(home_dir() / "config.json"), **dataclasses.asdict(cfg)}, True)
        return 0

    from .client import Client, ServiceError

    with Client(cfg) as client:
        try:
            if args.cmd == "start":
                info = client.ensure_running()
                print(f"Servicio activo en {client.base_url} (modelo cargado: {info['engine']['loaded']})")
            elif args.cmd == "stop":
                if client.health() is None:
                    print("El servicio no está en marcha.")
                else:
                    import time

                    client.http.post("/shutdown")
                    deadline = time.time() + 20
                    while time.time() < deadline and client.health() is not None:
                        time.sleep(0.5)
                    if client.health() is None:
                        print("Servicio detenido.")
                    else:
                        print("El servicio sigue respondiendo tras 20 s; mira ~/.embeddinggemma/logs/server.log", file=sys.stderr)
                        return 1
            elif args.cmd == "status":
                info = client.health()
                if info is None:
                    print(f"El servicio no responde en {client.base_url}. Arráncalo con `egemma start`.")
                    return 1
                _print(info, True)
            elif args.cmd == "unload":
                _print(client.post("/unload", {}), args.json)
            elif args.cmd == "index":
                job = client.post("/index", {"path": str(Path(args.path).resolve()), "collection": args.collection, "wait": 0})
                if not args.no_wait:
                    print(f"Indexando {job['root']} en la colección «{job['collection']}»…")
                    while job["status"] in ("queued", "running"):
                        job = client.get(f"/jobs/{job['id']}", wait=5)
                        print(f"  {job['files_done']}/{job['files_total']} ficheros", end="\r", flush=True)
                    print()
                _print(job, True)
            elif args.cmd == "search":
                res = client.post(
                    "/search",
                    {
                        "query": args.query,
                        "file": str(Path(args.file).resolve()) if args.file else None,
                        "path": str(Path(args.path).resolve()) if args.path else None,
                        "collection": args.collection,
                        "k": args.k,
                        "kinds": args.kinds.split(",") if args.kinds else None,
                        "refresh": args.refresh,
                    },
                )
                _print_hits(res, args.json)
            elif args.cmd == "similar":
                res = client.post(
                    "/search",
                    {
                        "file": str(Path(args.file).resolve()),
                        "path": str(Path(args.path).resolve()) if args.path else None,
                        "k": args.k,
                        "kinds": args.kinds.split(",") if args.kinds else None,
                    },
                )
                _print_hits(res, args.json)
            elif args.cmd == "embed":
                _print(client.post("/embed", {"inputs": args.texts, "task": args.task, "dimensions": args.dim}), True)
            elif args.cmd == "collections":
                cols = client.get("/collections")
                if args.json:
                    _print(cols, True)
                elif not cols:
                    print("No hay colecciones. Indexa una carpeta con `egemma index <ruta>`.")
                for c in cols:
                    files = ", ".join(f"{k}: {v}" for k, v in c.get("files", {}).items()) or "vacía"
                    print(f"{c['name']}  ({files}; {c.get('chunks', 0)} trozos, {c.get('size_mb', 0)} MB)")
                    for r in c.get("roots", []):
                        print(f"    {r}")
            elif args.cmd == "drop":
                _print(client.delete(f"/collections/{args.name}"), args.json)
            elif args.cmd == "jobs":
                _print(client.get("/jobs"), True)
        except ServiceError as exc:
            print(f"Error: {exc}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
