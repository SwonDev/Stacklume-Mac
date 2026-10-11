#!/usr/bin/env python3
"""Empaqueta el runtime fijado en uv.lock, sin depender del Python del usuario final."""
import argparse
import ast
import hashlib
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path


def normalize_portable_runtime(stage: Path) -> None:
    python = stage / "python"
    provenance = python / "lib/python3.12/site-packages"
    for path in provenance.glob("egemma-*.dist-info/direct_url.json"):
        metadata = json.loads(path.read_text())
        if metadata.get("dir_info", {}).get("editable") and metadata.get("url", "").startswith("file:"):
            path.unlink()

    for path in (python / "lib").glob("python*/_sysconfigdata*.py"):
        tree = ast.parse(path.read_text())
        assignment = next(node for node in tree.body if isinstance(node, ast.Assign)
                          and any(isinstance(target, ast.Name) and target.id == "build_time_vars" for target in node.targets))
        values = ast.literal_eval(assignment.value)
        prefixes = sorted({values[key] for key in ("prefix", "exec_prefix") if values.get(key)}, key=len, reverse=True)
        for key, value in values.items():
            if isinstance(value, str):
                for prefix in prefixes:
                    value = value.replace(prefix, "{STACKLUME_PYTHON_PREFIX}")
                values[key] = value
        path.write_text(
            "# Configuración reubicable del Python distribuido con Stacklume.\n"
            "from pathlib import Path as _Path\n"
            "_prefix = str(_Path(__file__).resolve().parents[2])\n"
            f"build_time_vars = {values!r}\n"
            "build_time_vars = {key: value.replace('{STACKLUME_PYTHON_PREFIX}', _prefix) "
            "if isinstance(value, str) else value for key, value in build_time_vars.items()}\n"
            "del _Path, _prefix\n",
            encoding="utf-8")

    library = python / "lib/libpython3.12.dylib"
    old_id = subprocess.check_output(["/usr/bin/otool", "-D", str(library)], text=True).splitlines()[1].strip()
    modified = {library}
    subprocess.run(["/usr/bin/install_name_tool", "-id", "@rpath/libpython3.12.dylib", str(library)], check=True)
    magic = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
    if old_id != "@rpath/libpython3.12.dylib":
        for path in python.rglob("*"):
            if not path.is_file() or path.is_symlink() or path == library:
                continue
            with path.open("rb") as file:
                if file.read(4) not in magic:
                    continue
                if old_id.encode() not in file.read():
                    continue
            dependencies = subprocess.check_output(["/usr/bin/otool", "-L", str(path)], text=True)
            if any(line.strip().startswith(old_id + " (") for line in dependencies.splitlines()[1:]):
                relative = os.path.relpath(library, path.parent)
                subprocess.run(["/usr/bin/install_name_tool", "-change", old_id, "@loader_path/" + relative, str(path)], check=True)
                modified.add(path)
    for path in sorted(modified):
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(path)], check=True)
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(path)], check=True)
        print("Mach-O portable firmado: " + str(path.relative_to(stage)), flush=True)


def portable_member(item: tarfile.TarInfo):
    if "__pycache__" in Path(item.name).parts:
        return None
    item.uid = item.gid = 0
    item.uname = item.gname = ""
    return item


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--python-root", type=Path)
    parser.add_argument("--base-archive", type=Path, help="Reutiliza exactamente el Python y las dependencias de un runtime ya fijado")
    parser.add_argument("--output-dir", type=Path, help="Directorio de salida; por defecto los recursos de la app")
    args = parser.parse_args()
    if args.python_root is None and args.base_archive is None:
        subprocess.run(["uv", "python", "install", "3.12.15", "--no-bin"], check=True)
        executable = subprocess.check_output(["uv", "python", "find", "3.12.15", "--managed-python", "--no-project", "--resolve-links"], text=True).strip()
        args.python_root = Path(executable).parents[1]
    root = Path(__file__).resolve().parents[2]
    source = root / "Runtime/EmbeddingGemma"
    output = args.output_dir or root / "App/Resources/EmbeddingRuntime"
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="stacklume-runtime-") as temp:
        stage = Path(temp) / "runtime"
        if args.base_archive is not None:
            with tarfile.open(args.base_archive, "r:gz") as original:
                if any(not member.name.startswith("runtime/") and member.name != "runtime" for member in original.getmembers()):
                    raise ValueError("El archivo base contiene una ruta ajena al runtime")
                original.extractall(temp, filter="data")
            shutil.rmtree(stage / "egemma")
        else:
            shutil.copytree(args.python_root, stage / "python", symlinks=True)
            subprocess.run(["uv", "sync", "--frozen", "--no-dev", "--python",
                            str(args.python_root / "bin/python3.12"), "--project", str(source)], check=True)
            packages = stage / "python/lib/python3.12/site-packages"
            shutil.copytree(source / ".venv/lib/python3.12/site-packages", packages, dirs_exist_ok=True,
                            ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "_egemma.pth"))
        shutil.copytree(source / "egemma", stage / "egemma", ignore=shutil.ignore_patterns("__pycache__"))
        shutil.copy2(source / "stacklume_server.py", stage / "stacklume_server.py")
        packages = stage / "python/lib/python3.12/site-packages"
        for path in packages.glob("*.pth"):
            if "editable" in path.name or path.name == "_virtualenv.pth" or "egemma" in path.read_text(errors="replace").lower():
                path.unlink()
        (packages / "_virtualenv.py").unlink(missing_ok=True)
        normalize_portable_runtime(stage)
        environment = {"HOME": temp, "PATH": str(stage / "python/bin") + ":/usr/bin:/bin",
                       "PYTHONHOME": str(stage / "python"), "PYTHONPATH": str(stage),
                       "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1", "LANG": "es_ES.UTF-8"}
        subprocess.run([str(stage / "python/bin/python3.12"), "-c",
                        "import sys,pathlib,sysconfig; root=pathlib.Path.cwd().resolve(); "
                        "assert all(not p or pathlib.Path(p).resolve().is_relative_to(root) for p in sys.path), sys.path; "
                        "assert pathlib.Path(sysconfig.get_config_var('prefix')).resolve() == root/'python'; "
                        "import mlx.core,mlx_vlm,transformers,av,fastapi,sqlite_vec,pypdfium2,egemma; "
                        "print('Imports y sysconfig portable: PASS')"],
                       cwd=stage, env=environment, check=True)
        archive = output / "runtime.tar.gz"
        pending = output / "runtime.tar.gz.part"
        with tarfile.open(pending, "w:gz", compresslevel=6) as tar:
            tar.add(stage, arcname="runtime", filter=portable_member)
        pending.replace(archive)
    source_hash = hashlib.sha256(Path(__file__).read_bytes())
    for path in sorted(source.rglob("*.py")):
        if ".venv" not in path.parts:
            source_hash.update(str(path.relative_to(source)).encode())
            source_hash.update(path.read_bytes())
    source_hash.update((source / "uv.lock").read_bytes())
    source_hash.update((source / "pyproject.toml").read_bytes())
    manifest = {"version": "egemma2-" + source_hash.hexdigest()[:16], "sha256": hashlib.file_digest(archive.open("rb"), "sha256").hexdigest(),
                "model": "google/embeddinggemma-2", "weights": "mlx-community/embeddinggemma-2-bf16",
                "revision": "1a4ffddb7905d3f63486748deabe091a01fb6201", "dimensions": 768}
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(f"Runtime empaquetado: {archive.stat().st_size // 2**20} MB")


if __name__ == "__main__":
    main()
