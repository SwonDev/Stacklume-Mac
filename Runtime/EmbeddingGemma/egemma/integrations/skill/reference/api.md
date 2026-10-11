# API HTTP del servicio (http://127.0.0.1:8737)

La documentación interactiva está en `http://127.0.0.1:8737/docs` (OpenAPI). Los errores siguen el formato de OpenAI: `{"error": {"message", "type"}}`, con 400 si la entrada no es válida, 401 si falta la clave, 403 si la petición viene de otra web (cabeceras `Origin` o `Sec-Fetch-Site` ajenas) y 500/503 si falla el modelo. Desde el navegador no se puede llamar directamente: hazlo desde el backend.

| Método y ruta | Para qué |
|---|---|
| `GET /llms.txt` | Esta referencia en texto plano, para cualquier LLM que llegue al servidor |
| `GET /guide/apps`, `GET /guide/api` | Las guías de integración y de la API en Markdown |
| `GET /health` | Estado: modelo cargado o no, GPU, VRAM, modalidades, colecciones, trabajos activos |
| `GET /v1/models` | Lista OpenAI (`embeddinggemma-2`) |
| `POST /v1/embeddings` | Compatible con OpenAI. Campos: `input`, `model` (admite el sufijo `:tarea`), `dimensions`, `encoding_format` (`float`/`base64`). Extras: `task`, `title` y las opciones de medios |
| `POST /embed` | Nativo: `inputs`, `task`, `title`, `dimensions`, `encoding_format` y las opciones de medios. Devuelve `embeddings`, `modalities`, `prompts` y `elapsed_ms` |
| `POST /similarity` | `a`, `b`, `task_a`, `task_b` → matriz `scores` |
| `POST /index` | `path`, `collection?`, `wait` (s) → trabajo |
| `GET /jobs`, `GET /jobs/{id}?wait=s`, `DELETE /jobs/{id}` | Progreso y cancelación del indexado |
| `POST /search` | `query` o `file`; además `path`, `collection`, `k`, `kinds`, `task`, `refresh`, `wait`. Devuelve `results` con `path`, `location`, `score`, `kind`, `modality` y `preview` |
| `GET /collections`, `GET /collections/{name}`, `DELETE /collections/{name}` | Colecciones |
| `POST /unload` | Descarga el modelo de la GPU ahora |
| `POST /shutdown` | Para el servidor (`egemma stop`) |

## Acceso y archivos

Todas las operaciones requieren `Authorization: Bearer …`, también en localhost. La CLI y el MCP comparten automáticamente una clave aleatoria guardada con permisos 0600 en `EGEMMA_HOME/api-token` (por defecto `~/.embeddinggemma/api-token`). Para un cliente HTTP propio o un servicio remoto, proporciona `EGEMMA_API_KEY` mediante tu gestor de secretos y envía esa misma clave desde el cliente; nunca la incluyas en código ni en URLs.

`/health` sin clave solo identifica el servicio. Con la clave devuelve el estado detallado. Los clientes CLI/MCP verifican además una prueba de identidad antes de enviar la clave al puerto configurado. `/docs` y `/openapi.json` conservan el esquema público; sus operaciones requieren autenticación.

Los archivos locales deben ser originales regulares: no se aceptan enlaces simbólicos, rutas de red ni archivos/carpetas de credenciales. Las URLs de medios solo pueden apuntar a direcciones públicas; cada redirección vuelve a comprobarse. Las data URIs conservan el límite de tamaño de los medios.

## Opciones de medios

Valen en `/v1/embeddings`, `/embed` y `/similarity`:

- `image_tokens`: 70, 140, 280 (por defecto), 560 o 1120. Más tokens dan más detalle a cambio de más latencia y más contexto.
- `video_tokens`: tokens por fotograma, 140 por defecto.
- `video_fps` (1 por defecto), `video_max_frames` (32 por defecto, máx. 114) y `video_overflow` (`uniform` o `truncate`).
- `video_timestamps`: escribe el `mm:ss` de cada fotograma en la entrada.

## Configuración

`~/.embeddinggemma/config.json`. Cada campo se puede sobrescribir con la variable `EGEMMA_<CAMPO>`.

| Campo | Por defecto | Nota |
|---|---|---|
| `host` / `port` | `127.0.0.1` / `8737` | Siempre requiere Bearer; genera una clave privada en localhost. Fuera de localhost exige `EGEMMA_API_KEY` explícita |
| `device` | `auto` | `cuda`, `mps` o `cpu` |
| `dtype` | `auto` | `bfloat16` o `float32`; float16 se rechaza |
| `modalities` | las cuatro | Quitar `audio` ahorra 300M parámetros; quitar `image` y `video`, 170M más |
| `idle_unload_minutes` | 10 | 0 = no descargar nunca |
| `request_timeout_s` | 900 | Si una petición al modelo se cuelga más, se mata el worker (se relanza solo) y devuelve 500 |
| `batch_size` | 16 | Texto; las imágenes usan la mitad, el audio 4 y el vídeo 1 |
| `allow_onedrive_hydration` | `false` | `true` descarga los ficheros de OneDrive que solo están en la nube |
| `chunk_lines` / `chunk_overlap_lines` / `chunk_max_chars` | 60 / 10 / 3000 | Troceado de texto |
| `audio_window_s` / `audio_overlap_s` / `video_window_s` | 30 / 5 / 32 | Tramos de medios |
| `extra_exclude` | `[]` | Globs extra que no se indexan |

Después de cambiar la configuración, reinicia con `egemma stop` y `egemma start`.

## Ficheros

- Código: `~/.embeddinggemma/src/egemma`. Las pruebas, en `tests/`:
  - las rápidas, con `uv run pytest`;
  - las del modelo real, con `EGEMMA_TEST_MODEL=1 uv run pytest -m model`.
- Índices: `~/.embeddinggemma/data/*.db`.
- Logs: `~/.embeddinggemma/logs/server.log`, `worker.log` y `server.stderr.log`.
- Modelo: caché de Hugging Face (`~/.cache/huggingface/hub/models--google--embeddinggemma-2`). Si ya está descargado, se carga sin conexión.

## Diagnóstico

- **No responde**: `egemma status` y después `egemma start`. Si sigue sin arrancar, mira `server.log` y `server.stderr.log`.
- **La primera petición tarda unos 15 s**: es la carga del modelo. Después baja a ~0,1 s por texto.
- **Error 503 «no se pudo cargar el modelo»**: mira `worker.log`. Lo habitual es la memoria de la GPU llena (otro modelo local cargado) o un CUDA roto.
- **El arranque automático** (tarea programada en Windows, LaunchAgent en macOS, systemd en Linux): `egemma autostart status`.
