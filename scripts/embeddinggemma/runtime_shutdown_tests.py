#!/usr/bin/env python3
"""Cierra el wrapper real durante una petición bloqueada sin cargar pesos."""
import argparse
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--runtime", type=Path, required=True)
parser.add_argument("--child", action="store_true")
parser.add_argument("--group-leader", action="store_true")
args = parser.parse_args()
sys.path.insert(0, str(args.runtime.resolve()))

if args.child:
    import stacklume_server
    from egemma.engine import Engine
    import egemma.server
    original_create = egemma.server.create_app

    def spawn(engine):
        engine._proc = subprocess.Popen(
            [sys.executable, "-c", "import sys,time;sys.stdin.buffer.read(1);time.sleep(60)"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        (stacklume_server.home / "worker-pid").write_text(str(engine._proc.pid))
        with (stacklume_server.home / "spawned").open("a") as record:
            record.write(str(engine._proc.pid) + "\n")

    def create(cfg, service, **kwargs):
        app = original_create(cfg, service, **kwargs)

        @app.get("/test/busy")
        def busy():
            def producer():
                for _ in range(3):
                    try:
                        service.engine.request("encode", items=[])
                    except Exception:
                        pass
                (stacklume_server.home / "producer-finished").write_text("sí")
            threading.Thread(target=producer, daemon=True).start()
            return service.engine.request("encode", items=[])
        return app

    Engine._spawn = spawn
    egemma.server.create_app = create
    stacklume_server.download_model = lambda: None
    stacklume_server.main()
    sys.exit(0)

with tempfile.TemporaryDirectory(prefix="stacklume-shutdown-test-") as temp:
    root = Path(temp)
    env = dict(os.environ, EGEMMA_HOME=temp, STACKLUME_PARENT_PID=str(os.getpid()),
               STACKLUME_EMBEDDING_TOKEN="token-de-prueba-local")
    log = (root / "server.log").open("w")
    server = subprocess.Popen([sys.executable, __file__, "--runtime", str(args.runtime), "--child"], env=env,
                              stdout=log, stderr=log, start_new_session=args.group_leader)
    worker_pid = None
    try:
        deadline = time.monotonic() + 20
        status = {}
        while time.monotonic() < deadline:
            try:
                status = json.loads((root / "status.json").read_text())
                if status.get("phase") == "ready":
                    break
            except (OSError, ValueError):
                pass
            time.sleep(0.05)
        assert status.get("phase") == "ready", (root / "server.log").read_text()
        assert os.getpgid(server.pid) == server.pid

        def request():
            try:
                req = urllib.request.Request(f"http://127.0.0.1:{status['port']}/test/busy",
                                             headers={"Authorization": "Bearer token-de-prueba-local"})
                urllib.request.urlopen(req, timeout=20).read()
            except Exception:
                pass  # La petición debe interrumpirse al cerrar el motor.
        thread = threading.Thread(target=request)
        thread.start()
        while not (root / "worker-pid").exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        worker_pid = int((root / "worker-pid").read_text())
        started = time.monotonic()
        server.terminate()
        server.wait(timeout=15)
        thread.join(5)
        assert not thread.is_alive()
        assert len((root / "spawned").read_text().splitlines()) == 1, "Se relanzó un worker durante el cierre"
        try:
            os.kill(worker_pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError("El worker sobrevivió al servidor")
        elapsed = time.monotonic() - started
        assert elapsed < 15
        print(f"Cierre SIGTERM con petición bloqueada y worker: PASS ({elapsed:.2f} s)")
    finally:
        if server.poll() is None:
            if os.getpgid(server.pid) == server.pid:
                os.killpg(server.pid, signal.SIGKILL)
            else:
                server.kill()
            server.wait()
        log.close()
