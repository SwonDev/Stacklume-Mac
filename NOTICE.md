# Dependencias y avisos de terceros

El código propio de Stacklume se distribuye bajo MIT. Cada componente externo conserva sus avisos y su licencia original. Este documento reúne los textos de las dependencias Swift fijadas en `Config/Package.resolved`; las copias se mantienen íntegramente, incluidos los avisos adicionales.

## Dependencias Swift

| Componente y fuente fijada | Versión | Licencia indicada por su texto | Copia del aviso |
|---|---|---|---|
| [eventsource](https://github.com/mattt/EventSource/tree/86b5096ac59ab46e66bd1f6377c604bc1dab0bc2) | 1.5.1 | MIT | [Texto](docs/licenses/eventsource/LICENSE.md) |
| [mlx-swift](https://github.com/ml-explore/mlx-swift/tree/19601207e9a0de51e03ee6ec0c3c5f3784275075) | 0.32.3 | MIT | [Texto](docs/licenses/mlx-swift/LICENSE) |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm/tree/3b339ad6e3b3f44c8121ecff5131c7fd55e075e6) | 3.32.3 | MIT | [Texto](docs/licenses/mlx-swift-lm/LICENSE) |
| [sparkle](https://github.com/sparkle-project/Sparkle/tree/eef1a539a373c1f1a320624b1130fc5de7b2e100) | 2.10.0 | MIT y avisos incluidos | [Texto](docs/licenses/sparkle/LICENSE) |
| [swift-asn1](https://github.com/apple/swift-asn1/tree/3b6410f7dee09eb33cdd26260c5fd47fda19b0e2) | 1.7.3 | Apache-2.0 | [Texto](docs/licenses/swift-asn1/LICENSE.txt) |
| [swift-cmark](https://github.com/swiftlang/swift-cmark/tree/08ddb528923cc1a6527e02b7a1aee9e516ca749a) | 0.9.0 | BSD-2-Clause y avisos incluidos | [Texto](docs/licenses/swift-cmark/COPYING) |
| [swift-collections](https://github.com/apple/swift-collections/tree/3b69cedbaa49957e97c092ae400bb57602ef941f) | 1.7.2 | Apache-2.0 con excepción de biblioteca de ejecución | [Texto](docs/licenses/swift-collections/LICENSE.txt) |
| [swift-crypto](https://github.com/apple/swift-crypto/tree/da9d28d69ebe3894b18376c8f2395c2f37b8448f) | 4.5.2 | Apache-2.0 | [Texto](docs/licenses/swift-crypto/LICENSE.txt) |
| [swift-huggingface](https://github.com/huggingface/swift-huggingface/tree/f0a0cb43cb1b402d2bbf6fb10d8981328c449c48) | 0.13.0 | Apache-2.0 | [Texto](docs/licenses/swift-huggingface/LICENSE) |
| [swift-jinja](https://github.com/huggingface/swift-jinja/tree/4588064a20f3fc093c95f2f7d3359999bf30cae5) | 2.5.1 | Apache-2.0 | [Texto](docs/licenses/swift-jinja/LICENSE) |
| [swift-markdown](https://github.com/swiftlang/swift-markdown/tree/25cb61d3482054b09ae76ca4f281b1bfe7fe5a43) | 0.9.0 | Apache-2.0 con excepción de biblioteca de ejecución | [Texto](docs/licenses/swift-markdown/LICENSE.txt) |
| [swift-numerics](https://github.com/apple/swift-numerics/tree/0c0290ff6b24942dadb83a929ffaaa1481df04a2) | 1.1.1 | Apache-2.0 con excepción de biblioteca de ejecución | [Texto](docs/licenses/swift-numerics/LICENSE.txt) |
| [swift-syntax](https://github.com/swiftlang/swift-syntax/tree/79e4b74a295b6eb74a8b585e3a39d29e70c1dbd1) | 603.0.2 | Apache-2.0 con excepción de biblioteca de ejecución | [Texto](docs/licenses/swift-syntax/LICENSE.txt) |
| [swift-transformers](https://github.com/huggingface/swift-transformers/tree/48473106a93b2d8dfb114b82f0628ebbb71734e7) | 1.3.5 | Apache-2.0 | [Texto](docs/licenses/swift-transformers/LICENSE) |
| [yyjson](https://github.com/ibireme/yyjson/tree/8b4a38dc994a110abaec8a400615567bd996105f) | 0.12.0 | MIT | [Texto](docs/licenses/yyjson/LICENSE) |
| [zipfoundation](https://github.com/weichsel/ZIPFoundation/tree/22787ffb59de99e5dc1fbfe80b19c97a904ad48d) | 0.9.20 | MIT | [Texto](docs/licenses/zipfoundation/LICENSE) |

La adaptación vendored de MLX LM incluye XGrammar: conserva su [licencia Apache-2.0](docs/licenses/xgrammar/LICENSE) y su [NOTICE](docs/licenses/xgrammar/NOTICE) en el árbol vendored. Los componentes incorporados dentro de cada dependencia pueden tener avisos adicionales en su código de origen.

## Runtime y modelos

El runtime de búsqueda utiliza Python y las dependencias declaradas en `Runtime/EmbeddingGemma/pyproject.toml`, fijadas en `uv.lock`. Sus distribuciones conservan sus archivos de licencia. Este inventario Swift no reemplaza los avisos de esas distribuciones ni presenta el runtime entero como software MIT.

Los pesos de los modelos no están incluidos en el código fuente de Stacklume. Consulta sus condiciones en los repositorios de origen antes de redistribuirlos:

- [LiquidAI/LFM2.5-8B-A1B-MLX-8bit](https://huggingface.co/LiquidAI/LFM2.5-8B-A1B-MLX-8bit).
- [google/embeddinggemma-2](https://huggingface.co/google/embeddinggemma-2).
- [mlx-community/embeddinggemma-2-bf16](https://huggingface.co/mlx-community/embeddinggemma-2-bf16).

Los frameworks del sistema y SF Symbols están sujetos a los términos de Apple. Las marcas y el contenido de las páginas que guardes pertenecen a sus respectivos titulares.
