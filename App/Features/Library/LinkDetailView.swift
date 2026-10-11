import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import StacklumeCore
import StacklumeDesignSystem
import StacklumeMetadata
import StacklumePersistence

/// Columna de detalle: ficha premium del enlace seleccionado, al nivel de
/// raindrop.io con piel Stacklume (oscuro + dorado). Héroe de portada, título,
/// host con favicon, barra de acciones de cristal, metadatos en tarjeta,
/// etiquetas, notas y recordatorio.
struct LinkDetailView: View {
    let link: Bookmark
    @Environment(\.themePalette) private var palette
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var context
    @Environment(LibraryActions.self) private var actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Buzón para preguntar al asistente sobre este enlace (lleva al chat con la pregunta).
    @Environment(AssistantInbox.self) private var assistantInbox: AssistantInbox?

    @State private var isEnriching = false
    @State private var inAppURL: IdentifiableURL?
    @State private var savingOffline = false
    @State private var showOfflineReader = false
    @State private var showDocumentText = false
    @State private var extractingDocumentText = false
    @State private var documentTextMessage: String?
    @State private var highlightEditor: HighlightEditorView.Mode?
    /// Estado del botón «Mejorar con IA» del enlace (spinner mientras enriquece).
    @State private var improvingAI = false
    /// Estado del botón «Extraer puntos clave con IA» (spinner mientras analiza).
    @State private var extractingHighlights = false
    /// Lanzador de IA local (Liquid), observado para habilitar/ocultar el botón de IA.
    @State private var aiRunner = LocalAIRunner.shared
    /// Enlaces semánticamente relacionados (descubrimiento dentro de tu biblioteca).
    @State private var relatedLinks: [RelatedLinkInfo] = []
    /// Tiempo de lectura estimado (min) del artículo, calculado al abrir la ficha.
    @State private var readingMinutes: Int?
    /// Controlador de lectura en voz alta (TTS), observado para el estado del botón.
    @State private var aloud = ReadAloud.shared
    /// Popover de compartir (WhatsApp/Telegram/Más opciones/Copiar).
    @State private var showShareMenu = false
    @State private var showXComposer = false
    /// El texto legible del artículo (copia offline o descargado), para leer en voz alta.
    @State private var articleText: String?
    /// Feeds personalizados del usuario (compartido con Descubrir). Permite «Seguir
    /// lanzamientos» de un repo de GitHub o «Seguir versiones» de un paquete añadiendo
    /// su feed RSS/Atom de versiones.
    @AppStorage(CustomFeedStore.storageKey) private var customFeedsJSON = ""
    /// Estado del botón «Seguir versiones del paquete» (la resolución del feed es
    /// asíncrona para npm/cargo/gem: consulta el registro para hallar el repo de origen).
    @State private var versionsState: VersionsFollowState = .idle
    /// Proporción REAL de la portada del héroe (ancho/alto), para que la caja del héroe
    /// adopte la forma de la imagen y esta la LLENE (sin fondo desenfocado flotante).
    @State private var heroAspect: CGFloat?
    /// Portadas personalizadas (HD del usuario): prioridad sobre la `imageURL` autodetectada.
    @State private var coverStore = CustomCoverStore.shared
    /// Diálogo de error si la imagen elegida/pegada no es válida.
    @State private var coverError = false
    /// Spinner mientras se busca automáticamente la imagen principal de la página.
    @State private var fetchingImage = false
    /// Spinner mientras se archiva la página en la Wayback Machine; y si ya está archivada.
    @State private var archivingWayback = false
    @State private var waybackArchived = false
    /// Para vídeos (YouTube/Vimeo): `true` tras pulsar «reproducir» → embebe el reproductor en
    /// lugar de la miniatura (no se contacta al servicio de vídeo hasta entonces).
    @State private var showingVideoPlayer = false
    /// Posición del reproductor inline, para reanudar al sacarlo a ventana (PiP / pantalla completa).
    @State private var playbackState = VideoPlaybackState()
    /// URLs de vídeo cuya incrustación falló (el autor la desactivó, etc.): no se ofrece el botón
    /// de play (se muestra la miniatura normal) para no repetir el error de YouTube.
    @State private var failedVideoURLs: Set<String> = []
    /// Aviso cuando la página no expone ninguna imagen de portada (se mantiene el logo).
    @State private var imageFetchFailed = false
    /// Confirmación para descargar el modelo de IA (≈8,4 GB) al pulsar «Mejorar con IA»
    /// sin tenerlo instalado todavía.
    @State private var showAIDownloadPrompt = false
    /// Galería para elegir la portada entre varias imágenes de la web (ver [[CoverPickerSheet]]).
    @State private var showCoverPicker = false
    /// Hoja para dibujar anotaciones sobre la página (ver [[PageAnnotationView]]).
    @State private var showAnnotation = false

    enum VersionsFollowState: Equatable { case idle, resolving, added, notFound }

    private var host: String {
        if link.fileKind == "pdf" { return "Documento PDF · local" }
        if link.fileKind == "image" { return "Imagen · local" }
        if link.fileKind == "epub" { return "Libro EPUB · local" }
        return URL(string: link.url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? link.url
    }

    private var brand: Color { Color(hex: link.platformColor ?? link.platform.brandColorHex) }

    /// URL válida del enlace (sin force unwrap). Si es `nil`, el enlace es local
    /// o malformado y se ocultan las acciones que dependen de abrirlo.
    private var linkURL: URL? { StacklumeAutomationPolicy.openableStoredURL(link.url) }

    private static let savedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        // Guarda anti-crash: al «Restablecer» o borrar enlaces, el seleccionado puede quedar
        // INVALIDADO por SwiftData (su `modelContext` pasa a nil) ANTES de que el @Query que
        // elige la ficha deje de seleccionarlo. Pintar entonces sus propiedades (p. ej.
        // `link.platform` en la portada, LinkDetailView.swift:348) dispara un assertionFailure
        // de SwiftData (EXC_BREAKPOINT/SIGTRAP). Mismo patrón que LinkRowView/LinkCoverCard.
        if link.modelContext == nil {
            DetailPlaceholderView()
        } else {
            detailContent
        }
    }

    private var detailContent: some View {
        detailPresentation
    }

    private var detailScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                heroSection
                titleBlock
                commandSection
                repoStatsSection
                followReleasesSection
                followPackageVersionsSection
                actionBar
                readAloudBar
                summarySection
                descriptionSection
                documentTextSection
                metadataCard
                tagsSection
                notesSection
                highlightsSection
                offlineSection
                relatedSection
                Spacer(minLength: 0)
            }
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WindowBackground())
        .navigationTitle(link.title.isEmpty ? "Enlace" : link.title)
    }

    private var detailLifecycle: some View {
        detailScroll
        .task(id: link.id) { await loadRelated() }
        // Prepara el texto legible del artículo (copia offline o descargado) para el tiempo
        // de lectura estimado y la lectura en voz alta.
        .task(id: link.id) { await loadArticleText() }
        // Los adjuntos antiguos se indexan al abrirlos. El coordinador evita duplicados y
        // ejecuta PDFKit/Vision o el lector EPUB fuera del MainActor; no usa red ni IA.
        .task(id: link.id) { await indexDocumentIfNeeded() }
        // ¿Esta página ya se archivó en la Wayback Machine? (estado del botón de la barra).
        .task(id: link.id) {
            guard link.modelContext != nil else { return }   // anti-crash: enlace borrado
            waybackArchived = WaybackStore.isArchived(link.url)
        }
        // Al cambiar de enlace, detén la lectura en voz alta del anterior y reinicia el
        // estado del botón «Seguir versiones» (no debe arrastrarse al siguiente paquete).
        .onChange(of: link.id) { _, _ in
            if aloud.isActive { aloud.stop() }
            versionsState = .idle
            showingVideoPlayer = false   // el reproductor de vídeo no se arrastra al siguiente enlace
            documentTextMessage = nil
        }
        // Al abrir la ficha se marca como leído (igual que el iPhone). Se espera un instante
        // ANTES de marcar+guardar: así marcar leído (que dispara un re-render de lista/sidebar)
        // NO entra en el camino del clic —que se sentía lento— y, además, solo se marca si de
        // verdad te quedas en el enlace (si pasas de uno a otro rápido, la tarea se cancela).
        .task(id: link.id) {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, link.modelContext != nil, !link.isRead else { return }
            link.isRead = true
            context.saveLogging()
        }
    }

    private var detailPresentation: some View {
        detailLifecycle
        .sheet(isPresented: $showXComposer) {
            XPostComposerView(link: link).themedSheet(palette)
        }
        .sheet(item: $inAppURL) { item in
            InAppBrowserSheet(url: item.url, offlineHTML: item.offlineHTML, bookmark: link).themedSheet(palette)
        }
        .sheet(isPresented: $showOfflineReader) {
            if let html = link.offlineHTML {
                OfflineReaderView(
                    title: link.title.isEmpty ? "Copia sin conexión" : link.title,
                    html: html,
                    bookmark: link
                )
                .themedSheet(palette)
            }
        }
        .sheet(isPresented: $showDocumentText) {
            if let text = link.offlineText, !text.isEmpty {
                DocumentTextSheet(
                    title: link.title.isEmpty ? "Texto reconocido" : link.title,
                    text: text,
                    onClose: { showDocumentText = false }
                )
                .themedSheet(palette)
            }
        }
        .sheet(item: $highlightEditor) { mode in
            HighlightEditorView(mode: mode).themedSheet(palette)
        }
        .toolbar {
            ToolbarItemGroup {
                if link.fileKind == nil {
                    Button("Actualizar metadatos", systemImage: "arrow.clockwise") {
                        guard !isEnriching else { return }
                        isEnriching = true
                        Task {
                            await MacLinkEnricher.enrichFromNetwork(link, in: context, overwriteTitle: false)
                            isEnriching = false
                        }
                    }
                    .disabled(isEnriching)
                    .themedHelp(isEnriching ? "Actualizando metadatos…" : "Actualizar metadatos del enlace")
                }
                // Repaso (resurfacing «segundo cerebro»): programa cuándo debe reaparecer en
                // «Para repasar» de Estadísticas. Es el mismo `reviewAt` que el menú contextual.
                Menu {
                    Button("En 3 días") { scheduleReview(days: 3) }
                    Button("En 1 semana") { scheduleReview(days: 7) }
                    Button("En 2 semanas") { scheduleReview(days: 14) }
                    Button("En 1 mes") { scheduleReview(days: 30) }
                    if link.reviewAt != nil {
                        Divider()
                        Button("Quitar repaso", role: .destructive) {
                            BookmarkActions.setReviewDate(nil, for: link, in: context)
                        }
                    }
                } label: {
                    Label("Repasar más tarde", systemImage: link.reviewAt != nil
                          ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath")
                }
                .themedHelp("Programar un repaso de este enlace")
                Button("Mover a la papelera", systemImage: "trash", role: .destructive) {
                    BookmarkActions.moveToTrash(link, in: context)
                }
                .themedHelp("Mover este enlace a la papelera")
            }
        }
    }

    /// Programa el repaso de este enlace para dentro de `days` días.
    private func scheduleReview(days: Int) {
        let date = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        BookmarkActions.setReviewDate(date, for: link, in: context)
    }

    // MARK: - Héroe de portada / reproductor de vídeo

    /// URL del reproductor embebido si el enlace es un vídeo embebible reconocido (YouTube, Vimeo,
    /// Twitch, Dailymotion, Loom); `nil` en otro caso. Basta con que la URL sea de una plataforma
    /// conocida —no exige `contentType == .video`— para cubrir también enlaces mal clasificados.
    private var videoEmbedURL: URL? {
        VideoEmbed.embedURL(for: link.url)
    }

    /// Cabecera de la ficha: para vídeos embebibles, la miniatura con un botón de PLAY que, al
    /// pulsarlo, embebe el reproductor (no se contacta a YouTube/Vimeo hasta entonces). Para el
    /// resto, el héroe de portada de siempre. Los adjuntos usan su visor nativo, sin fingir
    /// que una imagen genérica o un favicon son el contenido del documento.
    @ViewBuilder private var heroSection: some View {
        if let data = link.fileData, let kind = link.fileKind {
            LocalDocumentPreview(id: link.id, data: data, kind: kind)
        } else if let embed = videoEmbedURL, !failedVideoURLs.contains(link.url) {
            // Solo se ofrece el reproductor si es un vídeo embebible y NO falló su incrustación.
            if showingVideoPlayer {
                VStack(spacing: 0) {
                    VideoEmbedView(url: embed, state: playbackState,
                                   startAt: VideoProgressStore.progress(for: link.url),
                                   progressKey: link.url,
                                   onError: { handleVideoEmbedError() })
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 380)
                    videoControlsBar(embed)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.28), radius: 14, y: 8)
                .id(link.id)
            } else {
                Button { showingVideoPlayer = true } label: {
                    hero
                        .overlay { videoPlayOverlay }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reproducir el vídeo")
            }
        } else {
            hero
        }
    }

    /// El reproductor inline reportó un error (incrustación desactivada por el autor, etc.): recuerda
    /// este enlace como no-embebible y vuelve a la miniatura (el usuario lo abre con «Abrir original»).
    private func handleVideoEmbedError() {
        failedVideoURLs.insert(link.url)
        showingVideoPlayer = false
    }

    /// Botón de play centrado sobre la miniatura del vídeo (no intercepta el toque: el gesto vive
    /// en el contenedor para que pulsar en cualquier punto reproduzca).
    private var videoPlayOverlay: some View {
        ZStack {
            Color.black.opacity(0.28)
            Image(systemName: "play.circle.fill")
                .scaledFont(58, weight: .semibold, scalesWithText: false)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.45))
                .shadow(color: .black.opacity(0.4), radius: 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .allowsHitTesting(false)
    }

    /// Barra DEBAJO del reproductor: indicador «Sin anuncios» + botones de IMAGEN SOBRE IMAGEN
    /// (PiP) y PANTALLA COMPLETA. Sacan el vídeo a una VENTANA de macOS nativa (reanudando donde
    /// estaba): flotante pequeña = PiP siempre-encima; con el botón verde = pantalla completa REAL.
    /// Son botones de SwiftUI (clics fiables) y abren una ventana de AppKit, sin depender de las
    /// APIs de PiP/fullscreen del WebView (restringidas para el YouTube embebido).
    private func videoControlsBar(_ embed: URL) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(palette.accent)
            Text("Sin anuncios")
                .stacklumeFont(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))

            Spacer()

            Button { popOutVideo(embed, floating: true, fullscreen: false) } label: {
                Image(systemName: "pip.enter")
            }
            .themedHelp("Imagen sobre imagen (ventana flotante)")
            .accessibilityLabel("Imagen sobre imagen")

            Button { popOutVideo(embed, floating: false, fullscreen: true) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .themedHelp("Pantalla completa")
            .accessibilityLabel("Pantalla completa")
        }
        .buttonStyle(.plain)
        .scaledFont(14, weight: .semibold)
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(.black)
    }

    /// Saca el vídeo a una ventana nativa (PiP flotante o pantalla completa real), reanudando
    /// donde estaba, y devuelve el reproductor inline a su miniatura (solo suena la ventana).
    private func popOutVideo(_ embed: URL, floating: Bool, fullscreen: Bool) {
        // Reanuda donde iba: el tiempo en vivo del reproductor inline o, si aún no reportó, el
        // progreso guardado de «continuar viendo».
        let resumeAt = max(playbackState.currentTime, VideoProgressStore.progress(for: link.url))
        VideoWindowController.shared.open(embedURL: embed, startAt: resumeAt,
                                          floating: floating, fullscreen: fullscreen,
                                          title: link.title.isEmpty ? "Reproductor" : link.title)
        showingVideoPlayer = false
    }

    /// Héroe de portada: la caja adopta la PROPORCIÓN REAL de la imagen (resuelta de
    /// `ImageCache`) con un alto máximo, y la imagen la LLENA a sangre (`scaledToFill`,
    /// alta interpolación). Así una portada VERTICAL ocupa una caja vertical centrada y
    /// la llena entera —sin el fondo desenfocado que la dejaba «flotando»—. Skeleton
    /// mientras carga; si no hay imagen, placeholder de marca. Badge de tipo abajo-izq.
    private var hero: some View {
        Color.clear
            .aspectRatio(min(2.2, max(0.55, heroAspect ?? 1.6)), contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 380)
            .overlay {
                if let custom = coverStore.image(for: link.id) {
                    // Portada personalizada (prioridad): llena la caja a sangre.
                    Image(platformImage: custom).resizable().interpolation(.high).scaledToFill()
                } else {
                    // La imagen LLENA la caja (que ya tiene su proporción → no recorta).
                    // Sin og:image: NO se estira el favicon (quedaba muy borroso a 380 px) —
                    // se muestra el LOGO del sitio CENTRADO y nítido sobre el degradado de
                    // marca, como Raindrop con los enlaces sin imagen.
                    SecureRemoteImage(candidates: HDImage.candidates(link.imageURL), maxPixels: 2_048,
                                skeleton: { SkeletonView() }) {
                        ZStack {
                            palette.surface
                            RadialGradient(colors: [brand.opacity(0.18), .clear],
                                           center: .center, startRadius: 4, endRadius: 240)
                            VStack(spacing: DesignSystem.Spacing.md) {
                                SecureRemoteImage(candidates: [link.faviconURL] + PreviewImage.favicon(for: link.url, size: 256).map { Optional($0) }) {
                                    Image(systemName: link.platform.sfSymbol)
                                        .scaledFont(40, weight: .semibold, scalesWithText: false)
                                        .foregroundStyle(brand.opacity(0.55))
                                }
                                .frame(width: 96, height: 96)
                                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                                // Sin og:image: ofrece BUSCAR la imagen principal de la web
                                // (web fetch + heurística). No necesita el modelo de IA.
                                if fetchingImage {
                                    ProgressView().controlSize(.small)
                                } else if linkURL != nil {
                                    Button { fetchImageAutomatically() } label: {
                                        Label("Obtener imagen", systemImage: "sparkles")
                                            .stacklumeFont(.caption.weight(.semibold))
                                    }
                                    .stacklumeButton(prominent: false, compact: true)
                                    .themedHelp("Buscar y descargar la imagen principal de la página")
                                    .accessibilityLabel("Obtener la imagen principal de la página")
                                }
                            }
                        }
                    }
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            )
            .overlay(alignment: .bottomLeading) {
                ContentTypeBadge(type: link.contentType)
                    .padding(DesignSystem.Spacing.sm)
            }
            .overlay(alignment: .topTrailing) { coverEditMenu }
            .shadow(color: .black.opacity(0.28), radius: 14, y: 8)
            // Resuelve la proporción al cambiar de enlace O de portada personalizada.
            .task(id: "\(link.id)|\(coverStore.currentVersion(for: link.id))") { await resolveHeroAspect() }
            // Identidad ligada al enlace: al seleccionar otro se reconstruye con estado fresco.
            .id(link.id)
            .alert("No se pudo usar la imagen", isPresented: $coverError) {
                Button("Aceptar", role: .cancel) {}
            } message: {
                Text("Elige o pega una imagen válida (PNG, JPEG…).")
            }
            .alert("No se pudo recuperar la portada", isPresented: $imageFetchFailed) {
                Button("Aceptar", role: .cancel) {}
            } message: {
                Text("No se ha podido obtener una imagen válida del origen. Se conserva la referencia guardada; puedes volver a intentarlo o elegir una imagen manualmente.")
            }
            // «Mejorar con IA» sin el modelo instalado: avisa del tamaño antes de descargar y
            // ofrece una vía sin IA (solo metadatos, que también obtiene la imagen).
            .confirmationDialog("Mejorar con IA", isPresented: $showAIDownloadPrompt, titleVisibility: .visible) {
                Button("Descargar IA y mejorar (≈8,4 GB)") { runEnrich(useAI: true) }
                Button("Solo actualizar metadatos") { runEnrich(useAI: false) }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("La mejora con IA usa el modelo local (LFM2.5, ~8,4 GB), 100 % en tu Mac. También puedes actualizar solo los metadatos —título, descripción e imagen— sin descargar nada.")
            }
            .sheet(isPresented: $showCoverPicker) {
                CoverPickerSheet(link: link) {
                    Task { await resolveHeroAspect() }
                    WidgetReloader.reload()
                }
                .themedSheet(palette)
            }
            .sheet(isPresented: $showAnnotation) {
                PageAnnotationView(link: link) {
                    Task { await resolveHeroAspect() }
                    WidgetReloader.reload()
                }
                .themedSheet(palette)
            }
    }

    /// Menú para fijar una portada PROPIA (HD) al enlace: elegir archivo, pegar del
    /// portapapeles o quitar la personalizada. Supera a Raindrop (portadas solo en Pro) y
    /// resuelve para siempre las portadas de baja resolución del origen.
    private var coverEditMenu: some View {
        Menu {
            Button("Obtener imagen automáticamente", systemImage: "sparkles") { fetchImageAutomatically() }
                .disabled(fetchingImage || linkURL == nil)
            Button("Elegir entre las de la web…", systemImage: "photo.stack") { showCoverPicker = true }
                .disabled(linkURL == nil)
            Button("Anotar la página…", systemImage: "pencil.tip.crop.circle") { showAnnotation = true }
                .disabled(linkURL == nil)
            Divider()
            Button("Elegir imagen…", systemImage: "photo") { pickCoverFile() }
            Button("Pegar imagen", systemImage: "doc.on.clipboard") { pasteCover() }
            if coverStore.has(link.id) {
                Divider()
                Button("Quitar portada personalizada", systemImage: "arrow.uturn.backward", role: .destructive) {
                    coverStore.remove(for: link.id)
                    Task { await resolveHeroAspect() }
                    WidgetReloader.reload()
                }
            }
        } label: {
            Image(systemName: "photo.badge.plus")
                .scaledFont(12, weight: .semibold, scalesWithText: false)
                .foregroundStyle(.white)
                .padding(7)
                .background(.black.opacity(0.45), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(DesignSystem.Spacing.sm)
        .themedHelp("Cambiar la portada")
        .accessibilityLabel("Cambiar la portada")
    }

    /// Lee la proporción real de la portada (personalizada, caché o descarga) para que la
    /// caja del héroe adopte su forma y la imagen la llene sin recortes ni fondo flotante.
    @MainActor
    private func resolveHeroAspect() async {
        if let custom = coverStore.image(for: link.id), custom.size.height > 0 {
            heroAspect = custom.size.width / custom.size.height; return
        }
        heroAspect = nil
        // Solo la og:image fija la proporción del héroe; sin ella se queda en el
        // valor por defecto (1.6, héroe ancho) con el logo centrado encima —el
        // favicon NO debe imponer una caja cuadrada.
        let urls = HDImage.candidates(link.imageURL).compactMap { $0 }
        for candidate in urls {
            guard let url = URL(string: candidate) else { continue }
            if let img = SecureImageCache.shared.cached(for: url), img.size.height > 0 {
                heroAspect = img.size.width / img.size.height; return
            }
            if let img = await SecureImageCache.shared.image(for: url), img.size.height > 0 {
                heroAspect = img.size.width / img.size.height; return
            }
        }
    }

    /// Abre un panel para elegir una imagen del disco y fijarla como portada.
    @MainActor
    private func pickCoverFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Usar como portada"
        guard panel.runModal() == .OK, let url = panel.url,
              let image = NSImage(contentsOf: url) else { return }
        applyCustomCover(image)
    }

    /// Fija como portada la imagen del portapapeles (si la hay).
    @MainActor
    private func pasteCover() {
        guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage else {
            coverError = true; return
        }
        applyCustomCover(image)
    }

    /// Guarda la portada personalizada y refresca la proporción del héroe y el widget.
    @MainActor
    private func applyCustomCover(_ image: NSImage) {
        guard coverStore.set(image, for: link.id) else { coverError = true; return }
        Task { await resolveHeroAspect() }
        WidgetReloader.reload()
    }

    // MARK: - Título + host con favicon

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text(link.title.isEmpty ? host : link.title)
                .stacklumeFont(.title2.weight(.bold))
                .foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                PlatformBadge(platform: link.platform, size: 18)
                Text(host)
                    .stacklumeFont(.callout)
                    .foregroundStyle(palette.textSecondary)
                    .stacklumeLineLimit(1)
                if link.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(palette.accent)
                }
            }
        }
    }

    // MARK: - Estadísticas de repositorio GitHub

    /// Muestra `RepoStatsBar` cuando el enlace es un repositorio GitHub con datos
    /// enriquecidos presentes en `repoInfo`. Si no hay stats, no ocupa espacio.
    @ViewBuilder
    private var repoStatsSection: some View {
        if let repo = link.repoInfo {
            RepoStatsBar(repo: repo)
        }
    }

    // MARK: - Seguir lanzamientos en GitHub

    /// Slug «owner/repo» si el enlace es un repositorio de GitHub; `nil` en otro caso.
    /// Solo `github.com`/`www.github.com` (no gist./raw./api.) y excluye rutas reservadas
    /// (features, about…) que no son repos.
    private var githubRepoSlug: String? {
        guard let url = StacklumeAutomationPolicy.openableStoredURL(link.url) else { return nil }
        let host = url.host?.lowercased()
        guard host == "github.com" || host == "www.github.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let reserved: Set<String> = ["features", "about", "pricing", "topics", "collections",
                                     "sponsors", "marketplace", "settings", "explore", "orgs",
                                     "login", "join", "new", "notifications", "search"]
        guard !reserved.contains(parts[0].lowercased()) else { return nil }
        let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        return "\(parts[0])/\(repo)"
    }

    private func releasesFeedURL(_ slug: String) -> String {
        "https://github.com/\(slug)/releases.atom"
    }

    /// ¿Ya sigue los lanzamientos de este repo? (su feed ya está en «Tus feeds»).
    private var isFollowingReleases: Bool {
        guard let slug = githubRepoSlug else { return false }
        let target = releasesFeedURL(slug)
        return CustomFeedStore.decode(customFeedsJSON).contains { $0.url == target }
    }

    /// Para repos de GitHub: seguir sus lanzamientos. Añade el feed Atom de releases del
    /// repo a «Tus feeds» de Descubrir (reutiliza el sistema de feeds del usuario, vía
    /// `releases.atom` → SIN API de GitHub, sin límite de peticiones). Conecta biblioteca
    /// y descubrimiento: un diferencial para desarrolladores que ningún competidor ofrece.
    @ViewBuilder
    private var followReleasesSection: some View {
        if let slug = githubRepoSlug {
            Button {
                guard !isFollowingReleases else { return }
                var feeds = CustomFeedStore.decode(customFeedsJSON)
                feeds.append(CustomFeed(title: "Lanzamientos · \(slug)", url: releasesFeedURL(slug)))
                withAnimation(.snappy) { customFeedsJSON = CustomFeedStore.encode(feeds) }
            } label: {
                Label(isFollowingReleases ? "Siguiendo lanzamientos en Descubrir" : "Seguir lanzamientos en GitHub",
                      systemImage: isFollowingReleases ? "checkmark.seal.fill" : "bell.badge.fill")
                    .stacklumeFont(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .stacklumeButton(prominent: false)
            .tint(isFollowingReleases ? Color(hex: "#34D399") : brand)
            .disabled(isFollowingReleases)
            .themedHelp("Añade los lanzamientos de \(slug) a tus feeds de Descubrir")
        }
    }

    // MARK: - Seguir versiones del paquete

    /// Info del comando de instalación SI es un paquete cuyo registro permite seguir
    /// versiones (pip/composer/npm/cargo/gem/go…). `nil` para URLs normales o gestores
    /// sin feed fiable (brew, dotnet).
    private var packageInfo: CommandInfo? {
        guard let command = link.command, !command.isEmpty,
              let info = CommandDetector.detect(command),
              PackageReleaseFeed.isSupported(manager: info.manager) else { return nil }
        return info
    }

    /// Para paquetes (npm i…, pip install…): seguir sus VERSIONES. Resuelve el feed del
    /// registro (PyPI/Packagist nativo; npm/cargo/gem vía su repo de GitHub) y lo añade a
    /// «Tus feeds» de Descubrir. Igual que [[followReleasesSection]] pero para paquetes,
    /// enfocado a desarrolladores: te avisa de nuevas versiones de tus herramientas.
    @ViewBuilder
    private var followPackageVersionsSection: some View {
        if let info = packageInfo {
            Button {
                guard versionsState == .idle || versionsState == .notFound else { return }
                versionsState = .resolving
                let manager = info.manager
                let pkg = info.packageName
                Task {
                    let resolved = await PackageReleaseFeed.resolve(manager: manager, packageName: pkg)
                    guard let resolved else { withAnimation(.snappy) { versionsState = .notFound }; return }
                    var feeds = CustomFeedStore.decode(customFeedsJSON)
                    if !feeds.contains(where: { $0.url == resolved.feedURL }) {
                        feeds.append(CustomFeed(title: resolved.title, url: resolved.feedURL))
                        customFeedsJSON = CustomFeedStore.encode(feeds)
                    }
                    withAnimation(.snappy) { versionsState = .added }
                }
            } label: {
                HStack(spacing: 8) {
                    switch versionsState {
                    case .resolving:
                        ProgressView().controlSize(.small)
                        Text("Buscando feed de versiones…")
                    case .added:
                        Image(systemName: "checkmark.seal.fill")
                        Text("Siguiendo versiones en Descubrir")
                    case .notFound:
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("No se encontró feed de versiones")
                    case .idle:
                        Image(systemName: "bell.badge.fill")
                        Text("Seguir versiones del paquete")
                    }
                }
                .stacklumeFont(.callout.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
            }
            .stacklumeButton(prominent: false)
            .tint(versionsState == .added ? Color(hex: "#34D399")
                  : versionsState == .notFound ? Color(hex: "#F59E0B") : brand)
            .disabled(versionsState == .resolving || versionsState == .added)
            .themedHelp("Añade las versiones de \(info.packageName) (\(info.manager)) a tus feeds de Descubrir")
        }
    }

    /// Comando de instalación guardado (npm i…, pip install…): tarjeta con monoespaciado
    /// y botón de copiar. Solo aparece si el enlace es un comando.
    @ViewBuilder
    private var commandSection: some View {
        if let command = link.command, !command.isEmpty {
            CommandCard(command: command)
        }
    }

    // MARK: - Barra de acciones (cristal con mesura)

    /// UN solo botón primario «Abrir original» (cristal neutro con velo dorado,
    /// abre la `url` externa) seguido de una fila compacta de botones de cristal con
    /// icono: Favorito (★ con rebote gateado por Reduce Motion), Compartir
    /// (`ShareLink`), Editar y «Abrir aquí» (icono `safari`, abre el visor interno).
    /// Menos peso dorado, más refinado (DESIGN.md §6/§10). Toda la fila de cristal va
    /// dentro de un `GlassEffectContainer` para que los efectos se fundan y rindan
    /// bien (§8: el cristal no muestrea otro cristal; agrupar los cercanos).
    private var actionBar: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            if link.fileKind != nil {
                Button(action: exportLocalDocument) {
                    Label("Exportar original…", systemImage: "square.and.arrow.up")
                        .stacklumeFont(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .stacklumeButton()
            } else {
                Button {
                    if let url = linkURL { openURL(url) }
                } label: {
                    Label("Abrir original", systemImage: "arrow.up.right.square")
                        .stacklumeFont(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .stacklumeButton()
                .disabled(linkURL == nil)
            }

            HStack(spacing: DesignSystem.Spacing.sm) {
                    secondaryAction(systemName: link.isFavorite ? "star.fill" : "star",
                                    tint: link.isFavorite ? palette.accent : palette.textPrimary,
                                    help: link.isFavorite ? "Quitar de favoritos" : "Favorito",
                                    symbolValue: link.isFavorite) {
                        BookmarkActions.toggleFavorite(link, in: context)
                    }

                    if let url = linkURL {
                        // Botón IDÉNTICO a los demás (mismo `secondaryAction` turquesa); al pulsarlo
                        // abre un popover temático con las opciones de compartir.
                        secondaryAction(systemName: "square.and.arrow.up", tint: palette.textPrimary,
                                        help: "Compartir") { showShareMenu = true }
                            .popover(isPresented: $showShareMenu, arrowEdge: .bottom) {
                                shareMenu(for: url)
                            }
                    }

                    secondaryAction(systemName: "pencil",
                                    tint: palette.textPrimary,
                                    help: "Editar") {
                        actions.edit(link)
                    }

                    if let url = linkURL {
                        secondaryAction(systemName: "safari",
                                        tint: palette.textPrimary,
                                        help: "Abrir aquí") {
                            inAppURL = IdentifiableURL(url: url, offlineHTML: link.offlineHTML)
                        }
                    }

                    // Leer en voz alta (TTS on-device): lee el artículo. Mientras suena este
                    // enlace, el botón pausa/reanuda; un segundo botón (stop) aparece al lado.
                    let reading = aloud.isReading(link.id)
                    secondaryAction(systemName: reading ? (aloud.isPaused ? "play.fill" : "pause.fill") : "speaker.wave.2",
                                    tint: palette.textPrimary,
                                    help: reading ? (aloud.isPaused ? "Reanudar" : "Pausar") : "Leer en voz alta") {
                        if reading { aloud.togglePause() } else { startReadAloud() }
                    }
                    if reading {
                        secondaryAction(systemName: "stop.fill", tint: palette.textSecondary,
                                        help: "Detener lectura") { aloud.stop() }
                    }

                    // Archivar en la Wayback Machine (copia permanente en internet, además de la
                    // copia offline local). Acción EXPLÍCITA: es lo único que manda la URL a un
                    // tercero. Si ya está archivada, el botón abre la copia más reciente.
                    if linkURL != nil {
                        if archivingWayback {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 34, height: 30)
                        } else if waybackArchived {
                            // `textPrimary` (no acento): el cristal se tiñe de acento y un icono
                            // de acento quedaría invisible sobre él (igual que el botón de IA).
                            secondaryAction(systemName: "checkmark.seal.fill", tint: palette.textPrimary,
                                            help: "Ver copia archivada (Wayback Machine)") {
                                if let snap = WaybackArchive.snapshotURL(for: link.url) { openURL(snap) }
                            }
                        } else {
                            secondaryAction(systemName: "clock.arrow.circlepath", tint: palette.textPrimary,
                                            help: "Archivar en la Wayback Machine") {
                                archiveInWayback()
                            }
                        }
                    }

                    // Mejorar con IA: SIEMPRE disponible (antes se ocultaba si el modelo no
                    // estaba descargado). Refresca los metadatos de red —título, descripción
                    // e imagen— y, si el modelo local está (o el usuario acepta descargarlo),
                    // reescribe título/descripción con la IA. Conserva colección y etiquetas.
                    if linkURL != nil {
                        Button(action: improveWithAI) {
                            Group {
                                if improvingAI {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "wand.and.stars")
                                        .scaledFont(14, weight: .semibold, scalesWithText: false)
                                        .foregroundStyle(palette.accent)
                                }
                            }
                            .frame(width: 34, height: 30)
                            .contentShape(Rectangle())
                        }
                        .stacklumeButton(prominent: false, compact: true)
                        .themedHelp("Mejorar con IA")
                        .accessibilityLabel("Mejorar con IA")
                        .disabled(improvingAI)

                        // Preguntar a la IA sobre este enlace: abre el chat con la pregunta
                        // lista. Solo con el modelo YA cargado (necesita generar en el acto).
                        if aiRunner.isReady {
                            secondaryAction(systemName: "questionmark.bubble",
                                            tint: palette.textPrimary,
                                            help: "Preguntar a la IA sobre este enlace") {
                                askAI()
                            }
                        }
                    }

                Spacer(minLength: 0)
            }
            .stacklumeGlassContainer(spacing: DesignSystem.Spacing.sm)
        }
    }

    /// Botón cuadrado de cristal para las acciones secundarias de la barra. Si se
    /// pasa `symbolValue`, el símbolo rebota (`.bounce`) cuando ese valor cambia
    /// (p. ej. al marcar/desmarcar favorito). Multiplataforma (macOS 14+).
    private func secondaryAction(systemName: String, tint: Color, help: String,
                                 symbolValue: Bool? = nil,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .scaledFont(14, weight: .semibold, scalesWithText: false)
                // El cristal es neutro: el color puede comunicar estado sin perder contraste.
                .foregroundStyle(tint)
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
                // Respeta «Reducir movimiento»: si está activo, no se aplica el rebote.
                .symbolEffect(.bounce, value: reduceMotion ? false : (symbolValue ?? false))
        }
        .stacklumeButton(prominent: false, compact: true)
        .themedHelp(help)
        .accessibilityLabel(help)   // VoiceOver: botones de solo-icono de la barra de acciones
    }

    // MARK: - Reproductor de lectura en voz alta

    /// Barra-reproductor de la lectura en voz alta con **Kokoro** (voz neural): estado de descarga
    /// del modelo, frase que suena, progreso y controles (pausa, voz, detener). Visible mientras
    /// Kokoro lee ESTE enlace.
    @ViewBuilder private var readAloudBar: some View {
        if aloud.isReading(link.id) {
            ReadAloudBar(aloud: aloud)
        }
    }

    /// Lleva al chat de IA con una pregunta ya escrita sobre este enlace, vía el buzón
    /// del asistente + navegación a la sección IA. El agente local puede entonces
    /// resumirlo, compararlo con tu biblioteca o buscar más en internet.
    private func askAI() {
        let name = link.title.isEmpty ? link.url : link.title
        // Deja el enlace EN CONTEXTO del asistente: así el seguimiento («muévelo a X»,
        // «etiquétalo», «ábrelo»…) se refiere a este sin volver a nombrarlo.
        assistantInbox?.contextLink = LinkContext(link)
        assistantInbox?.pendingPrompt =
            "Háblame de este enlace y dame los puntos clave:\n\(name)\n\(link.url)"
        NotificationCenter.default.post(name: .stacklumeGoToSection, object: NavTarget.ai.key)
    }

    /// Carga el texto legible del artículo (copia offline si la hay; si no, lo descarga) y
    /// calcula el tiempo de lectura estimado. Alimenta también la lectura en voz alta.
    @MainActor
    private func loadArticleText() async {
        readingMinutes = nil
        guard link.modelContext != nil else { return }   // anti-crash: enlace borrado (reset/eliminar)
        if let offline = link.offlineText,
           link.fileKind != nil ? !offline.isEmpty : offline.count > 200 {
            articleText = ProseText.clean(offline)
        } else if link.fileKind != nil {
            // Un adjunto local nunca debe caer al extractor web con una URL vacía.
            articleText = nil
        } else if let html = await MacOfflineCopyService.fetchReadable(url: link.url) {
            guard link.modelContext != nil else { return }
            articleText = ProseText.clean(OfflineCopyService.plainText(from: html))
        } else {
            articleText = nil
        }
        readingMinutes = ReadingMetrics.minutes(forText: articleText)
    }

    private func indexDocumentIfNeeded() async {
        guard link.fileKind != nil, link.fileKind != "audio", link.fileKind != "video",
              link.offlineText == nil, !extractingDocumentText else { return }
        extractingDocumentText = true
        defer { extractingDocumentText = false }
        do {
            if let result = try await DocumentTextCoordinator.indexIfNeeded(
                link, in: context, waitForIdle: true
            ) {
                applyDocumentTextResult(result)
            }
        } catch is CancellationError {
            // Cambiar de selección cancela el feedback de esta ficha; no es un error visible.
        } catch {
            documentTextMessage = error.localizedDescription
        }
    }

    private func reindexDocument() {
        guard !extractingDocumentText else { return }
        extractingDocumentText = true
        documentTextMessage = nil
        Task { @MainActor in
            defer { extractingDocumentText = false }
            do {
                if let result = try await DocumentTextCoordinator.reindex(link, in: context) {
                    applyDocumentTextResult(result)
                }
            } catch is CancellationError {
                return
            } catch {
                documentTextMessage = error.localizedDescription
            }
        }
    }

    private func applyDocumentTextResult(_ result: DocumentTextExtractionResult) {
        articleText = result.text.isEmpty ? nil : ProseText.clean(result.text)
        readingMinutes = ReadingMetrics.minutes(forText: articleText)
        if result.text.isEmpty {
            documentTextMessage = "Análisis completado: no se encontró texto legible."
            return
        }
        let pages: String
        if link.fileKind == "epub" {
            pages = "\(result.recognizedPageCount) de \(result.totalPageCount) capítulos"
        } else if result.totalPageCount == 1 {
            pages = "la imagen"
        } else {
            pages = "\(result.recognizedPageCount) de \(result.totalPageCount) páginas"
        }
        let method = result.usedOCR ? " con OCR local" : ""
        let suffix = result.wasTruncated ? " Se indexó una parte segura del documento." : ""
        documentTextMessage = "Texto extraído de \(pages)\(method).\(suffix)"
    }

    /// Empieza a leer en voz alta SOLO la DESCRIPCIÓN del enlace (de qué va). NO lee el título
    /// técnico, NI la URL/sitio, NI el artículo completo: el usuario quiere una lectura corta y al
    /// grano, no «historias».
    private func startReadAloud() {
        let lang = AppSettingsStore.current(in: context).language.rawValue
        let text = spokenDescription()
        guard !text.isEmpty else { return }
        aloud.start(text, language: lang, id: link.id)
    }

    /// Lo que se lee en voz alta: la DESCRIPCIÓN del enlace (la prosa rica en español que generó
    /// la IA). Si por lo que sea no hay descripción, usa el TL;DR (`summary`); y solo como último
    /// recurso, el título. Nada de URL, sitio ni artículo: corto y al grano.
    private func spokenDescription() -> String {
        let details = (link.details ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !details.isEmpty { return details }
        let summary = (link.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { return summary }
        return link.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Compartir (popover temático)

    /// Contenido del popover de compartir: WhatsApp y Telegram SOLO si están instalados (detectado
    /// por su esquema de app), más el compartir nativo del sistema y copiar. Con la estética del tema.
    @ViewBuilder
    private func shareMenu(for url: URL) -> some View {
        let hasWhatsApp = appInstalled("whatsapp://")
        let hasTelegram = appInstalled("tg://")
        VStack(alignment: .leading, spacing: 1) {
            if StacklumeAutomationPolicy.allowsAutomaticNetworkURL(url), link.fileKind == nil {
                shareOption("Crear publicación para X", "at") {
                    showShareMenu = false
                    showXComposer = true
                }
                Divider().overlay(palette.border.opacity(0.4)).padding(.vertical, 3)
            }
            if hasWhatsApp {
                shareOption("WhatsApp", "message.fill") { showShareMenu = false; shareToWhatsApp(url) }
            }
            if hasTelegram {
                shareOption("Telegram", "paperplane.fill") { showShareMenu = false; shareToTelegram(url) }
            }
            if hasWhatsApp || hasTelegram {
                Divider().overlay(palette.border.opacity(0.4)).padding(.vertical, 3)
            }
            ShareLink(item: url) {
                shareRowLabel("Más opciones…", "ellipsis")
            }
            .buttonStyle(.plain)
            shareOption("Copiar enlace", "doc.on.doc") { showShareMenu = false; copyShareLink(url) }
        }
        .padding(6)
        .frame(width: 230)
        .background(palette.surface)
    }

    private func shareOption(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { shareRowLabel(title, icon) }
            .buttonStyle(.plain)
    }

    private func shareRowLabel(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon)
            .stacklumeFont(.callout)
            .foregroundStyle(palette.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
    }

    /// ¿Hay una app que pueda abrir este esquema? (p. ej. `whatsapp://`, `tg://`).
    private func appInstalled(_ scheme: String) -> Bool {
        guard let url = URL(string: scheme) else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }

    /// Abre WhatsApp (de escritorio) con el título + la URL ya escritos (esquema nativo).
    private func shareToWhatsApp(_ url: URL) {
        let text = (link.title.isEmpty ? "" : link.title + "\n") + url.absoluteString
        if let target = URL(string: "whatsapp://send?text=\(percentEncoded(text))") { openURL(target) }
    }

    /// Abre Telegram (de escritorio) con el enlace prerrellenado y el título como texto (esquema nativo).
    private func shareToTelegram(_ url: URL) {
        let title = link.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var target = "tg://msg_url?url=\(percentEncoded(url.absoluteString))"
        if !title.isEmpty { target += "&text=\(percentEncoded(title))" }
        if let u = URL(string: target) { openURL(u) }
    }

    /// Percent-encoding seguro para un valor de query de esquema custom (escapa también &=?#+).
    private func percentEncoded(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?#+")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private func copyShareLink(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    /// Devuelve al usuario el archivo original guardado en SwiftData. La escritura solo
    /// ocurre tras elegir explícitamente el destino en el panel nativo.
    @MainActor
    private func exportLocalDocument() {
        guard let data = link.fileData, let kind = link.fileKind else { return }
        let type = LocalDocumentFileType.contentType(for: data, kind: kind)
        let ext = LocalMediaFileFormat.fileExtension(for: data, kind: kind)
            ?? type.preferredFilenameExtension ?? (kind == "pdf" ? "pdf" : kind == "epub" ? "epub" : kind == "image" ? "img" : kind)
        let panel = NSSavePanel()
        panel.title = "Exportar original"
        panel.prompt = "Exportar"
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(safeDocumentName(link.title)).\(ext)"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "No se pudo exportar el archivo"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Aceptar")
            alert.runModal()
        }
    }

    private func safeDocumentName(_ raw: String) -> String {
        let cleaned = raw.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty { return cleaned }
        return switch link.fileKind {
        case "pdf": "Documento"
        case "epub": "Libro"
        default: "Imagen"
        }
    }

    /// Re-enriquece este enlace con la IA local (Liquid), rellenando los huecos
    /// (título/descripción/colección/etiquetas) a partir del contenido real de la
    /// página. Reutiliza `AIBatchEnricher.enrichOne` (mismo camino que el alta y el
    /// lote): no duplica lógica ni pisa lo que el usuario ya escribió.
    private func improveWithAI() {
        guard !improvingAI else { return }
        // Detección ROBUSTA del modelo: disponible si está cargado, marcado como descargado
        // O presente en disco (`isAvailable`). NO basta el flag `isDownloaded` de
        // UserDefaults —puede estar a false aunque el modelo lleve toda la sesión funcionando—.
        // Solo se OFRECE descargar si de verdad no está en ningún sitio.
        if aiRunner.isAvailable {
            runEnrich(useAI: true)
        } else {
            showAIDownloadPrompt = true
        }
    }

    /// Ejecuta el enriquecido en tres pasos, reutilizando los servicios existentes (no
    /// duplica): 1) metadatos de red SIEMPRE (título/descripción/imagen/autor, sin IA),
    /// 2) reescritura con el modelo local si `useAI` (lo activa/carga si hace falta y se
    /// pidió), 3) si AÚN no hay imagen, busca la imagen principal de la página. `force:
    /// true` regenera título/descripción conservando la colección y etiquetas del usuario.
    private func runEnrich(useAI: Bool) {
        guard !improvingAI else { return }
        improvingAI = true
        let language = AppSettingsStore.current(in: context).language.rawValue
        Task { @MainActor in
            defer { improvingAI = false }
            // «Mejorar con IA» es una orden EXPLÍCITA de regenerar ESTE enlace: levanta la protección
            // de edición manual de este enlace ([[UserEditLedger]]) para que pueda rehacerse. En el
            // resto de rutas (barrido automático, «a fondo») las ediciones a mano SÍ se respetan.
            if useAI { UserEditLedger.clear(link.id) }
            await MacLinkEnricher.enrichFromNetwork(link, in: context, overwriteTitle: false)
            guard link.modelContext != nil else { return }
            // Render UNA vez (favicon real + título en vivo + TEXTO renderizado) para webs JS cuyo
            // HTML estático no da favicon/prosa (p. ej. dynamicmaclake): así «Mejorar con IA»
            // arregla el favicon, el título y FUNDAMENTA la IA (descripción/categoría correctas, no
            // un «Videojuegos» inventado). Punto único [[LibraryCompleter]]/[[FaviconRenderer]].
            let renderedText = await LibraryCompleter.renderAndApplyMeta(link)
            guard link.modelContext != nil else { return }
            // Si el render no dio favicon (la web sí lo tiene en ruta estándar), prueba la cascada barata.
            if link.faviconURL?.isEmpty != false {
                await LibraryCompleter.ensureWorkingFavicon(link, allowRender: false)
            }
            if useAI, await aiRunner.ensureReady(userInitiated: true) != nil, link.modelContext != nil {
                await AIBatchEnricher.enrichOne(link, in: context, provider: "liquid",
                                                language: language, force: true, prefetchedContent: renderedText)
                // TL;DR de una frase (campo `summary`) para escanear sin abrir.
                await LinkSummarizer.summarize(link, in: context, language: language, force: true)
            }
            // Portada perfecta si aún falta (og:image / `<img>` hero / captura renderizada).
            // Punto único reutilizado por alta y lote (ver [[CoverEnsurer]]).
            if link.modelContext != nil {
                await CoverEnsurer.ensure(for: link, in: context)
            }
            await resolveHeroAspect()
            // «Mejorar con IA» también debe dejar el TÍTULO en español: si quedó en un idioma no
            // latino (chino/japonés…), pide al motor de traducción ([[AutoTranslateEngine]]) que lo
            // traduzca AHORA, FORZANDO el reintento (ignora el ledger anti-bucle, porque es una
            // acción manual del usuario). El título lo traduce el framework Translation de Apple
            // (sesión de vista), no la IA local; por eso se delega aquí en vez de en `enrichOne`.
            if link.modelContext != nil, LinkTranslator.needsTranslation(link) {
                NotificationCenter.default.post(name: .stacklumeAutoTranslate, object: nil,
                                                userInfo: ["force": true])
            }
            WidgetReloader.reload()
        }
    }

    /// Busca y fija automáticamente la imagen principal de la página (web fetch, SIN IA).
    /// Si la página no expone ninguna imagen de portada, avisa y conserva el logo centrado.
    private func fetchImageAutomatically() {
        guard !fetchingImage, link.modelContext != nil, link.deletedAt == nil else { return }
        let page = link.url
        let reference = link.imageURL
        let owner = link.modelContext
        fetchingImage = true
        Task { @MainActor in
            defer { fetchingImage = false }
            guard !Task.isCancelled, link.modelContext === owner, link.deletedAt == nil,
                  link.url == page, link.imageURL == reference else { return }
            if let reference, !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let result = await CoverEnsurer.recoverReference(for: link, retry: true)
                guard !Task.isCancelled, result != .cancelled, link.modelContext === owner, link.deletedAt == nil,
                      link.url == page, link.imageURL == reference else { return }
                let recoveredFromPage = result == .unavailable
                    ? await CoverEnsurer.recoverFromPage(for: link, in: context, retry: true) : false
                guard !Task.isCancelled, link.modelContext === owner, link.deletedAt == nil,
                      link.url == page, link.imageURL == reference else { return }
                if result == .stored || result == .acquired || recoveredFromPage {
                    await resolveHeroAspect()
                    WidgetReloader.reload()
                } else { imageFetchFailed = true }
                return
            }
            if await CoverEnsurer.ensure(for: link, in: context, retry: true) {
                await resolveHeroAspect()
                WidgetReloader.reload()
                return
            }
            if Task.isCancelled { return }
            imageFetchFailed = true
        }
    }

    /// Archiva la página en la Wayback Machine (acción explícita del usuario). Mientras dura,
    /// muestra un spinner; al terminar con éxito, el botón pasa a «Ver copia archivada».
    private func archiveInWayback() {
        guard linkURL != nil, !archivingWayback else { return }
        archivingWayback = true
        let urlString = link.url
        Task {
            let ok = await WaybackArchive.archive(urlString)
            await MainActor.run {
                archivingWayback = false
                waybackArchived = ok || WaybackStore.isArchived(urlString)
            }
        }
    }

    /// Extrae los puntos clave del artículo con la IA local y los guarda como resaltados.
    /// Usa el contenido offline si está; si no, descarga el texto legible de la página
    /// (mismo extractor que el enriquecido). No duplica resaltados ya existentes.
    private func extractKeyPoints() {
        guard !extractingHighlights else { return }
        extractingHighlights = true
        let lang = AppSettingsStore.current(in: context).language.rawValue
        Task { @MainActor in
            defer { extractingHighlights = false }
            var content = link.offlineText ?? ""
            if content.count < 120 {
                content = await AIBatchEnricher.pageContentExcerpt(for: link.url) ?? content
            }
            guard content.count >= 120,
                  let points = await LiquidAIService.keyPoints(from: content, language: lang),
                  !points.isEmpty,
                  link.modelContext != nil else { return }
            let existing = Set(link.highlights.map(\.text))
            let palette = ColorPresets.all
            var added = 0
            for point in points where !existing.contains(point) {
                let color = palette.isEmpty ? "#D4A853" : palette[added % palette.count]
                context.insert(Highlight(text: point, colorHex: color, bookmark: link))
                added += 1
            }
            if added > 0 { link.updatedAt = Date(); context.saveLogging() }
        }
    }

    // MARK: - Descripción / extracto

    /// TL;DR de una frase generado por la IA local (`summary`), destacado en una píldora
    /// para escanear la idea principal de un vistazo. Solo si existe (lo genera «Mejorar
    /// con IA» o el lote de Mantenimiento «Generar resúmenes»).
    @ViewBuilder
    private var summarySection: some View {
        if let summary = link.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "sparkles")
                    .foregroundStyle(palette.accent)
                    .padding(.top, 2)
                Text(summary)
                    .stacklumeFont(.callout.weight(.medium))
                    .foregroundStyle(palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DesignSystem.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(palette.accent.opacity(0.25), lineWidth: 0.5)
            )
        }
    }

    /// Extracto Open Graph del enlace (`details`), si la página lo aporta. Texto
    /// legible que da contexto sin abrir el original, al estilo del excerpt de
    /// raindrop.
    @ViewBuilder
    private var descriptionSection: some View {
        if let details = link.details, !details.isEmpty {
            Text(details)
                .stacklumeFont(.body)
                .foregroundStyle(palette.textPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Texto de documentos locales

    @ViewBuilder
    private var documentTextSection: some View {
        if link.fileKind == "audio" || link.fileKind == "video" {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                sectionHeader("Contenido buscable")
                Text(link.fileKind == "audio"
                     ? "Puedes encontrar este audio describiendo lo que se escucha."
                     : "Puedes encontrar este vídeo describiendo lo que aparece o se escucha.")
                    .stacklumeFont(.callout)
                    .foregroundStyle(palette.textSecondary)
            }
            .padding(DesignSystem.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else if link.fileKind != nil {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    sectionHeader("Contenido buscable")
                    Spacer()
                    if extractingDocumentText {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Extrayendo texto del documento")
                    }
                }

                if extractingDocumentText {
                    Label("Reconociendo texto en tu Mac…", systemImage: "text.viewfinder")
                        .stacklumeFont(.callout)
                        .foregroundStyle(palette.textSecondary)
                } else if let text = link.offlineText, !text.isEmpty {
                    Text(text)
                        .stacklumeFont(.callout)
                        .foregroundStyle(palette.textPrimary)
                        .stacklumeLineLimit(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Button("Ver texto completo", systemImage: "doc.text.magnifyingglass") {
                            showDocumentText = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(palette.accent)

                        Button("Volver a extraer", systemImage: "arrow.clockwise") {
                            reindexDocument()
                        }
                        .buttonStyle(.bordered)
                        .themedHelp("Repetir la extracción local de texto")

                        Spacer()
                        Text("\(text.count.formatted()) caracteres")
                            .stacklumeFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                    }
                } else if link.offlineText != nil {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Label("No se detectó texto legible.", systemImage: "doc.text")
                            .stacklumeFont(.callout)
                            .foregroundStyle(palette.textSecondary)
                        Spacer()
                        Button("Reintentar") { reindexDocument() }
                            .buttonStyle(.bordered)
                    }
                } else {
                    Button("Extraer texto y hacerlo buscable", systemImage: "text.viewfinder") {
                        reindexDocument()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                }

                if let message = documentTextMessage {
                    Text(message)
                        .stacklumeFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .accessibilityLabel("Resultado de la extracción: \(message)")
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.border.opacity(0.5), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Metadatos

    /// Tarjeta de metadatos: tipo, plataforma, colección, estado de lectura, fecha
    /// de guardado y recordatorio. El estado de lectura es editable (conserva el
    /// control que tenía la toolbar).
    private var metadataCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            metaRow(label: "Tipo", systemImage: link.contentType.sfSymbol) {
                Text(link.contentType.displayName)
                    .foregroundStyle(palette.textPrimary)
            }
            if let data = link.fileData, let kind = link.fileKind {
                Divider().overlay(palette.border.opacity(0.4))
                metaRow(label: "Archivo", systemImage: localDocumentSymbol(for: kind)) {
                    Text("\(localDocumentName(for: kind)) · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
                        .foregroundStyle(palette.textPrimary)
                        .stacklumeLineLimit(1)
                }
            }
            Divider().overlay(palette.border.opacity(0.4))
            metaRow(label: "Plataforma", systemImage: link.platform.sfSymbol) {
                Text(link.platform.displayName)
                    .foregroundStyle(palette.textPrimary)
            }
            if let category = link.category {
                Divider().overlay(palette.border.opacity(0.4))
                metaRow(label: "Colección", systemImage: category.icon) {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: category.colorHex)).frame(width: 8, height: 8)
                        Text(category.name).foregroundStyle(palette.textPrimary)
                    }
                }
            }
            Divider().overlay(palette.border.opacity(0.4))
            metaRow(label: "Estado de lectura", systemImage: link.readingStatus.sfSymbol) {
                Picker("Estado de lectura", selection: Binding(
                    get: { link.readingStatus },
                    set: { BookmarkActions.setReadingStatus($0, for: link, in: context) }
                )) {
                    ForEach(ReadingStatus.allCases) { status in
                        Label(status.displayName, systemImage: status.sfSymbol).tag(status)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(palette.accent)
                .fixedSize()
            }
            Divider().overlay(palette.border.opacity(0.4))
            metaRow(label: "Guardado", systemImage: "calendar") {
                Text(Self.savedDateFormatter.string(from: link.createdAt))
                    .foregroundStyle(palette.textPrimary)
            }
            if let author = link.author, !author.isEmpty {
                Divider().overlay(palette.border.opacity(0.4))
                metaRow(label: "Autor", systemImage: "person") {
                    Text(author).foregroundStyle(palette.textPrimary).stacklumeLineLimit(1)
                }
            }
            if let published = link.publishedAt {
                Divider().overlay(palette.border.opacity(0.4))
                metaRow(label: "Publicado", systemImage: "calendar.badge.clock") {
                    Text(Self.savedDateFormatter.string(from: published))
                        .foregroundStyle(palette.textPrimary)
                }
            }
            if let mins = readingMinutes {
                Divider().overlay(palette.border.opacity(0.4))
                metaRow(label: "Lectura", systemImage: "clock") {
                    Text("\(ReadingMetrics.label(mins)) de lectura")
                        .foregroundStyle(palette.textPrimary)
                }
            }
            if let reminderAt = link.reminderAt {
                Divider().overlay(palette.border.opacity(0.4))
                metaRow(label: "Recordatorio", systemImage: "bell.fill") {
                    Text(Self.savedDateFormatter.string(from: reminderAt))
                        .foregroundStyle(palette.accent)
                }
            }
            if let reviewAt = link.reviewAt {
                Divider().overlay(palette.border.opacity(0.4))
                metaRow(label: "Repaso", systemImage: "arrow.triangle.2.circlepath") {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Text(reviewAt <= Date() ? "Toca repasarlo" : Self.savedDateFormatter.string(from: reviewAt))
                            .foregroundStyle(reviewAt <= Date() ? .green : palette.accent)
                        Button("Hecho") {
                            BookmarkActions.setReviewDate(nil, for: link, in: context)
                        }
                        .buttonStyle(.borderless)
                        .stacklumeFont(.caption.weight(.medium))
                        .tint(palette.accent)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.border.opacity(0.5), lineWidth: 0.5)
        )
    }

    /// Fila etiqueta → valor limpia, con icono guía a la izquierda.
    private func metaRow<Value: View>(label: String, systemImage: String,
                                      @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: systemImage)
                .scaledFont(12, weight: .medium, scalesWithText: false)
                .foregroundStyle(palette.textSecondary)
                .frame(width: 18)
            Text(label)
                .stacklumeFont(.callout)
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: DesignSystem.Spacing.sm)
            value()
                .stacklumeFont(.callout)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
    }

    // MARK: - Etiquetas

    @ViewBuilder
    private var tagsSection: some View {
        if !link.tags.isEmpty {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                sectionHeader("Etiquetas")
                FlowLayout(spacing: 6) {
                    ForEach(link.tags) { TagChip(tag: $0) }
                }
            }
        }
    }

    private func localDocumentName(for kind: String) -> String {
        switch kind {
        case "pdf": "PDF"
        case "epub": "EPUB"
        default: "Imagen"
        }
    }

    private func localDocumentSymbol(for kind: String) -> String {
        switch kind {
        case "pdf": "doc.richtext"
        case "epub": "book.closed"
        default: "photo"
        }
    }

    // MARK: - Notas

    @ViewBuilder
    private var notesSection: some View {
        if let notes = link.notes, !notes.isEmpty {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                sectionHeader("Notas")
                Text(notes)
                    .stacklumeFont(.callout)
                    .foregroundStyle(palette.textPrimary)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignSystem.Spacing.md)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(palette.border.opacity(0.5), lineWidth: 0.5)
                    )
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .stacklumeFont(.caption.weight(.semibold))
            .foregroundStyle(palette.textSecondary)
            .textCase(.uppercase)
    }

    // MARK: - Resaltados

    /// Resaltados del enlace ordenados por antigüedad (como el iPhone). Usa la
    /// relación `Bookmark.highlights` del MODELO compartido del core.
    private var sortedHighlights: [Highlight] {
        link.highlights.sorted { $0.createdAt < $1.createdAt }
    }

    /// Sección de resaltados: cabecera con acción «+» para añadir y, debajo, la
    /// lista de citas (texto + barra de color) editables y eliminables. Si no hay
    /// resaltados, una línea discreta invita a guardar fragmentos. El botón de
    /// añadir está SIEMPRE presente en la cabecera (no se esconde).
    private var highlightsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                sectionHeader("Resaltados")
                Spacer()
                if aiRunner.isDownloaded, !aiRunner.isDeactivated {
                    Button {
                        extractKeyPoints()
                    } label: {
                        if extractingHighlights {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                                .scaledFont(13, weight: .semibold, scalesWithText: false)
                                .foregroundStyle(palette.accent)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(extractingHighlights)
                    .themedHelp("Extraer puntos clave con IA")
                    .accessibilityLabel("Extraer puntos clave con IA")
                }
                Button {
                    highlightEditor = .create(link)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .scaledFont(14, weight: .semibold, scalesWithText: false)
                        .foregroundStyle(palette.accent)
                }
                .buttonStyle(.plain)
                .themedHelp("Añadir resaltado")
                .accessibilityLabel("Añadir resaltado")
            }

            if sortedHighlights.isEmpty {
                Text("Guarda fragmentos o citas de este enlace.")
                    .stacklumeFont(.callout)
                    .foregroundStyle(palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignSystem.Spacing.md)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(palette.border.opacity(0.5), lineWidth: 0.5)
                    )
            } else {
                VStack(spacing: DesignSystem.Spacing.xs) {
                    ForEach(sortedHighlights) { highlight in
                        highlightCard(highlight)
                    }
                }
            }
        }
    }

    /// Tarjeta de un resaltado: barra de color a la izquierda (su `colorHex`),
    /// la cita (toda la fila es pulsable para editar) y un botón de eliminar
    /// discreto al pasar el ratón / siempre accesible. Fondo teñido sutil con el
    /// propio color del resaltado, al estilo del iPhone pero con piel Mac.
    private func highlightCard(_ highlight: Highlight) -> some View {
        let swatch = Color(hex: highlight.colorHex)
        return HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(swatch)
                .frame(width: 4)

            Button {
                highlightEditor = .edit(highlight)
            } label: {
                Text(highlight.text)
                    .stacklumeFont(.callout)
                    .foregroundStyle(palette.textPrimary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .themedHelp("Editar resaltado")

            Button {
                deleteHighlight(highlight)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(13, weight: .semibold, scalesWithText: false)
                    .foregroundStyle(palette.textSecondary)
            }
            .buttonStyle(.plain)
            .themedHelp("Eliminar resaltado")
            .accessibilityLabel("Eliminar resaltado")
        }
        .padding(.vertical, DesignSystem.Spacing.sm)
        .padding(.horizontal, DesignSystem.Spacing.md)
        .background(swatch.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(swatch.opacity(0.30), lineWidth: 0.5)
        )
    }

    private func deleteHighlight(_ highlight: Highlight) {
        withAnimation(reduceMotion ? nil : .snappy) {
            context.delete(highlight)
        }
        link.updatedAt = Date()
        context.saveLogging()
    }

    // MARK: - Copia sin conexión

    /// Solo para enlaces web (http/https) sin adjunto local.
    private var canHaveOfflineCopy: Bool {
        link.fileData == nil
            && (link.url.hasPrefix("http://") || link.url.hasPrefix("https://"))
    }

    @ViewBuilder
    private var offlineSection: some View {
        if canHaveOfflineCopy {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                sectionHeader("Sin conexión")
                if link.offlineHTML != nil {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Button {
                            showOfflineReader = true
                        } label: {
                            Label("Leer sin conexión", systemImage: "book.closed.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 2)
                        }
                        .stacklumeButton()

                        Button {
                            Task { await saveOfflineCopy() }
                        } label: {
                            if savingOffline {
                                ProgressView().controlSize(.small)
                                    .frame(width: 34, height: 28)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .frame(width: 34, height: 28)
                            }
                        }
                        .stacklumeButton(prominent: false, compact: true)
                        .themedHelp("Actualizar copia sin conexión")
                        .accessibilityLabel("Actualizar copia sin conexión")
                        .disabled(savingOffline)
                    }
                } else {
                    Button {
                        Task { await saveOfflineCopy() }
                    } label: {
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            if savingOffline {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.down.circle")
                            }
                            Text(savingOffline ? "Guardando copia…" : "Guardar copia sin conexión")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                    }
                    .stacklumeButton(prominent: false)
                    .disabled(savingOffline)
                }
            }
        }
    }

    // MARK: - Enlaces relacionados (similitud semántica · supera a Raindrop)

    @ViewBuilder
    private var relatedSection: some View {
        if !relatedLinks.isEmpty {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                sectionHeader("Enlaces relacionados")
                ForEach(relatedLinks) { rel in
                    Button {
                        if let u = StacklumeAutomationPolicy.openableStoredURL(rel.url) { openURL(u) }
                    } label: {
                        HStack(spacing: 10) {
                            SecureRemoteImage(candidates: [rel.faviconURL, rel.imageURL], skeleton: { Color.clear }) {
                                Image(systemName: rel.symbol)
                                    .font(.caption).foregroundStyle(palette.textSecondary)
                            }
                            .frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(rel.title.isEmpty ? rel.url : rel.title)
                                    .stacklumeFont(.callout).foregroundStyle(palette.textPrimary)
                                    .stacklumeLineLimit(1).truncationMode(.tail)
                                Text(rel.host)
                                    .stacklumeFont(.caption2).foregroundStyle(palette.textSecondary).stacklumeLineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.right")
                                .font(.caption2).foregroundStyle(palette.textSecondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .themedHelp("Abrir «\(rel.title.isEmpty ? rel.url : rel.title)»")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Instantánea (value type) de un enlace relacionado. Se captura mientras el modelo
    /// es válido para que `relatedSection` NUNCA acceda a un `@Model` que pueda haberse
    /// borrado (evita el crash de SwiftData al renderizar tras eliminar un enlace).
    private struct RelatedLinkInfo: Identifiable {
        let url: String
        let title: String
        let host: String
        let faviconURL: String?
        let imageURL: String?
        let symbol: String
        var id: String { url }
    }

    /// Calcula los enlaces relacionados por significado (precalienta vectores y rankea).
    private func loadRelated() async {
        relatedLinks = []
        // Debounce: NO calcular «relacionados» hasta que el usuario se ASIENTE en este enlace
        // (~0,6 s). Evita disparar en CADA clic el `fetch` O(n) + los embeddings (BNNS) + el
        // coseno mientras navega rápido o scrollea —era el retraso del clic y parte del scroll
        // entrecortado—. Si cambia de enlace, el `.task(id: link.id)` cancela esta tarea.
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled, link.modelContext != nil else { return }
        let lang = AppSettingsStore.current(in: context).language.rawValue
        guard SemanticSearch.isAvailable(language: lang) else { return }
        let all = (try? context.fetch(FetchDescriptor<Bookmark>(predicate: #Predicate {
            $0.deletedAt == nil && !$0.isArchived
        }))) ?? []
        guard all.count > 1 else { return }
        await SemanticSearch.warm(all, language: lang)
        guard !Task.isCancelled, link.modelContext != nil else { return }
        // Instantánea inmediata a value types (mientras los modelos son válidos): la
        // vista no debe retener `@Model` que puedan borrarse → no más crash al renderizar.
        relatedLinks = SemanticSearch.related(to: link, in: all, language: lang)
            .filter { $0.modelContext != nil }
            .map { RelatedLinkInfo(url: $0.url, title: $0.title, host: $0.url.urlHost,
                                   faviconURL: $0.faviconURL, imageURL: $0.imageURL,
                                   symbol: $0.platform.sfSymbol) }
    }

    private func saveOfflineCopy() async {
        guard !savingOffline else { return }
        savingOffline = true
        let html = await MacOfflineCopyService.fetchReadable(url: link.url)
        await MainActor.run {
            // El enlace pudo borrarse durante la descarga: escribir en un @Model invalidado
            // haría fatalError en SwiftData.
            guard link.modelContext != nil else { savingOffline = false; return }
            if let html {
                link.offlineHTML = html
                link.offlineText = OfflineCopyService.plainText(from: html)
                link.updatedAt = Date()
                context.saveLogging()
            }
            savingOffline = false
        }
    }
}
