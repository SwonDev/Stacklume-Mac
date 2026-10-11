#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ $# -ne 3 ]]; then
    echo "Uso: $0 <Stacklume.app> <Stacklume.zip> <appcast.xml>" >&2
    exit 64
fi

APP_PATH="$1"
ZIP_PATH="$2"
APPCAST_PATH="$3"

[[ -d "$APP_PATH" ]] || { echo "No existe la app: $APP_PATH" >&2; exit 1; }
[[ -f "$ZIP_PATH" ]] || { echo "No existe el ZIP: $ZIP_PATH" >&2; exit 1; }
[[ -f "$APPCAST_PATH" ]] || { echo "No existe el appcast: $APPCAST_PATH" >&2; exit 1; }

MAIN_BINARY="$APP_PATH/Contents/MacOS/Stacklume"
declare -a RELEASE_BINARIES=(
    "$MAIN_BINARY"
    "$APP_PATH/Contents/PlugIns/ShareExtension.appex/Contents/MacOS/ShareExtension"
    "$APP_PATH/Contents/PlugIns/StacklumeWidget.appex/Contents/MacOS/StacklumeWidget"
)
for binary in "${RELEASE_BINARIES[@]}"; do
    [[ -f "$binary" ]] || { echo "Falta el binario: $binary" >&2; exit 1; }
    ARCHS="$(lipo -archs "$binary")"
    [[ "$ARCHS" == "arm64" ]] || {
        echo "Arquitectura inesperada en $binary: $ARCHS (se esperaba arm64)." >&2
        exit 1
    }
done

verify_free_edition() {
    local info_plist="$1/Contents/Info.plist"
    plutil -lint "$info_plist" >/dev/null
    local key
    for key in StacklumeCommercialBuild StacklumeLicenseOrganizationID StacklumeLicenseBenefitID; do
        if plutil -type "$key" "$info_plist" >/dev/null 2>&1; then
            echo "El bundle gratuito contiene metadata comercial: $key." >&2
            exit 1
        fi
    done
}
verify_free_edition "$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
"$SCRIPT_DIR/verify-runtime-signing.sh" "$APP_PATH"

for bundle in \
    "$APP_PATH" \
    "$APP_PATH/Contents/PlugIns/ShareExtension.appex" \
    "$APP_PATH/Contents/PlugIns/StacklumeWidget.appex"; do
    SIGNATURE_INFO="$(codesign -d --verbose=4 "$bundle" 2>&1)"
    grep -q 'Signature=adhoc' <<< "$SIGNATURE_INFO" || {
        echo "La firma de $bundle no es ad hoc." >&2
        exit 1
    }
    ENTITLEMENTS_FILE="$(mktemp "${RUNNER_TEMP:-/tmp}/stacklume-entitlements.XXXXXX")"
    codesign -d --entitlements :- "$bundle" > "$ENTITLEMENTS_FILE" 2>/dev/null
    GET_TASK_ALLOW="$(plutil -extract 'com\.apple\.security\.get-task-allow' raw -o - "$ENTITLEMENTS_FILE" 2>/dev/null || true)"
    [[ "$GET_TASK_ALLOW" != "true" ]] || {
        echo "La build de distribución contiene get-task-allow en $bundle." >&2
        exit 1
    }
    rm -f "$ENTITLEMENTS_FILE"
done

if spctl --assess --type execute --verbose=2 "$APP_PATH" >/dev/null 2>&1; then
    echo "Aviso: Gatekeeper aceptó la app en este entorno; comprueba manualmente una descarga con cuarentena."
else
    echo "Gatekeeper identifica la build ad hoc como no notarizada, según lo previsto."
fi

VERIFY_DIR="$(mktemp -d "${RUNNER_TEMP:-/tmp}/stacklume-release-verification.XXXXXX")"
trap 'find "$VERIFY_DIR" -depth -delete' EXIT
ditto -x -k "$ZIP_PATH" "$VERIFY_DIR"
EXTRACTED_APP="$VERIFY_DIR/Stacklume.app"
[[ -d "$EXTRACTED_APP" ]] || {
    echo "El ZIP no contiene Stacklume.app en su raíz." >&2
    exit 1
}
[[ "$(lipo -archs "$EXTRACTED_APP/Contents/MacOS/Stacklume")" == "arm64" ]] || {
    echo "El binario comprimido no es exclusivamente arm64." >&2
    exit 1
}
verify_free_edition "$EXTRACTED_APP"
codesign --verify --deep --strict --verbose=2 "$EXTRACTED_APP"
"$SCRIPT_DIR/verify-runtime-signing.sh" "$EXTRACTED_APP"
xmllint --noout "$APPCAST_PATH"
grep -q 'sparkle:edSignature=' "$APPCAST_PATH" || {
    echo "El appcast no contiene una firma EdDSA de Sparkle." >&2
    exit 1
}
RELEASES_REPOSITORY="${STACKLUME_RELEASES_REPOSITORY:-SwonDev/Stacklume-Mac-Releases}"
grep -q "github.com/$RELEASES_REPOSITORY/releases/download/" "$APPCAST_PATH" || {
    echo "El appcast no apunta al repositorio binario previsto." >&2
    exit 1
}

echo "Release verificada: arm64, gratuita, Hardened Runtime compatible con Sparkle, firma ad hoc íntegra y appcast EdDSA."
