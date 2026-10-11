# Compilaciones públicas y releases oficiales

Stacklume para Mac es gratis para siempre. Su código propio se publica bajo MIT; las dependencias mantienen sus licencias. El código fuente permite compilar la app sin claves privadas ni secretos de GitHub. Consulta [la preparación local](../README.md) y [la instalación](INSTALLATION.md).

## Artefactos de CI

El workflow [release.yml](../.github/workflows/release.yml) se ejecuta con etiquetas `v*` o manualmente mediante `workflow_dispatch`. En una etiqueta exige que `v<versión>` coincida con `MARKETING_VERSION` de `project.yml`; en una ejecución manual toma la versión del código seleccionado. Ambos modos requieren sus notas en `docs/releases/<versión>.md` y conservan el sello de compilación del proyecto.

La CI usa el runner alojado `xcode-27` ARM64 y comprueba Xcode 27.0, build `27A266a`. XcodeGen 2.46.0, uv 0.13.0 y Python 3.12.15 están fijados; las acciones están fijadas por SHA y las descargas de XcodeGen y uv se verifican por SHA-256. Las dependencias se obtienen de `Config/Package.resolved` y `Runtime/EmbeddingGemma/uv.lock`. La imagen alojada y los activos de Apple pueden cambiar: son compilaciones con herramientas y dependencias fijadas, sin garantía de igualdad binaria byte a byte.

Después del bootstrap, la CI verifica el checksum del runtime y ejecuta sus regresiones de frontera, memoria y cierre con Hugging Face en modo offline. Esas pruebas no cargan pesos ni certifican la inferencia completa de `runtime_smoke.py`. La preparación inicial de herramientas, dependencias y activos lingüísticos de Apple sí necesita conexión.

También ejecuta los tests Swift, archiva la app y sus extensiones exclusivamente para ARM64, y verifica la firma ad hoc, Hardened Runtime y los componentes de Sparkle. El artefacto de Actions, conservado durante 14 días, contiene:

- `Stacklume-<versión>-ci-arm64.zip`, con `Stacklume.app`.
- Su archivo `.sha256`, comprobable con `shasum -a 256 -c <archivo>.sha256`.
- `BUILD-INFO.txt`, con revisión, ejecución, herramientas y checksums de los manifiestos.

La CI solo tiene permiso de lectura del repositorio. No publica releases, no genera `appcast.xml` y no recibe claves privadas. La firma ad hoc no equivale a Developer ID ni a notarización de Apple.

## Release oficial

El mantenedor prepara y valida la distribución en su pipeline privado y firma el ZIP definitivo para Sparkle con la clave Ed25519 existente. La clave nunca se incorpora al código, al workflow público ni a sus artefactos. La [release principal](https://github.com/SwonDev/Stacklume-Mac/releases) publica el ZIP oficial y su SHA-256 junto al código fuente. El [canal de compatibilidad para actualizaciones](https://github.com/SwonDev/Stacklume-Mac-Releases/releases) conserva el mismo ZIP, con bytes y checksum idénticos, y `appcast.xml` con la firma EdDSA para esa versión. Así las instalaciones anteriores mantienen su feed de Sparkle.

Antes de publicar, el mantenedor ejecuta `scripts/release/verify-release.sh <Stacklume.app> <ZIP> <appcast.xml>` y comprueba criptográficamente la firma con las herramientas de Sparkle. Ese script exige un appcast y por eso no se usa en la CI pública; esta ejecuta por separado `verify-runtime-signing.sh` y las comprobaciones del bundle. El código fuente público y los artefactos de CI permiten inspeccionar y compilar la app; solo el canal oficial proporciona actualizaciones autenticadas por la clave pública incluida en `Info.plist`.

Referencias: [runner ARM64 con Xcode 27](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md), [XcodeGen 2.46.0](https://github.com/yonaskolb/XcodeGen/releases/tag/2.46.0), [artefactos de GitHub Actions](https://github.com/actions/upload-artifact) y [firma de actualizaciones de Sparkle](https://sparkle-project.org/documentation/).
