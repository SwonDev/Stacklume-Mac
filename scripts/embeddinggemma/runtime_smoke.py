#!/usr/bin/env python3
"""Prueba el servidor empaquetado desde una ubicación nueva y un entorno mínimo."""
import argparse
import json
import math
import shutil
import uuid
import os
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--runtime", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--clean-model-cache", action="store_true")
parser.add_argument("--fixtures", type=Path)
parser.add_argument("--test-dns-dir", type=Path)
args = parser.parse_args()
runtime = args.runtime.resolve()
results = {}


def call(base, path, body=None, token=None, headers=None, timeout=900):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(base + path, data=data)
    request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    for key, value in (headers or {}).items():
        request.add_header(key, value)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def expect(name, condition):
    results[name] = bool(condition)
    print(name + ": " + ("PASS" if condition else "FAIL"), flush=True)
    if not condition:
        raise AssertionError(name)


def pdf(text):
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
               b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
               b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    stream = ("BT /F1 18 Tf 40 700 Td (" + text + ") Tj ET").encode()
    objects.append(b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"\nendstream")
    data = b"%PDF-1.4\n"
    positions = [0]
    for i, obj in enumerate(objects, 1):
        positions.append(len(data))
        data += f"{i} 0 obj\n".encode() + obj + b"\nendobj\n"
    offset = len(data)
    data += b"xref\n0 6\n0000000000 65535 f \n" + b"".join(f"{p:010d} 00000 n \n".encode() for p in positions[1:])
    return data + f"trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{offset}\n%%EOF".encode()


with tempfile.TemporaryDirectory(prefix="stacklume-egemma-test-") as temp:
    home = Path(temp)
    token = os.urandom(32).hex()
    env = {"HOME": str(home / "clean-user") if args.clean_model_cache else str(Path.home()), "PATH": "/usr/bin:/bin", "PYTHONNOUSERSITE": "1",
           "PYTHONHOME": str(runtime / "python"), "PYTHONPATH": str(runtime), "EGEMMA_HOME": str(home),
           "STACKLUME_PARENT_PID": str(os.getpid()), "STACKLUME_EMBEDDING_TOKEN": token,
           "PYTHONUNBUFFERED": "1"}
    if args.test_dns_dir:
        env["PYTHONPATH"] += os.pathsep + str(args.test_dns_dir.resolve())
        env["HF_HUB_DISABLE_XET"] = "1"
    with (home / "server.log").open("w") as log:
        child = subprocess.Popen([str(runtime / "python/bin/python3.12"), str(runtime / "stacklume_server.py")],
                                 env=env, cwd=runtime, stdout=log, stderr=log)
    try:
        for _ in range(7200 if args.clean_model_cache else 240):
            if child.poll() is not None:
                raise RuntimeError((home / "server.log").read_text())
            try:
                status = json.loads((home / "status.json").read_text())
            except (FileNotFoundError, json.JSONDecodeError):
                status = {}
            if status.get("phase") == "failed":
                raise RuntimeError(status)
            if status.get("phase") == "ready":
                break
            time.sleep(0.5)
        else:
            raise RuntimeError("El runtime no llegó a listo")
        base = f"http://127.0.0.1:{status['port']}"
        expect("instalación portable sin Homebrew", status["revision"] == "1a4ffddb7905d3f63486748deabe091a01fb6201")
        try:
            call(base, "/embed", {"inputs": ["hola"]})
        except urllib.error.HTTPError as error:
            expect("API privada", error.code == 401)
        else:
            expect("API privada", False)
        try:
            call(base, "/embed", {"inputs": ["hola"]}, token, {"Origin": "https://example.com"})
        except urllib.error.HTTPError as error:
            expect("rechazo de navegador ajeno", error.code == 403)
        corpus = home / "corpus"
        corpus.mkdir()
        (corpus / "huerto.txt").write_text("Cultivo de tomates, riego por goteo y fertilizantes para el huerto urbano.")
        (corpus / "metal.txt").write_text("Programación de shaders Metal, computación gráfica y renderizado por GPU en Apple Silicon.")
        (corpus / "manual.pdf").write_bytes(pdf("La expedicion a Lanzarote sale el viernes por la tarde."))
        from PIL import Image, ImageDraw
        import av
        image = Image.new("RGB", (512, 512), "white")
        ImageDraw.Draw(image).ellipse((60, 60, 452, 452), fill="red")
        image.save(corpus / "pelota.png")
        subprocess.run(["/usr/bin/say", "-o", str(corpus / "excursion.aiff"),
                        "Nuestro viaje a Lanzarote comienza el viernes por la tarde."], check=True)
        with av.open(str(corpus / "pelota.mp4"), "w") as video:
            stream = video.add_stream("libx264", rate=8)
            stream.width = stream.height = 512
            stream.pix_fmt = "yuv420p"
            for _ in range(16):
                frame = av.VideoFrame.from_image(image)
                for packet in stream.encode(frame):
                    video.mux(packet)
            for packet in stream.encode():
                video.mux(packet)
        response = call(base, "/embed", {"inputs": ["Un huerto de tomates", {"image": str(corpus / "pelota.png")},
                            {"audio": str(corpus / "excursion.aiff")}, {"video": str(corpus / "pelota.mp4")},
                            {"pdf": {"src": str(corpus / "manual.pdf"), "page": 1}},
                            {"text": "Una pelota roja <|image|>", "image": str(corpus / "pelota.png")}],
                            "dimensions": 768}, token)
        expect("seis entradas y todas las modalidades", len(response["embeddings"]) == 6)
        expect("vectores BF16 finitos normalizados", all(len(v) == 768 and all(math.isfinite(x) for x in v)
                            and abs(sum(x*x for x in v)-1) < 0.001 for v in response["embeddings"]))
        health = call(base, "/health", token=token)
        expect("motor MLX BF16 completo", health["engine"]["worker"]["dtype"] == "bfloat16"
               and health["engine"]["worker"]["motor"]["audio_cargado"])
        for dimensions in (128, 256, 512):
            vector = call(base, "/embed", {"inputs": ["prueba"], "dimensions": dimensions}, token)["embeddings"][0]
            expect(f"Matryoshka {dimensions}", len(vector) == dimensions and abs(sum(x*x for x in vector)-1) < 0.001)
        for task in ("query", "document", "code_query", "question", "fact_check", "classification", "clustering", "similarity"):
            value = call(base, "/embed", {"inputs": ["Encontrar la excursión"], "task": task}, token)
            expect("tarea " + task, len(value["embeddings"][0]) == 768)
        marker = home / "text-inference-active"
        marker.write_text(str(os.getpid()))
        paused = call(base, "/index", {"path": str(corpus), "collection": "test"}, token)
        time.sleep(1)
        paused = call(base, "/jobs/" + paused["id"], token=token)
        expect("indexación en pausa durante inferencia del chat", paused["indexed"] == 0 and paused["status"] in ("queued", "running"))
        marker.unlink()
        for _ in range(240):
            job = call(base, "/jobs/" + paused["id"], token=token)
            if job["status"] not in ("queued", "running"):
                break
            time.sleep(0.5)
        while job["status"] in ("queued", "running"):
            time.sleep(1)
            job = call(base, "/jobs/" + job["id"], token=token)
        expect("índice completo multimodal", job["status"] == "done" and job["failed"] == 0 and job["indexed"] == 6)
        search = call(base, "/search", {"query": "cómo regar las verduras", "collection": "test", "k": 10}, token)
        expect("búsqueda por significado", Path(search["results"][0]["path"]).name == "huerto.txt")
        visual = call(base, "/search", {"query": "pelota de color rojo", "collection": "test", "kinds": ["image", "video"], "k": 5}, token)
        expect("búsqueda visual por color", len(visual["results"]) >= 2)
        audio = call(base, "/search", {"query": "un viaje a Lanzarote", "collection": "test", "kinds": ["audio"], "k": 5}, token)
        expect("audio con posición temporal", bool(audio["results"]) and audio["results"][0]["loc_unit"] == "s")
        page = call(base, "/search", {"query": "cuándo sale la expedición", "collection": "test", "kinds": ["pdf"], "k": 5}, token)
        expect("PDF con página", page["results"][0]["loc_unit"] == "page")
        similar = call(base, "/search", {"file": str(corpus / "pelota.png"), "collection": "test", "k": 5}, token)
        expect("consulta mediante archivo", bool(similar["results"]))
        unchanged = call(base, "/index", {"path": str(corpus), "collection": "test", "wait": 120}, token)
        expect("indexado incremental sin recomputar", unchanged["unchanged"] == 6 and unchanged["indexed"] == 0)
        # Frontera de la app: deduplicar y acotar ANTES de limitar los resultados.
        ids = []
        for file in list(corpus.iterdir()):
            if not file.is_file():
                continue
            folder = corpus / str(uuid.uuid4()).upper()
            folder.mkdir()
            file.rename(folder / file.name)
            ids.append(folder.name)
        app_job = call(base, "/index", {"path": str(corpus), "collection": "stacklume-library", "wait": 120}, token)
        expect("corpus propio por UUID", app_job["failed"] == 0 and app_job["indexed"] == 6)
        scoped = call(base, "/stacklume/search", {"query": "tomates y riego", "ids": [ids[1]], "k": 1}, token)
        expect("filtros antes del ranking", len(scoped["results"]) == 1 and Path(scoped["results"][0]["path"]).parent.name == ids[1])
        empty = call(base, "/stacklume/search", {"query": "tomates", "ids": []}, token)
        expect("alcance vacío no devuelve biblioteca", empty["results"] == [])
        released = call(base, "/stacklume/release", {}, token=token, timeout=15)
        expect("liberación confirmada del worker privado", released["released"] and not call(base, "/health", token=token)["engine"]["loaded"])
        repeated = call(base, "/stacklume/search", {"query": "tomates", "ids": []}, token)
        expect("consulta persistente sin recargar el modelo", repeated["query_cached"] and not call(base, "/health", token=token)["engine"]["loaded"])
        visual_path = next(corpus.glob("*/*.png"))
        mixed = call(base, "/stacklume/search", {"query": "objeto rojo", "file": str(visual_path)}, token)
        expect("consulta mixta texto e imagen", bool(mixed["results"]))
        text_path = next(corpus.glob("*/huerto.txt"))
        mixed_text = call(base, "/stacklume/search", {"query": "hortalizas", "file": str(text_path)}, token)
        expect("consulta mixta texto y documento", bool(mixed_text["results"]))
        centers = call(base, "/stacklume/vectors", {"ids": ids}, token)["embeddings"]
        expect("centroides multimodales para conexiones", len(centers) == 6 and all(len(v) == 768
            and all(math.isfinite(x) for x in v) and abs(sum(x*x for x in v)-1) < 0.001 for v in centers.values()))
        for task in ("classification", "clustering", "similarity"):
            marker.write_text(str(os.getpid()))
            tasked = call(base, "/stacklume/vectors", {"ids": ids[:2], "task": task}, token, timeout=30)["embeddings"]
            marker.unlink()
            expect("centroides con prefijo " + task, len(tasked) == 2 and all(len(v) == 768 for v in tasked.values()))
            again = call(base, "/stacklume/vectors", {"ids": ids[:2], "task": task}, token)["embeddings"]
            expect("caché de tarea " + task, tasked == again)
        app_results = call(base, "/stacklume/search", {"query": "expedición de viaje", "k": 200}, token)["results"]
        expect("resultados sin duplicar enlaces", len(app_results) == len({Path(h["path"]).parent.name for h in app_results}))
        if args.fixtures:
            args.fixtures.mkdir(parents=True, exist_ok=True)
            for file in corpus.glob("*/*"):
                if file.is_file():
                    shutil.copy2(file, args.fixtures / file.name)
        text_path.unlink()
        removed = call(base, "/index", {"path": str(corpus), "collection": "stacklume-library", "wait": 120}, token)
        expect("purga del índice al borrar", removed["removed"] == 1)
        reference = call("http://127.0.0.1:8737", "/embed", {"inputs": ["Un huerto de tomates"], "dimensions": 768})["embeddings"][0]
        expect("paridad A/B con servicio personal", max(abs(a-b) for a,b in zip(reference, response["embeddings"][0])) < 0.00001)
        args.output.write_text(json.dumps({"tests": results, "health": health, "job": job}, ensure_ascii=False, indent=2))
    finally:
        child.terminate()
        try:
            child.wait(timeout=20)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
