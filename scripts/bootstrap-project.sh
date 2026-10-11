#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

command -v xcodegen >/dev/null 2>&1 || {
    echo "Falta XcodeGen. Instálalo con: brew install xcodegen" >&2
    exit 1
}

if [[ ! -f App/Resources/EmbeddingRuntime/manifest.json || ! -f App/Resources/EmbeddingRuntime/runtime.tar.gz ]]; then
    command -v uv >/dev/null 2>&1 || { echo "Falta uv para empaquetar la búsqueda local: brew install uv" >&2; exit 1; }
    uv run --python 3.12.15 --no-project scripts/embeddinggemma/package_runtime.py
fi

xcodegen generate
SWIFTPM_DIR="Stacklume.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$SWIFTPM_DIR"
cp Config/Package.resolved "$SWIFTPM_DIR/Package.resolved"

echo "Proyecto generado con las versiones SPM bloqueadas en Config/Package.resolved."
