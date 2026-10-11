---
version: "alpha"
name: "Stacklume Mac"
description: "Gestor de marcadores premium nativo de macOS con tema navy y acento dorado."
colors:
  primary: "#D6A62E"
  background: "#01030B"
  surface: "#030D19"
  text-primary: "#F1EFE6"
  accent: "#D6A62E"
typography:
  title:
    fontFamily: "SF Pro"
    fontSize: "22px"
    fontWeight: 700
    lineHeight: 1.2
  body:
    fontFamily: "SF Pro"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.45
  metadata:
    fontFamily: "SF Pro"
    fontSize: "11px"
    fontWeight: 400
    lineHeight: 1.35
rounded:
  chip: "8px"
  card: "14px"
  banner: "16px"
  glass-panel: "20px"
  glass-rail: "24px"
  tooltip: "11px"
  full: "9999px"
spacing:
  xs: "8px"
  sm: "12px"
  md: "16px"
  lg: "24px"
components:
  glass-surface:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.glass-panel}"
    padding: "{spacing.md}"
  glass-control:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.full}"
    padding: "{spacing.xs}"
  glass-tooltip:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.tooltip}"
    padding: "{spacing.xs}"
  button-primary:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.full}"
    padding: "12px"
  state-accent:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.background}"
    rounded: "{rounded.full}"
    padding: "{spacing.xs}"
  content-card:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.card}"
    padding: "16px"
---

# DESIGN.md — Stacklume Mac

Contrato visual y de arquitectura de información (IA) de la app nativa de macOS.
**Precedencia absoluta**: cualquier UI nueva o rediseñada DEBE respetar este documento.
Objetivo: **igualar y superar a [raindrop.io](https://raindrop.io)** en experiencia de
gestor de marcadores, con una **piel premium oscura + dorada** propia de Stacklume
(referencia estética: https://demo.stacklume.app).

---

## 1. Principios

1. **Contenido primero.** La app abre directamente en los enlaces («Todos»), no en un
   dashboard. Nada de bento ni widgets en el inicio. Nada de stickers.
2. **Navegar = Colecciones.** La columna izquierda es un árbol de Colecciones anidadas
   (modelo `BookmarkCategory`), al estilo raindrop, con accesos de sistema arriba y
   Filtros/Etiquetas abajo.
3. **Calma visual.** Mucho aire, jerarquía tipográfica clara, una sola acción primaria
   por pantalla, color usado con intención (el dorado se reserva para acentos/estado).
4. **Premium, no recargado.** Liquid Glass forma una capa funcional continua en la
   navegación, cabeceras, barras de acción, controles y overlays. El contenido sigue
   siendo sólido y calmado: nunca hay cristal en filas, tarjetas ni portadas.
5. **Nativo de Mac.** Selección nativa de `List`, menús contextuales (clic derecho),
   doble clic para abrir, arrastrar para reordenar/anidar, `⌘`-atajos, hover states.

---

## 2. Tokens (NO hardcodear color; usar siempre `palette` y `DesignSystem`)

Del paquete compartido `StacklumeDesignSystem` (tema oscuro por defecto):

| Token | Uso |
|---|---|
| `palette.background` (`#01030b`) | Fondo de ventana (`WindowBackground()`) |
| `palette.surface` (`#030d19`) | Tarjetas, filas, paneles, cabeceras |
| `palette.textPrimary` (`#f1efe6`) | Títulos y texto principal |
| `palette.textSecondary` | Metadatos, dominios, subtítulos, contadores |
| `palette.accent` (`#d6a62e`, dorado) | Estado activo, foco, acción primaria, favorito |
| `palette.border` | Bordes sutiles (usar a `0.5` de grosor y opacidad baja) |
| `Color(hex:)` / `Color(seed:)` | Color de marca de plataforma / color determinista |

Espaciado: `DesignSystem.Spacing.xs=8 · sm=12 · md=16 · lg=24`.
Radio: `DesignSystem.cornerRadius=12` (tarjetas 14, banners 16, paneles de cristal
flotantes 20, rail lateral 24, tooltips 11, chips 8). Las superficies funcionales grandes
nunca terminan en un rectángulo a sangre si pueden expresarse como una lente inset continua.
Tipografía: títulos `.title2/.title3 .weight(.bold)`, cuerpo `.body`, meta `.caption`.
Las barras de scroll doradas (`ScrollerTint`) se mantienen.

---

## 3. Arquitectura de información (mapeo raindrop → Stacklume)

La selección de navegación es un destino `NavTarget` (enum `Hashable` con valores
asociados) que dirige la columna central:

```
NavTarget:
  .all                 → Biblioteca: todos los enlaces activos (LANDING por defecto)
  .inbox               → Bandeja: capturas pendientes (`readingStatus == .inbox`) + triaje guiado
  .unsorted            → Biblioteca filtro onlyUncategorized («Sin clasificar»)
  .favorites           → Biblioteca filtro favoritos
  .readingQueue        → Biblioteca modo cola (readingStatus != .done)
  .collection(UUID)    → Biblioteca filtrada por esa colección (BookmarkCategory) + descendientes
  .tag(UUID)           → Biblioteca filtrada por esa etiqueta
  .smart(SmartFilter)  → Biblioteca con ese filtro inteligente (artículos, vídeos, rotos…)
  .discover            → Sección «Descubrir» (feeds)
  .sessions/.projects/.rules/.stats/.ai/.trash → vistas de herramienta
```

### Sidebar (columna 1) — jerarquía por intención y divulgación progresiva

**Objetivo de diseño:** menos saturación y más reconocimiento. El usuario debe ver de
un vistazo cómo entrar, consultar y organizar su biblioteca **sin recordar dónde se
esconde cada función**. Lo secundario se repliega en grupos colapsables, colapsados por
defecto, que recuerdan su estado.

```
┌ marca Stacklume ───────────────┐
│  ★ Todos                  248   │   ← ① ENTRADAS UNIVERSALES, siempre visibles
│  ▣ Bandeja                 18   │       capturas pendientes; revisión guiada o en lote
│  ✦ Asistente IA       LOCAL     │       preguntar y organizar; estado local explícito
│  ── BIBLIOTECA ───────────────  │   ← ② VISTAS DEL CONTENIDO
│  ☆ Favoritos               34   │
│  🕘 Cola de lectura          9   │
│  ✎ Resaltados               6   │
│  ◇ Sin clasificar          12   │
│  ── EXPLORAR ─────────────────  │   ← ③ CONOCIMIENTO Y FUENTES
│  ⤨ Conexiones                   │
│  🧭 Descubrir                    │
│  @ X                            │
│  ── COLECCIONES ──        [ + ] │   ← ④ árbol BookmarkCategory (siempre visible)
│  ▾ Diseño                  40   │       miniatura de portada o punto de color
│       UI                   22   │       contador a la derecha; clic = navegar
│       Inspiración          18   │       contextual: renombrar/portada/subcolección/borrar
│  ▸ Desarrollo              73   │       arrastrar para reordenar/anidar; NUNCA se colapsa
│  ▸ Etiquetas                    │   ← ⑤ SECUNDARIO, DisclosureGroup colapsado por defecto
│  ▸ Filtros                      │       Filtros = SmartFilter (artículos/vídeos/rotos…)
│  ▸ Herramientas                 │       Herramientas = Sesiones/Reglas/Estadísticas
└ [ +  Nuevo enlace ] (glass) 🗑 ─┘   ← acción primaria fija abajo + Papelera discreta (glass)
```

Niveles de jerarquía:
1. **Entradas universales (siempre visibles, sin cabecera):** «Todos», «Bandeja» y
   «Asistente IA». Son las tres formas fundamentales de usar Stacklume: consultar,
   revisar y conversar con la biblioteca.
2. **Biblioteca y Explorar (siempre visibles, con rótulo sutil):** Favoritos, Cola de
   lectura, Resaltados y Sin clasificar forman «Biblioteca»; Conexiones, Descubrir y X
   forman «Explorar». El rótulo explica la intención sin crear otra navegación.
3. **Colecciones:** árbol principal siempre accesible y expandido por defecto.
4. **Secundario (`DisclosureGroup`, COLAPSADO por defecto):** **Etiquetas** (lista
   potencialmente larga), **Filtros** (SmartFilter) y **Herramientas**. El estado de
   expansión se persiste con `@AppStorage` (`stacklume.sidebar.{tags,filters,tools}Expanded`).

Reglas del sidebar:
- **Una sola lente estructural:** marca, árbol navegable y acción inferior viven dentro
  de un único rail de cristal inset con radio continuo de 24 pt. La marca y el footer
  conservan lentes locales de 18 pt para refractar cualquier fila que pase debajo, pero
  se encajan a solo 5 pt del contorno y con una junta vertical de 1 pt: se leen como zonas
  fijas del mismo material, no como tarjetas separadas. El contorno puede seguir delimitando
  la navegación, pero siempre como una silueta vertical redondeada, nunca como un marco
  rectangular con cortes horizontales.
- **Continuidad al desplazarse:** el árbol pasa bajo las zonas superior e inferior y usa
  bordes de scroll `.soft`; no hay separadores rectos entre marca, navegación y footer.
  Los controles interactivos conservan sus cápsulas dentro de esas lentes locales.
- Fila activa: fondo `palette.accent.opacity(0.14)` + texto/icono en `accent` (selección nativa de `List`).
- Contadores en `palette.textSecondary`, alineados a la derecha, `.monospacedDigit()`.
- Colección con portada: miniatura 18×18 redondeada; si no, punto/icono en su `colorHex`.
- **Densidad:** sin cabeceras gritonas. Las cabeceras de sección y las etiquetas de los
  `DisclosureGroup` comparten el mismo lenguaje sutil: `.caption.weight(.semibold)` +
  `textSecondary`. El bloque esencial superior va sin cabecera (es lo primero, no
  necesita rótulo), dejando más aire entre bloques.
- **Asistente IA:** nunca vuelve a ocultarse en «Herramientas». Su fila usa título
  explícito, una frase de capacidad, estado y badge textual «LOCAL»; el color no es la
  única señal. `⌘8` abre el asistente desde cualquier parte.
- **Búsqueda global:** la cabecera de marca ofrece una acción compacta `⌘K` que encuentra
  enlaces, colecciones, etiquetas y secciones. Complementa el menú y el atajo; no los
  sustituye.
- **Papelera:** discreta, abajo, junto a la acción primaria «Nuevo enlace» (botón de
  cristal `.glass` con icono `trash`); navega a `.trash` sin ocupar una fila del árbol.
- **Bandeja:** es una proyección del estado compartido `ReadingStatus.inbox`, no un
  almacén paralelo. Su acción primaria abre un triaje estable por UUID, en bloques de
  hasta 25 capturas antiguas, para clasificar, etiquetar, añadir a lectura, marcar como
  leído, archivar u omitir sin perder contexto.

---

## 4. Cabecera de colección (columna central)

Cada vista de biblioteca lleva una **cabecera funcional Liquid Glass** propia —no una
segunda toolbar— que identifica la sección y mantiene a mano sus controles. Sin portada
manual es compacta y evita por completo el antiguo banner de color saturado con una fila
de favicons flotando sin jerarquía:

```text
┌──────────────────────────────────────────────────────────────────┐
│ [icono]  Diseño                                  [☰ ⊞ ▦ ≣]      │
│          140 enlaces · 12 sitios · descripción                   │
│          [favicons solapados]                 [orden][filtro][…] │
└──────────────────────────────────────────────────────────────────┘
```

- La superficie completa es cristal neutro con respaldo `surface` y un velo mínimo
  del color de la colección; el color orienta, nunca rellena medio encabezado.
- La lente se separa 10–12 pt de los laterales y 8 pt del borde superior, con radio
  continuo de 20 pt, hairline y sombra neutra. No toca los divisores de columna ni
  dibuja un marco rectangular de borde a borde.
- El icono de colección vive en una placa de cristal de 38×38; título y resumen forman
  un único grupo accesible. Los favicons son secundarios, se solapan ligeramente y se
  limitan a ocho, seguidos del total de sitios en texto.
- Si existe `coverImageData`, la portada se conserva como una franja editorial corta y
  oscurecida; la banda funcional de cristal queda separada y legible debajo.
- Selector de vista: cuatro iconos (Lista `list.bullet`, Cuadrícula `square.grid.2x2`,
  Moodboard `rectangle.3.offgrid`, Titulares `text.alignleft`) dentro de un único grupo
  de cristal. El modo activo usa velo y borde dorados de baja opacidad, no relleno sólido.
- Orden, agrupación, filtro y acciones forman un segundo grupo compacto. Búsqueda usa
  `.searchable` en la toolbar nativa. La cabecera no duplica el título de la ventana.
- Con «Reducir transparencia», toda la cabecera cae a `palette.surface` opaco, conserva
  contraste y no depende de la refracción para comunicar estructura o estado.
- La cabecera se monta como `safeAreaInset` sobre el scroll. Las filas empiezan debajo,
  pero al desplazarse continúan detrás de la lente y se perciben refractadas mediante
  `.scrollEdgeEffectStyle(.soft, for: .top)`; nunca se corta la lista con un bloque opaco.

---

## 5. Anatomía de la tarjeta de enlace (4 modos)

- **Lista** (`LinkRowView`): favicon 38 · título (semibold) · host · 2 chips de etiqueta ·
  ★ si favorito. Denso pero cómodo, filas planas para escaneo rápido. Guard `modelContext == nil`.
- **Cuadrícula** (`LinkCoverCard`, contenedor `BentoGridView`): la vista **visual y ordenada**,
  cover-forward, deliberadamente distinta de la Lista. Retícula adaptativa de columnas **anchas**
  (`GridItem(.adaptive(minimum: 300, maximum: 360))`, 2-4 columnas según ventana) con espaciado
  **generoso** (`Spacing.lg=24`) — tarjetas grandes, no miniaturas. Cada tarjeta (radio 16):
    - **portada 16:9 protagonista** (imagen OG → favicon → degradado de marca) con velo inferior,
      badge de tipo de contenido (cristal) abajo-izquierda y, al hover, acciones rápidas
      (favorito/editar/papelera) en píldora de cristal arriba-derecha;
    - **cuerpo de metadatos rico** (más que la fila de Lista, lo que justifica el modo): título a
      2 líneas (`.headline`) · **extracto** de descripción (`details` → fallback `summary`, 2 líneas,
      `textSecondary`) · fila favicon + host + ★ + **fecha relativa** de guardado (`createdAt`) ·
      chips de etiqueta (hasta 3);
    - **elevación/sombra sutil siempre presente** (más marcada al hover) + borde dorado al hover:
      las tarjetas «flotan» sobre la retícula, lo que la separa de un vistazo de la Lista plana.
  - **Tarjeta destacada**: con ≥6 enlaces, el más reciente se muestra a **ancho completo** arriba
    (portada 15:9, título `.title3`, extracto a 3 líneas, hasta 4 chips) como acento de jerarquía.
  - Conserva: guard `modelContext == nil`, skeletons, aparición escalonada (≤12), tokens.
- **Moodboard** (`MoodboardCard`): mural inmersivo, alturas variables, portada a sangre,
  título sobre degradado inferior.
- **Titulares** (`HeadlineRow`): una línea ultradensa, punto de color + título + host (estilo RSS).

Estados: skeleton (`SkeletonView`) mientras carga portada; vacío con `EmptyStateView`.

---

## 6. Panel de detalle (columna 3)

`LinkDetailView` premium: héroe de portada arriba, título, host con favicon, acciones
(Abrir original `glassProminent`, Favorito, Compartir, Editar), metadatos (tipo,
plataforma, fechas, estado de lectura), etiquetas como chips, notas, recordatorio.
Placeholder elegante cuando no hay selección.

Para **adjuntos locales** (PDF/imagen/EPUB), el héroe se sustituye por el contenido real:
`PDFView` nativo con zoom/selección o imagen ajustada sin recorte. La acción primaria es
«Exportar original…» y la ficha incluye una tarjeta de **contenido buscable** con progreso,
resultado de OCR, acceso al texto completo y reintento. PDFKit aprovecha la capa textual;
Vision solo reconoce páginas escaneadas, siempre on-device. Los textos extensos se abren
en una hoja `EditorScaffold` separada para no inflar el árbol principal de la ficha.

### Lector EPUB local

- La ficha muestra portada real cuando existe; si falta, usa un libro dorado sobrio con
  SF Symbol. El bloque comunica «EPUB · solo en este Mac» sin convertir la privacidad en
  un banner dominante y ofrece una única primaria: «Leer libro».
- El lector se presenta con `EditorScaffold`, no con `NavigationStack`: tabla de contenidos
  estrecha a la izquierda y capítulo a la derecha. El capítulo activo usa un fondo dorado
  tenue; no hay una tarjeta por capítulo ni decoración editorial falsa.
- El texto usa estilos semánticos del sistema, interlineado holgado y ancho máximo de
  lectura de 720 pt. Puede seleccionarse y ajustarse en tres tamaños; nunca ocupa todo el
  ancho de una ventana grande.
- «Anterior»/«Siguiente», `⌘[`/`⌘]` y el índice son caminos equivalentes. Al cambiar de
  capítulo se vuelve al inicio; el desplazamiento animado se desactiva con «Reducir movimiento».
- El progreso se guarda lateralmente por UUID en `ReadingProgressStore`; el modelo compartido
  no se modifica. El original permanece intacto y exportable.
- La carga superior a 300 ms muestra progreso. Errores y truncado explican qué ocurrió y
  cómo recuperar el original; el color nunca es la única señal.
- Prohibido representar capítulos con `WKWebView`, ejecutar HTML/CSS/JavaScript del EPUB o
  solicitar fuentes, imágenes o estilos remotos. La lectura deriva texto local sanitizado.

### Explorador «Conexiones»

- El mapa es **contenido**, no navegación. Debe sentirse como una constelación editorial,
  no como un diagrama técnico: un solo lienzo continuo, sin tarjeta exterior ni lista de
  relaciones duplicada. Liquid Glass queda reservado a acciones puntuales.
- Un enlace ocupa el centro y se muestran **como máximo cuatro** relaciones prioritarias.
  Las restantes se revelan desde un menú compacto en el inspector inferior. La geometría
  es determinista y se adapta al ancho estrecho sin desplazar el foco.
- Los satélites son etiquetas espaciales, no tarjetas permanentes: el fondo y el borde
  aparecen únicamente al pasar el puntero. Las aristas permanecen finas y neutras; solo
  la relación bajo el puntero usa `palette.accent`.
- El motivo de la relación se explica **una sola vez** en un inspector contextual inferior.
  Prohibido repetir todos los enlaces en una segunda lista debajo del mapa.
- La barra funcional es compacta: atrás/adelante, lente, estado «100 % local», búsqueda
  en popover y redescubrimiento al azar. Sin segunda cabecera, eslogan ni buscador a ancho
  completo que compitan con el título nativo de navegación.
- Las lentes «Todas / Por tema / Por etiquetas / Por colección / Por sitio» aplican
  divulgación progresiva al mismo ranking local; no crean índices, datos ni llamadas nuevas.
- Los nodos usan SF Symbols de plataforma y **no solicitan favicons remotos**. El mapa
  debe seguir siendo íntegro, rápido y legible sin conexión.
- No rellenar el lienzo con relaciones débiles para que parezca más denso. Si ninguna
  supera la verja semántica, mostrar un estado vacío honesto con otro punto de partida.
- Atrás/adelante conserva el camino explorado; «Sorpréndeme» habilita serendipia. Todo
  cambio de foco respeta «Reducir movimiento» y actualiza la ficha de la tercera columna.

### Asistente IA local

- La cabecera funcional comunica dos hechos sin banners: «Modelo local» y «Web para completar
  tu búsqueda» (o «Web desactivada»). Las peticiones de investigar, comparar recursos o proponer
  una aplicación autorizan esa búsqueda; el ajuste permite revocarla. El color no es la única señal y la web nunca se presenta
  como parte implícita del funcionamiento local.
- La respuesta no se representa como un bloque Markdown monótono. Su anatomía es estable:
  conclusión directa primero, encabezados breves con marcador dorado, párrafos legibles,
  listas con una idea por línea y siguiente paso solo cuando aporta valor. Un parser local
  tolerante recompone esta jerarquía aunque el modelo omita parte del formato; nunca interpreta
  HTML, enlaces Markdown, `file://` ni deep links generados.
- El razonamiento interno del modelo no se muestra ni se persiste. La actividad sí se
  explica con chips sobrios de SF Symbols («Buscando en tu biblioteca», «Verificando la
  fuente»), sin emojis decorativos ni exposición de la cadena de pensamiento.
- Las operaciones masivas, fusiones y borrados presentan una tarjeta de confirmación
  determinista con alcance y reversibilidad. La tarjeta es contenido (palette.surface);
  solo sus botones son cristal funcional. Una petición nueva invalida la confirmación
  anterior.
- Los resultados web se muestran como tarjetas con título y host obtenidos de la búsqueda.
  Usan el SF Symbol globe: prohibido solicitar favicons a Google u otros terceros. No se
  descarga metadata adicional hasta que una acción explícita del usuario lo requiera.
- Los resultados de biblioteca y web comparten un deck verificable, pero mantienen una etiqueta
  de procedencia inequívoca. Solo el resultado exacto de una herramienta puede crear una tarjeta;
  una URL escrita libremente por el modelo permanece texto inerte. Se muestran cinco tarjetas
  como máximo y el resto queda tras «Mostrar más» para conservar calma visual.
- Cada tarjeta ofrece acciones próximas al objeto: previsualizar en el panel derecho, abrir,
  preguntar por ese enlace y, solo para resultados web, agregar uno o el lote. La vista rápida
  despliega resumen, colección y hasta tres etiquetas sin salir de la conversación. El alta en
  lote usa el embudo único, comunica añadidos/duplicados y nunca oculta un fallo.
- Tras una respuesta completa aparecen acciones secundarias discretas: copiar, regenerar y un
  menú «Continuar» para ampliar, resumir o comparar. No se muestran chips de sugerencia en cada
  mensaje ni varias llamadas primarias compitiendo entre sí.
- El campo de entrada recupera el foco tras enviar. El streaming sigue la respuesta sin
  animar cada token; inserciones y desplazamientos animados respetan «Reducir movimiento».
- El chat conserva una extensión de documento estable: la verificación FIX3 ensaya
  ScrollView + VStack completo después de observar que List contraía una respuesta alta
  y recortaba el desplazamiento. Es una excepción a la prescripción anterior de LazyVStack,
  condicionada a comprobar coste y fluidez con historiales largos, sesión viva y streaming
  antes de aprobar la release; el parseo o build no cumplen ese gate. Historial, memoria
  semántica y resultados tienen límites explícitos. Los errores explican qué falló y mantienen una acción de
  recuperación visible, sin afirmar que una herramienta se ejecutó si no lo hizo.

---

## 7. Qué se ELIMINA en este rediseño

- `BentoBoardView` y el concepto de panel/dashboard de widgets en el inicio.
- Stickers: `StickerLayerView`, `StickerPickerView`, `StickerCatalog` (UI; el modelo
  `PlacedSticker` queda en el core sin usar en Mac).
- Widgets de biblioteca del bento (favoritos/recientes/cola/nota/nube) — su contenido ya
  vive como secciones/modos propios.
- El modo «Resumen»/`HomeMode` (ya eliminado) y `HomeView` como dashboard.

Los **feeds de descubrir** (GitHub trending, Hacker News, dev.to, Steam, juegos gratis,
ofertas App Store…) NO se eliminan: se reubican en la sección **«Descubrir»**.

---

## 8. Liquid Glass premium (macOS 26 · estado del arte junio 2026)

Regla de oro de Apple (HIG): **el cristal vive en la CAPA FUNCIONAL** — controles,
navegación, barras, sidebars y overlays transitorios — **NUNCA en la capa de
contenido**, que usa materiales estándar o `palette.surface`. Si la app se rompe con
«Reducir transparencia» activado, no es Liquid Glass, es decoración.

Reglas de implementación:
- Aplicar `.glassEffect()` **al final** (después de layout/padding/frame).
- **El cristal no puede muestrear otro cristal.** Agrupar elementos de cristal cercanos
  en un `GlassEffectContainer(spacing:)` para que se fundan y rindan bien. NUNCA anidar
  contenedores.
- Morphing con `glassEffectID(_:in:)` + `@Namespace` cuando un elemento de cristal se
  transforma en otro (p.ej. el «pill» del selector de vista).
- Botones: usar la primitiva canónica `stacklumeButton`. El cristal es neutro; una
  acción primaria solo añade un velo y borde `accent` de baja opacidad. Se evita
  `.glassProminent` tintado como relleno porque aplana la refracción y satura la UI.
- **Bordes de scroll**: usar `.scrollEdgeEffectStyle(.soft, for: .top)` en los `ScrollView`/
  `List` para que el contenido se difumine premium bajo cabeceras flotantes. Las
  cabeceras pinchadas (`safeAreaInset`) son lentes redondeadas e inset: preservan la
  legibilidad del contenido propio, pero dejan que el contenido desplazado se intuya y
  refracte por debajo en vez de imponer un corte rectangular.
- Mesura: cristal en titlebar unificada, sidebar funcional, cabeceras, barras de acción,
  selector de vista, paleta ⌘K, tooltips y HUD. NO cristal en filas de lista, tarjetas
  de contenido ni portadas (eso es contenido → material/surface).

### Ayuda contextual

- `.themedHelp` dibuja un tooltip Liquid Glass propio, flotante y compacto, con cristal
  neutro, hairline de contraste, sombra negra y transición breve de escala + opacidad.
- Su ancho es intrínseco al texto más 20–22 pt de relleno total; solo crece hasta 300 pt
  cuando necesita envolver. Máximo tres líneas, texto centrado y nunca tapa el control.
- Siempre conserva `accessibilityHint`; con «Reducir movimiento» no escala y con
  «Reducir transparencia» utiliza una superficie opaca. El tooltip jamás roba eventos.

### Superficies de cristal (capa funcional)
Titlebar unificada, cabecera de marca y fondo funcional del sidebar, barra «Nuevo enlace»
+ Papelera, cabecera de colección, barra de acciones en lote, paleta ⌘K, tooltips,
barra de acciones del detalle y HUD de progreso.

### Captura por arrastrar y soltar

- Toda la ventana acepta enlaces web, ubicaciones `.webloc`/`.url`, PDF, EPUB e imágenes.
- Mientras el cursor arrastra contenido compatible, un velo navy cubre el contenido y
  un único panel de cristal centrado explica con texto e icono qué se puede soltar.
- Tras soltar, un HUD de cristal en la parte inferior muestra progreso y resultado sin
  robar el foco. El resultado también se anuncia a VoiceOver; el color nunca es la única
  señal de éxito o error.
- La aparición es un fundido breve (0,16 s) y se desactiva con «Reducir movimiento».
- No se muestran nombres de cientos de archivos ni menús dinámicos: el mensaje resume
  altas, duplicados y rechazos para conservar calma visual y rendimiento.

---

## 9. Fondo y profundidad (premium navy + dorado)

`WindowBackground`: navy profundo (`background`) con una variación vertical uniforme
apenas perceptible (`surface` muy tenue arriba → `background` abajo), suficiente para
que el cristal refracte y gane profundidad. NO hay halos radiales, manchas doradas ni
degradados de marca saturados. El dorado vive en estados, bordes y velos funcionales;
las barras de scroll doradas (`ScrollerTint`) se mantienen.

Placeholders de portada (sin imagen): superficie oscura + glow radial **sutil** del
color de marca (un susurro) + glifo de plataforma apagado. **Prohibido** el degradado
diagonal saturado `[brand, surface]` (abarataba la estética).

## 10. Selección y resaltados (sutiles y separados)

- El dorado de los resaltados se usa con **baja opacidad** y **separación/inset**: el
  «pill» del selector de vista a `accent.opacity(0.12)` con iconos separados; la fila
  activa del sidebar con realce inset sutil (no un bloque dorado sólido).
- Estados vacíos (`EmptyStateView`): icono dorado jerárquico en un círculo de navy
  profundo con **anillo dorado fino y nítido** (gradiente vertical) y sombra **neutra**;
  **nunca** halo dorado difuso ni cristal tintado de oro.

## 11. Investigación y catálogos de modelos

Design Read: espacios de consulta para personas que construyen su biblioteca, con el lenguaje
nativo y la paleta de Stacklume. ENERGY 1 / RHYTHM 2 / MOTION 1: lectura tranquila, jerarquía
distinta entre filtros, resultados y ficha, y movimiento limitado a estados de interacción.

- «Explorar» incorpora destinos Hugging Face y Civitai, como pide el usuario. El símbolo `cpu`
  representa repositorios de modelos; `photo.on.rectangle.angled` representa el catálogo visual.
  Se conserva la tipografía semántica de macOS para leer identificadores extensos sin otra fuente.
- Los catálogos usan el ancho del espacio central y un inspector propio. La ficha vacía de la
  biblioteca se repliega, igual que en X: ese espacio se necesita para filtros y resultados.
  Al volver a una colección reaparecen sus tres columnas y mínimos habituales.
- Una única cabecera funcional reúne búsqueda, filtros y conexión. Los resultados y detalles son
  contenido en `palette.surface`, sin cristal. La imagen real ayuda a reconocer un modelo visual;
  un repositorio sin portada se presenta por su nombre, tarea y autor, sin inventar una imagen.
- Los filtros se adaptan y se repliegan en tamaños estrechos. Las listas son perezosas y paginadas;
  no se cargan miles de modelos ni todas sus imágenes al abrir una sección. Los estados de carga,
  vacío, acceso denegado y límite de peticiones explican la causa y permiten recuperar la búsqueda.
  Si los filtros desplegados ocupan una columna estrecha o corta, la cabecera tiene scroll propio
  y reserva el 60 % del alto para resultados y pie. Así se alcanza el último filtro sin ocultar
  permanentemente el contenido ni reducir todos los controles para que quepan.
- Los filtros y la conexión usan `EditorScaffold` y `.themedSheet` también en su cuerpo: secciones
  sólidas con `palette.surface`, fondo de la paleta y controles del editor existente. El fondo gris
  de `Form(.grouped)` del sistema no sustituye el tema de Stacklume.
- Los campos conservan una etiqueta visible después de escribir y una superficie navy. Los
  selectores mantienen el menú nativo con el mismo marco de paleta. El foco usa un único borde
  del acento activo; no añade un anillo dorado del sistema cuando el usuario eligió otro acento.
  La deshabilitación se distingue sin simular foco ni perder la selección mostrada.
- Lista y cuadrícula son dos lecturas de los mismos resultados. La lista compara identidad y
  procedencia; la cuadrícula reconoce muestras reales con tamaño ajustable. Cada resultado muestra
  tipo, modelo base y versión recibidos del proveedor. Si sus versiones usan bases distintas, se
  indica esa diversidad; no se deduce la familia del nombre ni se inventa una portada.
  En cuadrícula, título, tipo y base preceden a la imagen para reconocer el recurso al entrar,
  incluso con previews grandes en una columna estrecha. Autor, versiones y estadísticas siguen
  después de la imagen; la lista conserva su orden y densidad de comparación.
- Los filtros rápidos de tipo, familia, contenido adulto, origen y orden modifican los filtros
  existentes y conservan un estado activo visible. La carga de 30, 60 o 100 resultados por petición
  y «Cargar más» secuencial tiene deduplicación y un máximo de 300 modelos retenidos. El límite se
  comunica y permite continuar por páginas; las imágenes siguen cargándose bajo demanda.
- El visor mantiene separado el encuadre de la información. «Información» abre o cierra sus datos
  sin modificar el porcentaje de zoom ni sustituir la imagen. La imagen ampliada se explora en un
  lienzo nativo con desplazamiento en ambos ejes, arrastre y magnificación de trackpad; ajustar,
  tamaño real y zoom son acciones explícitas. La información conserva sus metadatos, procedencia,
  parámetros y acciones sin provocar otra descarga al abrirse.
- Las claves se introducen con controles seguros. El estado de conexión identifica el proveedor
  y nunca revela el token. La consulta pública sigue disponible sin clave. NSFW es una elección
  explícita de Civitai, con indicación textual y aplicación a modelos y previsualizaciones.
- Guardar un modelo permite elegir organización propia y reutiliza el alta de enlaces. Las
  versiones se distinguen mediante la URL del proveedor; favoritos, lectura y colecciones siguen
  siendo los controles de la biblioteca, sin almacén paralelo de marcadores.
  «Organizar/Guardar» conserva el mismo editor y agrupa selección y organización en superficies
  de paleta. Los campos de nuevas colecciones y etiquetas reutilizan etiquetas persistentes,
  fondo navy y foco del acento activo; el estado de lectura mantiene un menú nativo tematizado.
  El cuerpo se desplaza dentro de la hoja para que las acciones de guardar y cancelar sigan visibles.
- El editor de X separa enfoque, tono y hashtags. Las variantes se comparan por su texto real,
  no por supuestas puntuaciones de viralidad. La selección conserva una versión editable y
  respeta el contador ponderado. El acento señala la elección activa y la acción de abrir en X.
- El chat muestra el avance de la investigación antes de cargar el LLM. El deck distingue fuentes
  guardadas y web; la respuesta vincula decisiones con esas fuentes y hace explícitos los huecos.
  Las continuaciones conservan la intención anterior sin enviar contenido de la biblioteca a la web.

### Espacio del asistente

La sección Asistente IA ocupa el espacio ampliado de trabajo como los catálogos: sus fuentes y acciones se presentan en el propio chat, por lo que no reserva una columna vacía de detalle de enlaces. Al regresar a la biblioteca se restaura su disposición de tres columnas. Los mensajes conservan sus límites de anchura y el historial nativo se ajusta al espacio disponible.

«Previsualizar» abre la ficha existente de Descubrir en una hoja tematizada con un cierre explícito. La hoja permite consultar la portada, los metadatos y las acciones de esa fuente sin reducir permanentemente el espacio del asistente ni cambiar la selección de la biblioteca.
