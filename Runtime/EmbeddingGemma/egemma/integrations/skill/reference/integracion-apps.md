# Integrar EmbeddingGemma 2 en una aplicación

Primero decide **dónde corre el modelo**. El servidor de `127.0.0.1:8737` solo existe en este equipo.

| La app es… | Dónde corre el modelo | Cómo |
|---|---|---|
| Herramienta interna, script o backend que corre en este equipo | El servicio local | API compatible con OpenAI (abajo) |
| Web que corre en el navegador del usuario | En el navegador (WebGPU/WASM) | transformers.js ≥ 4.3.1 + `onnx-community/embeddinggemma-2-ONNX` |
| Backend en Node desplegado (Vercel, VPS…) | En el propio backend o en un servidor de embeddings | transformers.js en Node (`device: "cpu"`), o llama.cpp `llama-server` con el GGUF; en Vercel pesa demasiado para una función: mejor un servidor aparte |
| Android | En el dispositivo | LiteRT-LM con `litert-community/embeddinggemma-2-*-litert-lm` |
| macOS / iOS | En el dispositivo | MLX (`mlx-community/embeddinggemma-2-*`) o LiteRT-LM (Swift) |
| Capacitor | En el dispositivo o en el servidor | Plugin nativo con LiteRT-LM, o servidor; WebGPU en WebView no es fiable |

Desplegar el servicio en un servidor remoto o en el VPS requiere permiso explícito del usuario: el destino, la operación y la credencial. Por defecto, todo queda en local.

**Siempre**:

- Mismo modelo y misma dimensión para consultas y documentos. Un índice creado con otro modelo no vale: hay que reindexar.
- El prefijo de tarea va en el texto: `task: search result | query: …` para consultas, `title: … | text: …` para documentos. Los medios no llevan prefijo.
- Normaliza en float32 tras recortar (Matryoshka 768/512/256/128).
- La base de datos es SQLite (preferencia del usuario) con **sqlite-vec**: tabla `vec0` con `distance_metric=cosine`.

## 1. Contra el servicio local (API compatible con OpenAI)

Base URL `http://127.0.0.1:8737/v1`, modelo `embeddinggemma-2`. Cualquier clave vale (no se comprueba en local). La tarea va en el nombre del modelo (`embeddinggemma-2:query`) o en el campo extra `task`.

### Node / TypeScript (probado con `openai` 7.28 y `node:sqlite` en Node 26)

```ts
import OpenAI from "openai";
import { DatabaseSync } from "node:sqlite";
import * as sqliteVec from "sqlite-vec";

const ai = new OpenAI({ baseURL: "http://127.0.0.1:8737/v1", apiKey: "local" });
const DIM = 768;

async function embed(input: string[], task: "query" | "document" | "code_query") {
  const res = await ai.embeddings.create({ model: `embeddinggemma-2:${task}`, input, dimensions: DIM });
  return res.data.map((d) => Float32Array.from(d.embedding));
}

const db = new DatabaseSync("app.db", { allowExtension: true });
sqliteVec.load(db);
db.exec(`CREATE VIRTUAL TABLE IF NOT EXISTS docs_vec USING vec0(
  doc_id INTEGER PRIMARY KEY, embedding float[${DIM}] distance_metric=cosine)`);

// Insertar: new Uint8Array(vec.buffer); la clave como BigInt
db.prepare("INSERT INTO docs_vec(doc_id, embedding) VALUES (?, ?)").run(1n, new Uint8Array(vectors[0].buffer));

// Buscar (1 - distance = similitud coseno)
const [q] = await embed(["¿cuánto se cura el personaje?"], "query");
const rows = db.prepare(
  `SELECT doc_id, 1 - distance AS score FROM docs_vec WHERE embedding MATCH ? AND k = 10 ORDER BY distance`,
).all(new Uint8Array(q.buffer));
```

Con better-sqlite3 se carga igual (`sqliteVec.load(db)`) y acepta el `Float32Array` directamente, pero necesita aprobar su script de compilación (`pnpm approve-builds`).

### Python (httpx)

```python
import httpx

r = httpx.post("http://127.0.0.1:8737/v1/embeddings", json={
    "model": "embeddinggemma-2", "task": "query", "input": ["¿cuánto se cura el personaje?"], "dimensions": 256,
}, timeout=120)
vec = r.json()["data"][0]["embedding"]
```

### Multimodal (`POST /embed`)

```ts
const res = await fetch("http://127.0.0.1:8737/embed", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    inputs: [
      { image: "C:/assets/dragon.png" },
      { audio: { src: "C:/grabaciones/reunion.m4a", start: 600, end: 630 } },
      { video: "https://…/clip.mp4" },
      { text: "Zapatilla impermeable <|image|>", image: "data:image/jpeg;base64,…" },
    ],
    dimensions: 768,
  }),
});
const { embeddings, modalities } = await res.json();
```

También acepta el formato de llama.cpp/OpenAI en `/v1/embeddings`: `{"input": [{"content": [{"type": "image_url", "image_url": {"url": "data:…"}}]}]}`. Las partes pueden ser `text`, `image_url`, `input_audio` (`{data, format}`) y `video_url`.

## 2. En el navegador o en Node, sin servidor: transformers.js

Necesita `@huggingface/transformers` ≥ 4.3.1, la primera versión con EmbeddingGemma 2. Salió el 06-10-2026, así que con `minimum-release-age=1440` pnpm no la instala hasta pasadas 24 h. Comprueba la versión con `pnpm view @huggingface/transformers version` y la API con Context7 antes de escribir código.

```js
import { pipeline, matmul } from "@huggingface/transformers";

const extractor = await pipeline("feature-extraction", "onnx-community/embeddinggemma-2-ONNX", {
  device: "webgpu", // "wasm" en navegadores sin WebGPU, "cpu" en Node
  dtype: "q4",
});
const out = await extractor(
  ["task: search result | query: dónde se cura el jugador", "title: none | text: …"],
  { pooling: "mean", normalize: true },
);
```

Para imagen, audio y vídeo se usan `AutoProcessor` y `AutoModel`, junto con `load_image`, `load_audio(url, 16000)` y `load_video(url, { fps: 1 })`. La llamada es `processor(text, images, audio, videos)` y el resultado está en `.sentence_embedding`. Ojo con las listas:

- `processor(null, [[img1], [img2]])` devuelve dos vectores;
- `processor(null, [img1, img2])` devuelve uno conjunto.

| dtype | Texto | Visión | Audio | Total | Coseno frente a fp32 |
|---|---|---|---|---|---|
| q4 | 175 MB | 109 MB | 189 MB | 473 MB | 0,975 (texto 0,988) |
| q8 | 314 MB | 195 MB | 340 MB | 850 MB | 0,9997 |
| fp16 | 543 MB | 336 MB | 587 MB | 1.465 MB | 0,9998 |

## 3. Servidor alternativo: llama.cpp

Sirve si el proyecto ya usa llama.cpp o necesita un binario sin Python:

- **Versión**: build b11457 o posterior (el soporte llegó con la PR #30054, el 06-10-2026).
- **Ficheros**: `ggml-org/embeddinggemma-2-GGUF`, con su `mmproj`.
- **Arranque**: `llama-server -m embeddinggemma-2-Q8_0.gguf --mmproj mmproj-embeddinggemma-2-Q8_0.gguf --embeddings`.
- **Imágenes**: van anidadas en `input: [{"content": [{"type": "image_url", …}]}]`. Si las partes van directamente en `input`, da error 400.
- **Lo que no cubre**: el audio está en fase experimental y el vídeo no es nativo (habría que mandar fotogramas). Por eso el servicio de este equipo usa la implementación oficial.

## 4. Android y Apple

- **LiteRT-LM**: `litert-community/embeddinggemma-2-text-270m-litert-lm` (165 MB, solo texto), `…-text-vision-440m-…` (388 MB) y `…-740m-…` (485 MB, todas las modalidades). Tiene API en Kotlin, Swift, C++, Python y JS. Antes de escribir código, consulta la doc vigente: `android docs` o Context7.
- **MLX (Mac)**: `mlx-community/embeddinggemma-2-bf16`, `-8bit`, `-4bit`, etc.

## Patrones

- **RAG**:
  1. Trocea los documentos (500–3.000 caracteres) e indexa cada trozo con `title: <fuente> | text: <trozo>`.
  2. Embebe la pregunta con `question` o `query`.
  3. Recupera los 5–20 trozos más cercanos y pásaselos al LLM con su fuente.
- **Código**: consultas con `code_query`; documentos con `title: <ruta> | text: <código>`.
- **Clasificación sin entrenar**: embebe las etiquetas y el contenido con `classification` y quédate con la etiqueta de mayor coseno. Fija un umbral con ejemplos reales.
- **Duplicados**: un coseno ≥ 0,95 entre imágenes suele indicar el mismo recurso. Calibra el umbral con tus datos.
- **Clustering**: usa `clustering` en todos los textos y luego k-means o HDBSCAN sobre los vectores.
- **Almacenamiento**: 768 float32 ocupan 3 KB por vector. A 256 dimensiones se queda en 1 KB, con una pérdida de calidad mínima.
