#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 && $# -ne 3 ]]; then
    echo "Uso: $0 <Stacklume.app> [SHA1 del certificado TeamID]" >&2
    exit 64
fi

APP_PATH="$1"
EXPECTED_CERTIFICATE="${2:-}"
EXPECTED_TEAM="${3:-}"
if [[ -n "$EXPECTED_CERTIFICATE" ]]; then
    [[ "$EXPECTED_CERTIFICATE" =~ ^[A-Fa-f0-9]{40}$ && "$EXPECTED_TEAM" =~ ^[A-Z0-9]{10}$ ]] || {
        echo "El certificado o TeamID esperado no es válido." >&2
        exit 64
    }
    EXPECTED_CERTIFICATE="$(tr '[:lower:]' '[:upper:]' <<< "$EXPECTED_CERTIFICATE")"
fi
CHECK_DIRECTORY="$(mktemp -d "${RUNNER_TEMP:-/tmp}/stacklume-runtime-signing.XXXXXX")"
trap 'rm -rf "$CHECK_DIRECTORY"' EXIT
MAIN_BINARY="$APP_PATH/Contents/MacOS/Stacklume"
SPARKLE_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION="$SPARKLE_FRAMEWORK/Versions/Current"

[[ -d "$APP_PATH" ]] || { echo "No existe la app: $APP_PATH" >&2; exit 1; }
[[ -f "$MAIN_BINARY" ]] || { echo "Falta el binario principal: $MAIN_BINARY" >&2; exit 1; }
[[ -d "$SPARKLE_FRAMEWORK" ]] || {
    echo "Falta Sparkle.framework: $SPARKLE_FRAMEWORK" >&2
    exit 1
}

signature_info() {
    codesign -d --verbose=4 "$1" 2>&1
}

assert_runtime_signature() {
    local code_path="$1"
    local info
    info="$(signature_info "$code_path")"

    if [[ -z "$EXPECTED_CERTIFICATE" ]]; then
        grep -q '^Signature=adhoc$' <<< "$info" || {
            echo "La firma de $code_path no es ad hoc." >&2
            exit 1
        }
        grep -q '^TeamIdentifier=not set$' <<< "$info" || {
            echo "La firma ad hoc de $code_path contiene un Team ID inesperado." >&2
            exit 1
        }
    else
        grep -Fxq "TeamIdentifier=$EXPECTED_TEAM" <<< "$info" || {
            echo "El TeamID de $code_path no coincide con el esperado." >&2
            exit 1
        }
        local certificate_prefix="$CHECK_DIRECTORY/certificate"
        rm -f "$certificate_prefix"*
        codesign -d --extract-certificates="$certificate_prefix" "$code_path" 2>/dev/null
        local fingerprint
        fingerprint="$(openssl x509 -inform DER -in "${certificate_prefix}0" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')"
        [[ "$fingerprint" == "$EXPECTED_CERTIFICATE" ]] || {
            echo "El certificado de $code_path no coincide con el esperado." >&2
            exit 1
        }
        codesign --verify --strict -R="anchor apple generic and certificate leaf[subject.OU] = \"$EXPECTED_TEAM\"" "$code_path"
        local requirement
        requirement="$(codesign -d -r- "$code_path" 2>&1)"
        if ! grep -q 'anchor apple generic' <<< "$requirement" || ! grep -q 'certificate leaf' <<< "$requirement" || grep -q 'cdhash' <<< "$requirement"; then
            echo "La identidad de $code_path no está ligada a un certificado Apple estable." >&2
            exit 1
        fi
    fi
    grep -q '^Runtime Version=' <<< "$info" || {
        echo "Hardened Runtime no está activo en $code_path." >&2
        exit 1
    }
    codesign --verify --strict --verbose=2 "$code_path"
}

assert_runtime_signature "$APP_PATH"

ENTITLEMENTS_FILE="$CHECK_DIRECTORY/entitlements.plist"
codesign -d --entitlements :- "$APP_PATH" > "$ENTITLEMENTS_FILE" 2>/dev/null

DISABLE_LIBRARY_VALIDATION="$(
    plutil -extract 'com\.apple\.security\.cs\.disable-library-validation' raw \
        -o - "$ENTITLEMENTS_FILE" 2>/dev/null || true
)"
[[ "$DISABLE_LIBRARY_VALIDATION" == "true" ]] || {
    echo "La build ad hoc con Hardened Runtime no puede cargar Sparkle sin" >&2
    echo "com.apple.security.cs.disable-library-validation=true." >&2
    exit 1
}

declare -a SPARKLE_CODE=(
    "$SPARKLE_VERSION/XPCServices/Installer.xpc"
    "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
    "$SPARKLE_VERSION/Autoupdate"
    "$SPARKLE_VERSION/Updater.app"
    "$SPARKLE_FRAMEWORK"
)
for code_path in "${SPARKLE_CODE[@]}"; do
    [[ -e "$code_path" ]] || { echo "Falta código de Sparkle: $code_path" >&2; exit 1; }
    assert_runtime_signature "$code_path"
done

if [[ -n "$EXPECTED_CERTIFICATE" ]]; then
    for code_path in "$APP_PATH"/Contents/PlugIns/*.appex; do
        [[ -e "$code_path" ]] || continue
        assert_runtime_signature "$code_path"
    done
fi

if [[ -n "$EXPECTED_CERTIFICATE" ]]; then
    echo "Firma runtime verificada: certificado y TeamID esperados, identidad estable y Sparkle."
else
    echo "Firma runtime verificada: Hardened Runtime ad hoc compatible con Sparkle."
fi
