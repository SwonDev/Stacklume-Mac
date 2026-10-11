#!/usr/bin/env python3
"""Regresión del worker bloqueado: libera memoria sin esperar el timeout de 900 s."""
import argparse
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--runtime", type=Path, required=True)
args = parser.parse_args()
sys.path.insert(0, str(args.runtime.resolve()))
from egemma.config import Config
from egemma.engine import Engine, WorkerError

with tempfile.TemporaryDirectory(prefix="stacklume-memory-test-") as temp:
    engine = Engine(Config(data_dir=temp))
    # Tuberías reales: representa un modelo ocupado que no devuelve respuesta.
    worker = subprocess.Popen([sys.executable, "-c", "import sys,time;sys.stdin.buffer.read(1);time.sleep(60)"],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    engine._proc = worker
    outcomes = []
    def request():
        try:
            engine.request("encode", items=[])
        except WorkerError as error:
            outcomes.append(error.kind)
    thread = threading.Thread(target=request)
    try:
        thread.start()
        time.sleep(0.2)
        started = time.monotonic()
        assert engine.release_memory()
        thread.join(5)
        assert not thread.is_alive() and outcomes == ["memory"]
        assert worker.poll() is not None and not engine.status()["loaded"]
        assert time.monotonic() - started < 6
        print("Worker ocupado: liberación confirmada y error recuperable: PASS")
    finally:
        engine.close()
