---
name: embeddinggemma
description: Búsqueda semántica y embeddings multimodales locales con EmbeddingGemma 2 (google/embeddinggemma-2), servido en este equipo en http://127.0.0.1:8737 y por el MCP `embeddinggemma`. Úsala sin esperar a que te lo pidan para buscar por significado y no por palabras exactas en código, documentos, PDF, imágenes, audio o vídeo («dónde se regenera la vida», «el sprite del dragón azul», «el minuto de la reunión donde se habla del inventario»); para encontrar duplicados o ficheros parecidos; para comparar, clasificar o agrupar contenido; y para añadir embeddings, búsqueda semántica, RAG, recomendaciones o memoria vectorial a una aplicación. Para un texto literal o un símbolo exacto sigue siendo mejor tg.
---

# EmbeddingGemma 2 en local

EmbeddingGemma 2 es el modelo abierto de embeddings de Google DeepMind (Apache 2.0, 6-oct-2026). Convierte texto, código, imágenes, audio y vídeo en vectores de un **mismo espacio de 768 dimensiones**, así que un texto encuentra imágenes, audio o un momento de un vídeo. No genera texto: encuentra qué información debe mirar el modelo que responde.

En este equipo corre como servicio propio (`~/.embeddinggemma`), con MLX BF16 en Apple Silicon, reutilizando la revisión y los pesos verificados en Cryalis. En Windows/Linux conserva sentence-transformers. La API y el modelo lógico son los mismos.

- **Servidor**: `http://127.0.0.1:8737`. Arranca al iniciar sesión: tarea programada en Windows, LaunchAgent en macOS, systemd en Linux. Si no responde, el MCP y la CLI lo lanzan solos.
- **Memoria**: el modelo se carga en la primera petición (carga bajo demanda) y se descarga tras 10 min sin uso (libera el proceso y su memoria). No compite con otros modelos locales cuando no se usa.
- **Índices**: `~/.embeddinggemma/data/<colección>.db` (SQLite + sqlite-vec), fuera de los repos.
- **Para cualquier LLM**: `GET http://127.0.0.1:8737/llms.txt` explica la API. La herramienta MCP `integration_guide` da las recetas de integración.

## Úsala sin esperar a que te lo pidan

- El usuario pregunta dónde se hace algo y no sabes cómo se llama, o grep no lo encuentra: `semantic_search` con `path` = carpeta del proyecto.
- Hay que localizar un recurso por lo que muestra o suena (sprite, icono, foto, sonido, clip, página de PDF): `semantic_search` con `kinds`.
- Hay que encontrar repetidos o parecidos: `find_similar`.
- El proyecto necesita búsqueda semántica, RAG, recomendaciones, deduplicado, clasificación o clustering:
  - propón EmbeddingGemma 2 e intégralo tú;
  - en desarrollo, contra la API local;
  - en producción, con el runtime adecuado: `integration_guide` o [reference/integracion-apps.md](reference/integracion-apps.md).
- No cambies a otro modelo de embeddings sin permiso del usuario: este es el elegido.

## Cuándo usar cada herramienta

| Necesidad | Herramienta |
|---|---|
| Texto literal, nombre de función, regex | `tg` |
| «Dónde se hace X» sin saber cómo se llama | `semantic_search` con `path` del repo y `kinds: ["code"]` |
| Buscar recursos por descripción (sprites, iconos, fotos, sonidos, clips) | `semantic_search` con `kinds: ["image"]`, `["audio"]` o `["video"]` |
| Momento exacto de una grabación o vídeo | `semantic_search`: devuelve `mm:ss-mm:ss` |
| Página de un PDF (también escaneados) | `semantic_search` con `kinds: ["pdf"]` |
| Duplicados o casi duplicados | `find_similar` (≥ 0,95 suele ser el mismo recurso) |
| ¿Encaja esta imagen con esta descripción? ¿Qué etiqueta le toca? | `compare` |
| Embeddings, RAG o búsqueda semántica dentro de una app | `integration_guide` y [reference/integracion-apps.md](reference/integracion-apps.md) |

## Herramientas MCP (`embeddinggemma`)

- `semantic_search(query | file, path?, collection?, kinds?, k=10, refresh=true)`:
  - Con `path`, indexa o pone al día la carpeta de forma incremental antes de buscar. Espera hasta 120 s; si no termina, avisa y devuelve lo que hay.
  - Sin path ni collection, usa la carpeta de trabajo del cliente. No mezcla proyectos implícitamente ni indexa la carpeta personal o la raíz del disco.
  - `file` usa un fichero como consulta.
- `find_similar(file, path?, kinds?, k)`: los ficheros más parecidos a uno dado.
- `index_path(path, wait_seconds=120)` e `index_status(job_id)`: indexado explícito y su progreso.
- `compare(a, b, task="similarity")`: matriz coseno entre dos listas de entradas de cualquier modalidad.
- `embed(inputs, task?, dimensions)`: vectores (hasta 16 entradas; para lotes, la API HTTP).
- `integration_guide(topic)`: recetas para integrarlo en una app. Temas: `all`, `node`, `python`, `multimodal`, `browser`, `llama.cpp`, `android`, `apple`, `patterns`, `api`.
- `list_collections`, `drop_collection(name)` (destructivo: confírmalo antes) y `service_status`.

Formato de entrada (en `compare`, `embed` y la API): un texto, o un objeto con rutas, URLs o data URIs.

```json
"un texto"
{"image": "/ruta/sprite.png"}
{"audio": {"src": "reunion.mp4", "start": 600, "end": 630}}
{"video": "demo.mp4"}
{"pdf": {"src": "manual.pdf", "page": 3}}
{"text": "Zapatilla impermeable <|image|> prueba de agarre <|video|>", "image": "z.jpg", "video": "g.mp4"}
```

Sin marcadores `<|image|>`/`<|audio|>`/`<|video|>`, el contenido se coloca en el orden de las claves. Varias entradas de una misma clave (lista) dan **un solo** vector conjunto.

## Qué se indexa

- **Código y texto** en trozos de 60 líneas con 10 de solape, con el formato de documento `title: <ruta> | text: <trozo>`. Los resultados dan el rango de líneas.
- **PDF**: el texto, por página. Las páginas escaneadas o casi sin texto se indexan como imagen.
- **Imágenes**: un vector por imagen.
- **Audio**: tramos de 30 s con 5 de solape.
- **Vídeo**: tramos de 32 s (1 fps), con la imagen y el sonido en vectores separados.
- **Nunca se indexa**:
  - lo que excluye `.gitignore`, más `node_modules`, `dist`, `.venv`, etc.;
  - credenciales: `.env*` (salvo `.env.example`), claves, `*.pem`;
  - lockfiles, minificados y bases de datos.
- **Bloqueos**:
  - Los ficheros de nube sin descargar (OneDrive o iCloud bajo demanda) se saltan.
  - Se niega a indexar el perfil, un disco entero, la raíz de OneDrive o rutas de red.
  - No acepta más de 50.000 ficheros por raíz.
- **Incremental**: solo reprocesa lo que cambió y quita lo borrado.

## Tareas (prefijos) — importan para la calidad

El modelo se entrenó con prefijos de tarea. El servicio los pone solo, y únicamente en el texto: imagen, audio y vídeo van sin prefijo.

| `task` | Prefijo | Uso |
|---|---|---|
| `query` | `task: search result \| query: ` | consulta de búsqueda (por defecto en `semantic_search`) |
| `document` (+ `title`) | `title: {title} \| text: ` | lo que se indexa |
| `code_query` | `task: code retrieval \| query: ` | buscar código (por defecto con `kinds: ["code"]`) |
| `question` | `task: question answering \| query: ` | RAG de preguntas |
| `fact_check` | `task: fact checking \| query: ` | buscar pruebas de una afirmación |
| `classification`, `clustering`, `similarity` | `task: … \| query: ` | simétricas: el mismo prefijo en ambos lados |

Se aceptan también los nombres de sentence-transformers (`SearchQuery`, `Document`, `CodeRetrieval`…). Por HTTP, si el cliente solo deja poner el modelo, la tarea va como sufijo: `embeddinggemma-2:query`, `embeddinggemma-2:document`.

## CLI (`egemma`, en `~/.local/bin`)

```bash
egemma status                       # estado del servicio y del modelo
egemma index <carpeta>              # indexa o pone al día
egemma search "consulta" -p <carpeta> --kinds code,doc -k 5
egemma similar <fichero> --kinds image
egemma collections | egemma drop <nombre> | egemma unload | egemma stop | egemma start
egemma setup                        # (re)instala skill, MCP, hook y arranque en todos los asistentes
```

## Reglas

- **Nunca uses float16** si cargas el modelo en PyTorch tú mismo: da NaN o vectores degradados sin avisar. Usa bf16 donde haya soporte nativo, y si no, float32. El ONNX es otra cosa: su fp16 está validado.
- **Matryoshka**: 768, 512, 256 o 128 dimensiones. Recorta y **vuelve a normalizar** (la API lo hace con `dimensions`). Consultas y documentos deben tener la misma dimensión. Hasta 256 apenas pierde calidad; con 128 la parte multimodal cae mucho.
- **Contexto**: 8.192 tokens compartidos. Una imagen ocupa 280 tokens (configurable entre 70 y 1.120 con `image_tokens`), un fotograma 140 (`video_tokens`; máx. 32 por defecto) y el audio 25 tokens por segundo (unos 327 s). Para medios largos usa `start`/`end` o el indexado, que ya trocea.
- **Rutas**: la API las resuelve en el servidor; pásalas absolutas. El MCP resuelve las relativas respecto a la carpeta de trabajo.
- **Desde el navegador no se puede**: la API rechaza peticiones con `Origin` ajeno. Llámala desde el backend o el proceso.
- Si algo falla: `egemma status`, y los logs `~/.embeddinggemma/logs/server.log` y `worker.log`. Más detalles en [reference/api.md](reference/api.md).
