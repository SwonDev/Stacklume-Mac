import SwiftUI
import SwiftData
import AppKit
import CoreSpotlight
import StacklumeCore
import StacklumeDesignSystem
import StacklumeMetadata
import StacklumePersistence

/// Ventana principal: NavigationSplitView de 3 columnas con el tema activo
/// aplicado en vivo (lee `AppSettings.themeID`).
struct RootWindowView: View {
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    /// Para reabrir la ventana principal desde el icono del menubar (el `NSPopover` no puede
    /// usar `openWindow` por su cuenta): se registra como closure en `MenuBarController`.
    @Environment(\.openWindow) private var openWindow
    @Query private var settings: [AppSettings]
    /// Favoritos activos: el widget de escritorio refleja estos. Se observan para
    /// reescribir el snapshot del widget cuando cambian (antes solo se escribía al
    /// arrancar, así que el widget quedaba desactualizado hasta reiniciar la app).
    @Query(filter: #Predicate<Bookmark> { $0.isFavorite && $0.deletedAt == nil && !$0.isArchived },
           sort: \Bookmark.createdAt, order: .reverse)
    private var favoriteLinks: [Bookmark]

    @State private var selection: NavTarget?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    // La app abre directamente en los enlaces («Todos»), no en un dashboard.
    // Selección MÚLTIPLE nativa de macOS (⌘/⇧-clic en la List): un `Set` de ids.
    // La columna de detalle muestra la ficha solo cuando hay exactamente uno
    // seleccionado; con 0 o 2+ muestra el placeholder (la barra de lote opera el resto).
    @State private var selectedLinks: Set<Bookmark.ID>
    @State private var actions = LibraryActions()
    /// Ítem de «Descubrir» seleccionado (se muestra en la columna de detalle).
    @State private var discoverSelection = DiscoverSelection()
    /// Buzón para enviar preguntas al asistente desde otras vistas (p. ej. la ficha).
    @State private var assistantInbox = AssistantInbox()
    @State private var showWelcome = false
    @State private var categoryEditor: CategoryEditorView.Mode?
    /// Paleta de comandos ⌘K (búsqueda global + navegación + acciones), estilo Spotlight.
    @State private var showCommandPalette = false
    /// Estado del drop global de Finder: destino visible, preparación en curso y
    /// feedback transitorio. No roba el foco ni bloquea la navegación por teclado.
    @State private var isDropTargeted = false
    @State private var isImportingDrop = false
    @State private var dropFeedback: DropImportFeedback?
    /// Alto real de la toolbar/titlebar unificada. La barra de cristal se adapta al
    /// chrome de la ventana en vez de asumir una cifra fija.
    @State private var windowHeaderHeight: CGFloat = 52

    // Captura de enlaces desde el portapapeles a nivel de ventana (supera al iPhone):
    // al activarse la app, si hay una URL NUEVA que no esté ya en la biblioteca ni se
    // haya descartado en esta sesión, ofrece añadirla con un banner flotante sutil.
    /// URL `http(s)` sugerida ahora mismo (mostrada en el banner). `nil` = sin banner.
    @State private var clipboardSuggestion: String?
    /// `changeCount` del portapapeles ya procesado: detecta SOLO contenido nuevo.
    @State private var lastPasteboardChangeCount = ClipboardLink.changeCount
    /// URLs descartadas en esta sesión: no se vuelven a sugerir aunque sigan copiadas.
    @State private var dismissedClipboardURLs: Set<String> = []
    /// Feedback breve «Añadido» tras pulsar Añadir, antes de ocultar el banner.
    @State private var clipboardAdded = false
    /// El enlace del portapapeles YA está en la biblioteca: el banner pasa a modo informativo
    /// («Ya está en tu biblioteca · Ver») en vez de callarse, para que no parezca que no detecta.
    @State private var clipboardAlreadySaved = false
    @State private var modelRevision: UInt = 0
    private final class ClipboardLibraryIndex {
        var revision: UInt?
        var idsByCanonicalURL: [String: Bookmark.ID] = [:]
    }
    @State private var clipboardLibraryIndex = ClipboardLibraryIndex()
    private final class FavoritesFingerprintCache {
        var revision: UInt?
        var value = ""
    }
    @State private var favoritesFingerprintCache = FavoritesFingerprintCache()

    /// Acento personalizado elegido por el usuario (hex). Vacío = usa el del tema.
    @AppStorage("stacklume.accentHex") private var accentHex = ""

    init() {
        _selection = State(initialValue: MarketingDemoRuntime.isActive
            ? MarketingDemoRuntime.initialTarget
            : .all)
        _selectedLinks = State(initialValue: MarketingDemoRuntime.isActive
            ? MarketingDemoRuntime.selectedLinkIDs
            : [])
    }

    /// Tema activo resuelto desde los ajustes (por defecto, Oscuro).
    private var theme: Theme {
        if MarketingDemoRuntime.isActive, let override = MarketingDemoRuntime.themeOverride {
            return override
        }
        return Theme(rawValue: settings.first?.themeID ?? "dark") ?? .dark
    }

    /// Paleta del tema activo, con el acento personalizado del usuario si lo hay. La leen
    /// tanto el entorno (todas las vistas) como overlays y la scrollbar de marca.
    private var palette: ThemePalette {
        var p = theme.palette(systemScheme: systemScheme)
        if !accentHex.isEmpty { p.accent = Color(hex: accentHex) }
        return p
    }

    /// Huella de los favoritos que ve el widget (id + título de los 8 primeros): cambia
    /// al añadir/quitar un favorito o editar su título → dispara la reescritura del snapshot.
    private var favoritesFingerprint: String {
        if favoritesFingerprintCache.revision == modelRevision {
            return favoritesFingerprintCache.value
        }
        let value = favoriteLinks.prefix(8)
            .map { "\($0.id.uuidString):\($0.title)" }
            .joined(separator: "|")
        favoritesFingerprintCache.revision = modelRevision
        favoritesFingerprintCache.value = value
        return value
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(
                    min: RootWindowLayoutMetrics.sidebarMinimumWidth,
                    ideal: RootWindowLayoutMetrics.sidebarIdealWidth,
                    max: RootWindowLayoutMetrics.sidebarMaximumWidth
                )
        } content: {
            GeometryReader { viewport in
                SectionContentView(target: selection ?? .all, selectedLinks: $selectedLinks)
                    .frame(width: viewport.size.width, height: viewport.size.height)
            }
                // `max` DURO: en secciones normales la lista no pasa de 720 → el detalle
                // queda ancho. En X se libera para que el navegador ocupe casi todo. Como el
                // 720 es un tope duro, al volver de X la lista se reajusta (sin «recordar»
                // un ancho enorme). El detalle NO se toca aquí (eso causaba el encogido).
                .navigationSplitViewColumnWidth(
                    min: RootWindowLayoutMetrics.libraryMinimumWidth,
                    ideal: RootWindowLayoutMetrics.libraryIdealWidth,
                    max: selection?.usesExpandedWorkspace == true ? 100_000 : RootWindowLayoutMetrics.libraryMaximumWidth
                )
                // Transición muy sutil al cambiar de sección. Fundido CORTO (0,1 s, easeOut)
                // para que la navegación se sienta INSTANTÁNEA: a 0,18 s el contenido tardaba en
                // «solidificarse» y se percibía como retraso/entrecortado al cambiar de colección.
                .id(selection ?? .all)
                .transition(.opacity)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: selection)
        } detail: {
            if selection?.usesExpandedWorkspace == true {
                // Estos espacios tienen inspector propio; conservan el ancho para sus resultados.
                Color.clear.navigationSplitViewColumnWidth(0)
            } else {
                // Mínimo DURO: anula el ancho 0 «recordado» de X, así el detalle nunca
                // aparece encogido al volver a una sección normal.
                DetailColumn(selectedLinks: selectedLinks)
                    .navigationSplitViewColumnWidth(
                        min: RootWindowLayoutMetrics.detailMinimumWidth,
                        ideal: RootWindowLayoutMetrics.detailIdealWidth,
                        max: 100_000
                    )
            }
        }
        // El material de la toolbar del sistema se oculta porque la superficie continua
        // la dibuja Stacklume debajo, igual que Vessel: controles nítidos sobre cristal.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { windowHeaderHeight = max(proxy.safeAreaInsets.top, 1) }
                    .onChange(of: proxy.safeAreaInsets.top) { _, newValue in
                        windowHeaderHeight = max(newValue, 1)
                    }
            }
        }
        .overlay(alignment: .top) {
            StacklumeGlassBackdrop(
                shape: Rectangle(),
                tint: palette.accent,
                tintOpacity: 0.025
            )
            .frame(height: max(windowHeaderHeight, 1))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                palette.border.opacity(0.02),
                                palette.textPrimary.opacity(0.14),
                                palette.border.opacity(0.02)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 1)
            }
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
        // Al cambiar de sección del sidebar, limpia la selección: los ids del
        // destino anterior no tienen sentido en el nuevo (evita una ficha colgada
        // o una barra de lote con elementos que ya no se ven).
        .onChange(of: selection) { oldValue, newValue in
            // Al ir a la sección IA: pasa al asistente el «enlace en contexto» (el seleccionado)
            // y la SECCIÓN que venías viendo (para «¿cuántos hay aquí?», «organiza ESTA
            // colección»…), ANTES de limpiar la selección.
            if newValue == .ai {
                if selectedLinks.count == 1, let id = selectedLinks.first, let link = bookmark(for: id) {
                    assistantInbox.contextLink = LinkContext(link)
                }
                assistantInbox.activeSection = sectionDisplayName(oldValue)
            }
            selectedLinks.removeAll()
            discoverSelection.selected = nil   // al cambiar de sección, limpia el detalle de Descubrir
        }
        // Mantén el snapshot del widget al día: al añadir/quitar un favorito o cambiar su
        // título, reescribe el fichero que lee el widget (no basta con recargar el timeline).
        .onChange(of: favoritesFingerprint) { _, _ in
            WidgetSnapshotWriter.write(from: context)
        }
        // Inyecta la paleta (con el acento personalizado) en el entorno; las hojas
        // presentadas desde aquí lo heredan. Equivale a `stacklumeTheme` pero respetando
        // el acento elegido por el usuario.
        .environment(\.themePalette, palette)
        .environment(\.appTheme, theme)
        // Tooltips temáticos (estilo Stacklume según el tema) en toda la ventana, en vez del
        // tooltip gris del sistema. Una única capa dibuja el bocadillo activo por encima de todo.
        .tooltipLayer(palette)
        // Motor de traducción AUTOMÁTICA de textos extranjeros (sobre todo títulos en chino/
        // japonés/árabe…): el framework Translation de Apple exige una sesión de VISTA, así que
        // vive aquí, montado de forma permanente, y traduce en cuanto se añade un enlace.
        .autoTranslateForeignText()
        // Tematiza la barra de título de la ventana (antes gris del sistema): titlebar
        // transparente + fondo navy del tema, para que se integre con la app. Reactivo al tema.
        .background(WindowChrome(background: palette.background))
        .tint(palette.accent)
        .preferredColorScheme(theme.preferredColorScheme)
        // La scrollbar de marca (GoldenScroller) se pinta fuera de SwiftUI (AppKit),
        // así que le pasamos el acento (con override) al aparecer y cuando cambia.
        .onAppear {
            MultimodalSearchService.shared.attach(context: context)
            ScrollerTint.setAccent(NSColor(palette.accent))
            // El menubar reabre la ventana con este closure (captura un `openWindow` válido).
            MenuBarController.shared.openMainWindow = { openWindow(id: StacklumeWindowID.main) }
        }
        .onChange(of: theme) { _, _ in ScrollerTint.setAccent(NSColor(palette.accent)) }
        .onChange(of: accentHex) { _, _ in ScrollerTint.setAccent(NSColor(palette.accent)) }
        // Guardado de la copia sin conexión EN AUTOMÁTICO (opt-in, desactivado por
        // defecto en Ajustes › Datos). Vive en la VENTANA (lifecycle estable), no en la
        // lista: así las descargas de red no se cancelan al navegar entre secciones. Una
        // pasada al abrir y luego cada minuto; cada pasada guarda unos pocos enlaces.
        .task(priority: .background) {
            while !Task.isCancelled {
                await OfflineAutoSaver.runIfNeeded(in: context)
                try? await Task.sleep(for: .seconds(60))
            }
        }
        // AppKit restaura el ancho previo de los divisores. El contrato reserva el
        // sidebar a su MÁXIMO junto a los mínimos de biblioteca y detalle, evitando
        // que un panel persistido se desplace fuera del borde izquierdo.
        .frame(minWidth: RootWindowLayoutMetrics.minimumWindowWidth, minHeight: 620)
        .environment(actions)
        .environment(discoverSelection)
        .environment(assistantInbox)
        // Capa del preview emergente a nivel de VENTANA (sin `.popover`): así no consume el primer
        // clic al cerrarse y navegar con un preview abierto ya no exige clicar dos veces.
        .linkPreviewLayer()
        .sheet(item: Binding(get: { actions.editorTarget }, set: { actions.editorTarget = $0 })) { target in
            LinkEditorView(target: target).themedSheet(palette, theme)
        }
        .sheet(item: $categoryEditor) { CategoryEditorView(mode: $0).themedSheet(palette, theme) }
        .sheet(item: Binding(get: { actions.quickLookTarget }, set: { actions.quickLookTarget = $0 })) { target in
            InAppBrowserSheet(url: target.url, offlineHTML: target.offlineHTML).themedSheet(palette, theme)
        }
        .modifier(UndoRedoCommands(context: context))
        .modifier(PasteLinksHandler(context: context))
        .modifier(OpenBrowserTabsHandler(palette: palette, theme: theme))
        .onReceive(NotificationCenter.default.publisher(for: .stacklumeNewLink)) { _ in
            actions.newLink()
        }
        .modifier(ModelRevisionObserver(revision: $modelRevision))
        // La sección X pide re-comprobar el portapapeles al detectar una copia nueva (p. ej.
        // «Copiar enlace» del WebView): muestra el banner «Añadir» con el enlace externo copiado.
        .onReceive(NotificationCenter.default.publisher(for: .stacklumeCheckClipboard)) { _ in
            refreshClipboardSuggestion()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stacklumeNewCollection)) { _ in
            categoryEditor = .create
        }
        .onReceive(NotificationCenter.default.publisher(for: .stacklumeGoToSection)) { note in
            if let key = note.object as? String, let target = NavTarget(key: key) { selection = target }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stacklumeOpenCommandPalette)) { _ in
            // Si ya está abierta, ⌘K la cierra (comportamiento esperado de un toggle).
            withAnimation(paletteAnimation) { showCommandPalette.toggle() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stacklumeSetTheme)) { note in
            if let id = note.object as? String {
                let s = AppSettingsStore.current(in: context)
                s.themeID = id
                context.saveLogging()
            }
        }
        // Acciones de menú «Enlace» sobre la selección. Modifier separado para aliviar el type-checker.
        .modifier(LinkCommandHandlers(selectedLinks: $selectedLinks, context: context, openURL: openURL, actions: actions))
        // Tasks de inicio, hojas, drop, deep link, overlays y portapapeles.
        .modifier(RootWindowTasks(
            context: context,
            palette: palette,
            theme: theme,
            showWelcome: $showWelcome,
            isDropTargeted: $isDropTargeted,
            clipboardBanner: clipboardBanner,
            commandPaletteOverlay: commandPaletteOverlay,
            dropImportOverlay: dropImportOverlay,
            ensureWelcomeState: ensureWelcomeState,
            importDroppedContent: importDroppedContent,
            handleDeepLink: handleDeepLink,
            handleSpotlightActivity: handleSpotlightActivity,
            refreshClipboardSuggestion: refreshClipboardSuggestion
        ))
    }

    // MARK: - Paleta de comandos ⌘K (nivel de ventana)

    /// Animación de entrada/salida de la paleta, respetando Reduce Motion (sin
    /// movimiento si está activo: aparece/desaparece sin transición).
    private var paletteAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86)
    }

    /// Resuelve un `Bookmark` activo por su id (para fijar el «enlace en contexto» del
    /// asistente al navegar a la sección IA con un enlace seleccionado).
    private func bookmark(for id: Bookmark.ID) -> Bookmark? {
        let selectedID = id
        var descriptor = FetchDescriptor<Bookmark>(
            predicate: #Predicate { $0.id == selectedID && $0.deletedAt == nil })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Nombre legible de una sección (para dar al asistente la sección que el usuario venía
    /// viendo). Resuelve colección/etiqueta/proyecto por su id. `nil` si no aporta contexto.
    private func sectionDisplayName(_ target: NavTarget?) -> String? {
        guard let target else { return nil }
        switch target {
        case .all: return "Todos"
        case .inbox: return "Bandeja"
        case .unsorted: return "Sin clasificar"
        case .favorites: return "Favoritos"
        case .readingQueue: return "Cola de lectura"
        case .highlights: return "Resaltados"
        case .connections: return "Conexiones"
        case .discover: return "Descubrir"
        case .huggingFace: return "Hugging Face"
        case .civitai: return "Civitai"
        case .x: return "X"
        case .sessions: return "Sesiones"
        case .projects: return "Proyectos"
        case .rules: return "Reglas"
        case .stats: return "Estadísticas"
        case .trash: return "Papelera"
        case .ai: return nil   // ya está en el chat: no aporta
        case .savedSearch: return "una búsqueda guardada"
        case .smart: return nil
        case .collection(let id):
            let selectedID = id
            var descriptor = FetchDescriptor<BookmarkCategory>(predicate: #Predicate {
                $0.id == selectedID && $0.deletedAt == nil
            })
            descriptor.fetchLimit = 1
            let name = try? context.fetch(descriptor).first?.name
            return name.map { "la colección «\($0)»" }
        case .tag(let id):
            let selectedID = id
            var descriptor = FetchDescriptor<Tag>(predicate: #Predicate {
                $0.id == selectedID && $0.deletedAt == nil
            })
            descriptor.fetchLimit = 1
            let name = try? context.fetch(descriptor).first?.name
            return name.map { "la etiqueta «\($0)»" }
        case .project(let id):
            let selectedID = id
            var descriptor = FetchDescriptor<Project>(predicate: #Predicate {
                $0.id == selectedID && $0.deletedAt == nil
            })
            descriptor.fetchLimit = 1
            let name = try? context.fetch(descriptor).first?.name
            return name.map { "el proyecto «\($0)»" }
        }
    }

    /// Backdrop oscurecido + panel flotante centrado-arriba. El clic en el fondo cierra.
    @ViewBuilder
    private var commandPaletteOverlay: some View {
        if showCommandPalette {
            ZStack(alignment: .top) {
                // Fondo que oscurece y cierra al hacer clic.
                Rectangle()
                    .fill(Color.black.opacity(0.32))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { closeCommandPalette() }
                    .transition(.opacity)

                CommandPaletteView(
                    selection: $selection,
                    selectedLinks: $selectedLinks,
                    onClose: closeCommandPalette
                )
                .padding(.top, 96)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .top).combined(with: .opacity)
                )
            }
            .animation(paletteAnimation, value: showCommandPalette)
        }
    }

    /// Cierra la paleta con la animación adecuada.
    private func closeCommandPalette() {
        withAnimation(paletteAnimation) { showCommandPalette = false }
    }

    // MARK: - Banner de sugerencia del portapapeles (nivel de ventana)

    @ViewBuilder
    private var clipboardBanner: some View {
        if let suggestion = clipboardSuggestion {
            let command = CommandDetector.detect(suggestion)
            HStack(spacing: DesignSystem.Spacing.sm) {
                if let command {
                    Image(systemName: "terminal.fill")
                        .font(.title3)
                        .foregroundStyle(Color(hex: command.colorHex))
                        .frame(width: 30, height: 30)
                        .background(Color(hex: command.colorHex).opacity(0.16),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    SecureRemoteImage(candidates: [faviconURL(for: suggestion)]) {
                        Image(systemName: "doc.on.clipboard.fill")
                            .font(.title3)
                            .foregroundStyle(palette.accent)
                            .frame(width: 30, height: 30)
                            .background(palette.accent.opacity(0.16),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(clipboardAdded ? "Añadido"
                         : clipboardAlreadySaved ? "Ya está en tu biblioteca"
                         : (command != nil ? "Comando \(command!.manager) en el portapapeles"
                                           : "Enlace en el portapapeles"))
                        .stacklumeFont(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.textPrimary)
                    Text(command?.command ?? suggestion.urlHost)
                        .stacklumeFont(command != nil ? .system(.caption2, design: .monospaced) : .caption2)
                        .foregroundStyle(palette.textSecondary)
                        .stacklumeLineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: DesignSystem.Spacing.md)

                if clipboardAdded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color(hex: "#22C55E"))
                } else if clipboardAlreadySaved {
                    // Ya guardado: informar y ofrecer ir a él (no «Añadir», sería un duplicado).
                    Button("Descartar") { dismissClipboardSuggestion(suggestion) }
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.textSecondary)
                    Button("Ver") { revealExistingLink(suggestion) }
                        .buttonStyle(.borderedProminent)
                        .tint(palette.accent)
                } else {
                    Button("Descartar") { dismissClipboardSuggestion(suggestion) }
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.textSecondary)
                    Button("Añadir") { addClipboardSuggestion(suggestion) }
                        .buttonStyle(.borderedProminent)
                        .tint(palette.accent)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.border.opacity(0.6), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            .frame(maxWidth: 460)
            .padding(.top, DesignSystem.Spacing.sm)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Overlay funcional del drop: zona inequívoca mientras el cursor arrastra y HUD
    /// accesible mientras se prepara o al terminar. Usa los tokens de `DESIGN.md`.
    private var dropImportOverlay: some View {
        DropImportOverlay(
            isTargeted: isDropTargeted,
            isImporting: isImportingDrop,
            feedback: dropFeedback,
            palette: palette
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isDropTargeted)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isImportingDrop)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: dropFeedback?.id)
        .allowsHitTesting(false)
    }

    /// Favicon del dominio sugerido (best-effort) para el banner. `sz=256` para que
    /// se vea nítido en pantallas Retina (a `sz=64` salía borroso).
    private func faviconURL(for urlString: String) -> String {
        "https://www.google.com/s2/favicons?domain=\(urlString.urlHost)&sz=256"
    }

    /// Comprueba el portapapeles al activarse la app y, si trae una URL `http(s)` NUEVA
    /// (changeCount nuevo), que no esté ya en la biblioteca ni descartada en la sesión,
    /// muestra el banner. No molesta si no hay URL.
    private func refreshClipboardSuggestion() {
        guard !MarketingDemoRuntime.isActive else { return }
        // No dupliques el banner de ventana con el del editor: si hay un editor
        // abierto (o el onboarding), deja que el editor gestione el portapapeles.
        guard actions.editorTarget == nil, !showWelcome else { return }
        let change = ClipboardLink.changeCount
        // Solo contenido NUEVO: si no cambió desde la última vez, no reproceses.
        guard change != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = change
        guard let candidate = ClipboardLink.currentSaveable() else { return }
        guard !dismissedClipboardURLs.contains(candidate) else { return }
        // Si YA está en la biblioteca, NO se calla: muestra un banner informativo («Ya está… ·
        // Ver»). Antes simplemente no aparecía → parecía que no detectaba el portapapeles.
        let already = isInLibrary(candidate)
        withAnimation(.snappy) {
            clipboardAdded = false
            clipboardAlreadySaved = already
            clipboardSuggestion = candidate
        }
        // El banner informativo de «ya guardado» se oculta solo a los pocos segundos.
        if already {
            let shown = candidate
            Task {
                try? await Task.sleep(for: .seconds(5))
                if clipboardSuggestion == shown, clipboardAlreadySaved {
                    withAnimation(.snappy) { clipboardSuggestion = nil }
                }
            }
        }
    }

    /// Selecciona el enlace YA guardado que coincide con la URL del portapapeles, para que el
    /// usuario lo VEA (y pueda editarlo o borrarlo). Cambia a «Todos» y lo selecciona.
    private func revealExistingLink(_ input: String) {
        if let id = existingBookmarkID(for: input) { revealBookmark(id) }
        dismissedClipboardURLs.insert(input)
        withAnimation(.snappy) { clipboardSuggestion = nil }
    }

    /// ¿Ya está en la biblioteca (no en papelera)? Compara por clave EXACTA
    /// ([[CanonicalURL]]): solo es duplicado el MISMO enlace (normaliza únicamente
    /// host/esquema a minúsculas y la barra final; query/fragmento/www se respetan). Si es
    /// un comando, se compara por la página del registro a la que apunta.
    private func isInLibrary(_ input: String) -> Bool {
        existingBookmarkID(for: input) != nil
    }

    /// Índice canónico perezoso para el detector de portapapeles. Copiar varias URLs o
    /// reactivar la app ya no ejecuta un fetch + canonicalización de toda la biblioteca
    /// cada vez; el índice solo se reconstruye después de un guardado real.
    private func existingBookmarkID(for input: String) -> Bookmark.ID? {
        let effective = CommandDetector.detect(input)?.registryURL ?? input
        let key = CanonicalURL.key(effective)
        if clipboardLibraryIndex.revision != modelRevision {
            let active = (try? context.fetch(FetchDescriptor<Bookmark>(
                predicate: #Predicate { $0.deletedAt == nil }))) ?? []
            clipboardLibraryIndex.idsByCanonicalURL = Dictionary(
                active.map { (CanonicalURL.key($0.url), $0.id) },
                uniquingKeysWith: { first, _ in first }
            )
            clipboardLibraryIndex.revision = modelRevision
        }
        return clipboardLibraryIndex.idsByCanonicalURL[key]
    }


    /// Añade la URL sugerida con el camino unificado (`LinkIngest`, con IA) y muestra un
    /// breve «Añadido» antes de ocultar el banner. Se autocategoriza/etiqueta/traduce en
    /// segundo plano (lo gestiona `LinkIngest`).
    private func addClipboardSuggestion(_ urlString: String) {
        LinkIngest.ingestLink(urlString: urlString, in: context, aiEnrich: true)
        dismissedClipboardURLs.insert(urlString)   // no re-sugerir esta misma URL
        withAnimation(.snappy) { clipboardAdded = true }
        Task {
            try? await Task.sleep(for: .seconds(1.1))
            withAnimation(.snappy) { clipboardSuggestion = nil }
        }
    }

    /// Descarta la sugerencia: no se vuelve a mostrar para esta URL en la sesión.
    private func dismissClipboardSuggestion(_ urlString: String) {
        dismissedClipboardURLs.insert(urlString)
        withAnimation(.snappy) { clipboardSuggestion = nil }
    }

    /// Procesa únicamente las rutas cerradas de `StacklumeRoute`: alta desde Share
    /// Extension, secciones, favoritos del widget y selección exacta de un marcador.
    private func handleDeepLink(_ url: URL) {
        guard let route = StacklumeRoute.parse(url) else { return }
        switch route {
        case .add(let webURL):
            LinkIngest.ingestLink(urlString: webURL.absoluteString, in: context, aiEnrich: true)
        case .bookmark(let id):
            revealBookmark(id)
        case .section(let key):
            if let target = NavTarget(key: key) { selection = target }
        case .favorites:
            selection = .favorites
        }
    }

    /// Spotlight entrega el UUID indexado mediante esta actividad. Se resuelve contra
    /// SwiftData y se selecciona el elemento exacto, no solo se abre la app genéricamente.
    private func handleSpotlightActivity(_ activity: NSUserActivity) {
        guard let rawID = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let id = UUID(uuidString: rawID) else { return }
        revealBookmark(id)
    }

    /// Cambiar de sección limpia la selección mediante `onChange`; por eso, si hace
    /// falta ir a «Todos», la selección exacta se aplica tras ceder un ciclo al render.
    private func revealBookmark(_ id: Bookmark.ID) {
        guard bookmark(for: id) != nil else { return }
        if selection == .all {
            selectedLinks = [id]
        } else {
            selection = .all
            Task { @MainActor in
                await Task.yield()
                guard bookmark(for: id) != nil else { return }
                selectedLinks = [id]
            }
        }
    }

    private func ensureWelcomeState() {
        let s = AppSettingsStore.current(in: context)   // crea el singleton si no existe
        context.saveLogging()
        showWelcome = (s.onboardingCompleted == false)
    }

    /// Importa de una sola vez URLs, `.webloc`, `.url`, PDF, EPUB e imágenes. El disco y la
    /// validación pesada viven fuera del actor principal; SwiftData permanece aislado.
    private func importDroppedContent(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard !isImportingDrop else {
            showDropFeedback("Ya hay una importación en curso.", isError: true)
            return
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            isImportingDrop = true
            dropFeedback = nil
        }

        Task { @MainActor in
            let prepared = await DroppedContentImporter.prepare(urls)
            let linkResult = LinkIngest.ingestLinks(
                prepared.webURLs.map { .init(urlString: $0.absoluteString) },
                in: context,
                category: nil,
                aiEnrich: true
            )
            let documentResult = LocalDocumentIngest.ingest(prepared.documents, in: context)
            let added = linkResult.added + documentResult.added
            let skipped = linkResult.skipped.count + documentResult.skippedCount
            let rejected = prepared.rejections.count + prepared.omittedItemCount

            isImportingDrop = false
            if let first = added.first { revealBookmark(first.id) }

            let message: String
            if !added.isEmpty {
                var parts = ["Importados \(added.count) elemento(s)"]
                if skipped > 0 { parts.append("\(skipped) ya estaban guardados") }
                if rejected > 0 { parts.append("\(rejected) no se pudieron importar") }
                message = parts.joined(separator: " · ") + "."
            } else if skipped > 0, rejected == 0 {
                message = "Todo estaba ya guardado; no se crearon duplicados."
            } else if let firstRejection = prepared.rejections.first {
                message = "No se pudo importar «\(firstRejection.name)»: \(firstRejection.reason)."
            } else if prepared.omittedItemCount > 0 {
                message = "El lote supera el máximo de \(DroppedContentImporter.maximumItemCount) elementos."
            } else {
                message = "No había enlaces, PDF, EPUB o imágenes compatibles."
            }
            showDropFeedback(message, isError: added.isEmpty && skipped == 0)
        }
    }

    private func showDropFeedback(_ message: String, isError: Bool) {
        let feedback = DropImportFeedback(message: message, isError: isError)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            dropFeedback = feedback
        }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: (isError
                    ? NSAccessibilityPriorityLevel.high
                    : .medium).rawValue,
            ]
        )
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard dropFeedback?.id == feedback.id else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                dropFeedback = nil
            }
        }
    }
}

private struct DropImportFeedback: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let isError: Bool
}

/// Capa funcional transitoria para arrastrar y soltar. El panel central usa cristal
/// porque es un control/HUD, mientras el velo conserva el navy del contenido.
private struct DropImportOverlay: View {
    let isTargeted: Bool
    let isImporting: Bool
    let feedback: DropImportFeedback?
    let palette: ThemePalette

    var body: some View {
        ZStack {
            if isTargeted {
                Rectangle()
                    .fill(palette.background.opacity(0.82))
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                VStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.largeTitle)
                        .foregroundStyle(palette.accent)
                    Text("Suelta para importar")
                        .stacklumeFont(.title2.weight(.bold))
                        .foregroundStyle(palette.textPrimary)
                    Text("Enlaces, .webloc, PDF, EPUB o imágenes · hasta 64 MB por archivo")
                        .stacklumeFont(.subheadline)
                        .foregroundStyle(palette.textSecondary)
                }
                .multilineTextAlignment(.center)
                .padding(DesignSystem.Spacing.lg)
                .background(
                    palette.background.opacity(0.36),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .stacklumeGlass(
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(palette.accent.opacity(0.34), lineWidth: 0.75)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "Suelta para importar enlaces, accesos directos, PDF, EPUB o imágenes"
                )
                .transition(.opacity)
            }

            if isImporting || feedback != nil {
                VStack {
                    Spacer()
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        if isImporting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(palette.accent)
                            Text("Preparando importación…")
                        } else if let feedback {
                            Image(systemName: feedback.isError
                                  ? "exclamationmark.triangle.fill"
                                  : "checkmark.circle.fill")
                                .foregroundStyle(palette.accent)
                            Text(feedback.message)
                                .stacklumeLineLimit(2)
                        }
                    }
                    .stacklumeFont(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.textPrimary)
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, DesignSystem.Spacing.sm)
                    .frame(maxWidth: 620)
                    .background(palette.background.opacity(0.34), in: Capsule(style: .continuous))
                    .stacklumeGlass(in: Capsule(style: .continuous))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(isImporting
                                        ? "Preparando importación"
                                        : feedback?.message ?? "")
                    .padding(.bottom, DesignSystem.Spacing.lg)
                }
                .transition(.opacity)
            }
        }
    }
}

/// Mantiene fuera del `body` principal la suscripción de revisión del modelo; además de
/// simplificar el type-checker, deja explícito que esta señal no altera la presentación.
private struct ModelRevisionObserver: ViewModifier {
    @Binding var revision: UInt

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .stacklumeModelDidSave)) { _ in
            revision &+= 1
        }
    }
}

/// Resuelve el enlace seleccionado y muestra su ficha. Con selección MÚLTIPLE solo
/// tiene sentido una ficha: se muestra cuando hay exactamente un enlace seleccionado;
/// con 0 o 2+ se muestra el placeholder (las acciones de varios viven en la barra de
/// lote de la columna central).
private struct DetailColumn: View {
    let selectedLinks: Set<Bookmark.ID>
    @Environment(DiscoverSelection.self) private var discoverSelection: DiscoverSelection?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Fundido suave (premium, como Raindrop) al pasar de un enlace/ítem a otro. La
        // identidad por `contentKey` hace que SwiftUI trate cada ficha como distinta y
        // aplique la transición; Reduce Motion la desactiva.
        content
            .id(contentKey)
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: contentKey)
    }

    /// Clave estable del contenido actual (ítem de Descubrir / enlace / vacío).
    private var contentKey: String {
        if let item = discoverSelection?.selected { return "discover:\(item.id)" }
        if selectedLinks.count == 1, let id = selectedLinks.first { return "link:\(id.uuidString)" }
        return "empty"
    }

    @ViewBuilder
    private var content: some View {
        // Prioridad: ítem de Descubrir (solo se fija en esa sección) → enlace único → vacío.
        if let item = discoverSelection?.selected {
            DiscoverItemDetailView(item: item)
        } else if selectedLinks.count == 1, let id = selectedLinks.first {
            SelectedBookmarkDetail(id: id)
        } else {
            DetailPlaceholderView()
        }
    }
}

/// Consulta exclusivamente el enlace de la ficha visible. La implementación anterior tenía
/// un `@Query [Bookmark]` sin filtro en la tercera columna: materializaba y observaba toda la
/// biblioteca incluso con el detalle vacío. Esta consulta acotada mantiene la reactividad de
/// SwiftData y el fundido del panel, pero su coste no crece con el total de enlaces.
private struct SelectedBookmarkDetail: View {
    @Query private var links: [Bookmark]

    init(id: Bookmark.ID) {
        let selectedID = id
        _links = Query(filter: #Predicate<Bookmark> {
            $0.id == selectedID && $0.deletedAt == nil
        })
    }

    var body: some View {
        if let link = links.first {
            LinkDetailView(link: link)
        } else {
            DetailPlaceholderView()
        }
    }
}

/// Deshacer/Rehacer del modelo (⌘Z/⇧⌘Z cuando el foco no es un campo de texto). En un
/// `ViewModifier` aparte para no sobrecargar el type-checker del `body` de `RootWindowView`.
private struct UndoRedoCommands: ViewModifier {
    let context: ModelContext
    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .stacklumeUndo)) { _ in
                context.undoManager?.undo()
                context.saveLogging("Deshacer")
            }
            .onReceive(NotificationCenter.default.publisher(for: .stacklumeRedo)) { _ in
                context.undoManager?.redo()
                context.saveLogging("Rehacer")
            }
    }
}

/// «Pegar enlaces» (⌘⇧V): guarda todas las URLs/comandos del portapapeles (una por línea).
/// Si hay varias, pide confirmación. En un `ViewModifier` aparte (type-checker del body).
private struct PasteLinksHandler: ViewModifier {
    let context: ModelContext
    @State private var pending: [String] = []
    @State private var showConfirm = false

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .stacklumePasteLinks)) { _ in
                let urls = ClipboardLink.allSaveable()
                if urls.count <= 1 {
                    if let one = urls.first { LinkIngest.ingestLink(urlString: one, in: context, aiEnrich: true) }
                } else {
                    pending = urls
                    showConfirm = true
                }
            }
            .confirmationDialog("¿Guardar \(pending.count) enlaces del portapapeles?",
                                isPresented: $showConfirm, titleVisibility: .visible) {
                Button("Guardar \(pending.count)") {
                    LinkIngest.ingestLinks(
                        pending.map { LinkIngest.IngestItem(urlString: $0) },
                        in: context,
                        category: nil,
                        aiEnrich: true
                    )
                    pending = []
                }
                Button("Cancelar", role: .cancel) { pending = [] }
            }
    }
}

/// Maneja las acciones del menú «Enlace» (Favorito ⌘D, Mover a la papelera ⌘⌫, Abrir
/// original ⌘O) sobre la selección actual. Vive en un `ViewModifier` aparte para no
/// sobrecargar el type-checker del `body` de `RootWindowView`.
private struct LinkCommandHandlers: ViewModifier {
    @Binding var selectedLinks: Set<Bookmark.ID>
    let context: ModelContext
    let openURL: OpenURLAction
    let actions: LibraryActions

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .stacklumeFavoriteSelected)) { _ in
                for link in selectedBookmarks() { BookmarkActions.toggleFavorite(link, in: context) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .stacklumeTrashSelected)) { _ in
                let items = selectedBookmarks()
                guard !items.isEmpty else { return }
                for link in items { BookmarkActions.moveToTrash(link, in: context) }
                selectedLinks.removeAll()
            }
            .onReceive(NotificationCenter.default.publisher(for: .stacklumeOpenSelected)) { _ in
                guard selectedLinks.count == 1, let link = selectedBookmarks().first,
                      let url = StacklumeAutomationPolicy.openableStoredURL(link.url) else { return }
                openURL(url)
            }
            .onReceive(NotificationCenter.default.publisher(for: .stacklumeQuickLookSelected)) { _ in
                guard selectedLinks.count == 1, let link = selectedBookmarks().first,
                      let url = StacklumeAutomationPolicy.openableStoredURL(link.url) else { return }
                actions.quickLook(url, offlineHTML: link.offlineHTML)
            }
            .onReceive(NotificationCenter.default.publisher(for: .stacklumeCopySelected)) { _ in
                let urls = selectedBookmarks().map(\.url)
                guard !urls.isEmpty else { return }
                NSPasteboard.copyString(urls.joined(separator: "\n"))
            }
            .onReceive(NotificationCenter.default.publisher(for: .stacklumeCopyMarkdownSelected)) { _ in
                let items = selectedBookmarks()
                guard !items.isEmpty else { return }
                let md = items.map { link -> String in
                    let title = link.title.isEmpty ? (link.url.urlHost) : link.title
                    return "[\(title)](\(link.url))"
                }.joined(separator: "\n")
                NSPasteboard.copyString(md)
            }
            .onReceive(NotificationCenter.default.publisher(for: .stacklumeEditSelected)) { _ in
                guard selectedLinks.count == 1, let link = selectedBookmarks().first else { return }
                actions.edit(link)
            }
            .onReceive(NotificationCenter.default.publisher(for: .stacklumeToggleReadSelected)) { _ in
                let items = selectedBookmarks()
                guard !items.isEmpty else { return }
                for link in items { BookmarkActions.toggleRead(link, in: context) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .stacklumeArchiveSelected)) { _ in
                let items = selectedBookmarks()
                guard !items.isEmpty else { return }
                for link in items { BookmarkActions.toggleArchive(link, in: context) }
            }
    }

    /// Resuelve los `Bookmark` activos seleccionados ahora mismo (filtra en memoria por
    /// la `Set<Bookmark.ID>` de la selección).
    private func selectedBookmarks() -> [Bookmark] {
        guard !selectedLinks.isEmpty else { return [] }
        // El camino habitual de los comandos de menú es una sola selección: consulta
        // únicamente ese registro en vez de traer toda la biblioteca para filtrarla.
        if selectedLinks.count == 1, let selectedID = selectedLinks.first {
            var descriptor = FetchDescriptor<Bookmark>(predicate: #Predicate {
                $0.id == selectedID && $0.deletedAt == nil
            })
            descriptor.fetchLimit = 1
            return (try? context.fetch(descriptor)).map { Array($0.prefix(1)) } ?? []
        }
        let active = (try? context.fetch(
            FetchDescriptor<Bookmark>(predicate: #Predicate { $0.deletedAt == nil }))) ?? []
        return active.filter { selectedLinks.contains($0.id) }
    }
}

/// Tasks de inicio, hojas de bienvenida, drop de URLs, deep links, overlays del banner
/// y la paleta de comandos, y recarga del portapapeles. Extraídos en un `ViewModifier`
/// aparte para mantener el `body` de `RootWindowView` dentro del límite del type-checker.
private struct RootWindowTasks<ClipboardBanner: View, PaletteOverlay: View, DropOverlay: View>: ViewModifier {
    let context: ModelContext
    let palette: ThemePalette
    let theme: Theme
    @Binding var showWelcome: Bool
    @Binding var isDropTargeted: Bool
    let clipboardBanner: ClipboardBanner
    let commandPaletteOverlay: PaletteOverlay
    let dropImportOverlay: DropOverlay
    let ensureWelcomeState: () -> Void
    let importDroppedContent: ([URL]) -> Void
    let handleDeepLink: (URL) -> Void
    let handleSpotlightActivity: (NSUserActivity) -> Void
    let refreshClipboardSuggestion: () -> Void

    func body(content: Content) -> some View {
        content
            // Reindexar Spotlight se DIFIERE y corre a QoS `.background` (núcleos de eficiencia,
            // cede a la UI). Además `reindexAll` se autodescarta si la biblioteca no cambió.
            .task(priority: .background) {
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled else { return }
                SpotlightIndexer.reindexAll(in: context)
            }
            .task(priority: .background) { WidgetSnapshotWriter.write(from: context) }
            // Autolimpieza: funde los duplicados por URL canónica al arrancar (sin perder
            // datos, restaurable). DIFERIDA y en `.background`: es O(n); no urge ni debe competir.
            .task(priority: .background) {
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                // Sin registro de undo: una auto-reparación no debe quedar en la pila de ⌘Z.
                context.undoManager?.disableUndoRegistration()
                _ = DuplicateCleaner.autoMergeURLDuplicates(in: context)
                context.undoManager?.enableUndoRegistration()
            }
            // Funde colecciones y etiquetas equivalentes (p. ej. «Development»→«Desarrollo»,
            // «videojuego»→«videojuegos») que pudieron crearse antes; mueve sus enlaces a la
            // original. DIFERIDA y en `.background` (O(n), no urge al abrir).
            // RECUPERACIÓN ANTE DESASTRE (INMEDIATA, antes que todo lo demás): si la biblioteca está
            // VACÍA pero hay una copia de seguridad reciente con enlaces (p. ej. tras un crash que dejó
            // el store inservible), restaura la última copia al instante. [[BackupRecovery]].
            .task {
                _ = BackupRecovery.restoreIfEmpty(in: context)
            }
            .task(priority: .background) {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                // La fusión reescribe muchos enlaces (mover de colección/etiqueta) → invalidaría la
                // lista. No la hagas en pleno scroll: espera a una pausa de la interacción.
                await UserActivityMonitor.shared.waitUntilIdle()
                guard !Task.isCancelled else { return }
                context.undoManager?.disableUndoRegistration()
                _ = CollectionMerger.mergeDuplicates(in: context)
                _ = EntityResolver.mergeDuplicateTags(in: context)
                // Vacía de la papelera lo que lleva >30 días (no debe crecer sin límite).
                _ = TrashRetention.purgeOld(in: context)
                if let surviving = try? context.fetch(FetchDescriptor<Bookmark>()) {
                    XPostDraftStore.prune(keeping: Set(surviving.map(\.id)))
                }
                context.undoManager?.enableUndoRegistration()
                // Purga notas de resaltados huérfanas (sus resaltados ya no existen).
                let ids = Set(((try? context.fetch(FetchDescriptor<Highlight>())) ?? []).map(\.id))
                HighlightNoteStore.prune(keeping: ids)
                // Purga del libro mayor de enriquecido los ids de enlaces ya borrados. Solo si ha
                // derivado mucho (evita un fetch completo en cada arranque a gran escala).
                let liveLinks = (try? context.fetchCount(FetchDescriptor<Bookmark>(
                    predicate: #Predicate<Bookmark> { $0.deletedAt == nil }))) ?? 0
                if EnrichmentLedger.shouldPrune(liveCount: liveLinks) {
                    let linkIDs = Set(((try? context.fetch(FetchDescriptor<Bookmark>())) ?? []).map(\.id))
                    EnrichmentLedger.prune(keeping: linkIDs)
                }
                // Backup automático (cada 3 días, tras la limpieza, conserva los últimos 7).
                AutoBackup.runIfNeeded(in: context)
            }
            // Copia de seguridad DIARIA a la hora elegida (sobrescribe la anterior). Comprueba al
            // arrancar y cada 20 min mientras la app vive: si ya pasó la hora de hoy y no se hizo, la
            // hace. Red de seguridad extra ([[DailyBackup]]) para no volver a perder datos por un crash.
            .task {
                while !Task.isCancelled {
                    DailyBackup.runIfDue(in: context)
                    try? await Task.sleep(for: .seconds(1200))
                }
            }
            .task { ensureWelcomeState() }
            // MIGRACIÓN puntual (one-shot): re-habilita en el libro mayor de IA los enlaces cuya
            // DESCRIPCIÓN se quedó en otro idioma por el bug del gate (la IA nunca miraba el idioma,
            // así que un enlace con `og:description` en inglés ya marcado «intentado» no se volvía a
            // tocar). Quitándoles la marca, el barrido de fondo de aquí abajo los re-traduce UNA vez.
            // Corre ANTES (menos espera) para que el barrido ya los vea como pendientes este arranque.
            // Gated por flag → solo se ejecuta una vez por instalación; barato (lookup O(1) por enlace).
            .task(priority: .background) {
                let flag = "stacklume.migration.retranslateForeign.v1"
                guard !UserDefaults.standard.bool(forKey: flag) else { return }
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                let all = (try? context.fetch(FetchDescriptor<Bookmark>(
                    predicate: #Predicate<Bookmark> { $0.deletedAt == nil }))) ?? []
                for link in all where EnrichmentLedger.hasAIAttempt(link.id)
                    && LinkTranslator.isForeignDescription((link.details ?? "")) {
                    EnrichmentLedger.clearAIAttempt(link.id)
                }
                UserDefaults.standard.set(true, forKey: flag)
            }
            // Migración one-shot: corrige RETROACTIVAMENTE la colección de los enlaces de dominios
            // con regla DETERMINISTA ([[DomainCategoryRules]]) que quedaron mal clasificados por la
            // IA (p. ej. modelos de huggingface.co metidos en «Videojuegos» → su colección «IA»/
            // «LLM»). Conservador: solo toca dominios inequívocos de la tabla y solo si la colección
            // actual NO coincide ya canónicamente con la correcta.
            .task(priority: .background) {
                let flag = "stacklume.migration.domainCategory.v1"
                guard !UserDefaults.standard.bool(forKey: flag) else { return }
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                let all = (try? context.fetch(FetchDescriptor<Bookmark>(
                    predicate: #Predicate<Bookmark> { $0.deletedAt == nil }))) ?? []
                var changed = false
                for link in all {
                    guard let name = DomainCategoryRules.categoryName(
                        forURL: link.url, title: link.title, details: link.details) else { continue }
                    let targetKey = CollectionMerger.canonical(name)
                    if let current = link.category, CollectionMerger.canonical(current.name) == targetKey { continue }
                    if let category = EntityResolver.category(name, in: context) {
                        link.category = category
                        LinkIngest.userChangedOrganization(link.id)
                        SpotlightIndexer.index(link)
                        changed = true
                    }
                }
                if changed { context.saveLogging() }
                UserDefaults.standard.set(true, forKey: flag)
            }
            // Barrido de TRADUCCIÓN de títulos extranjeros (chino/japonés/árabe…) de enlaces YA
            // guardados, con la IA LOCAL (sin descargar idiomas de Apple → CERO prompts ni
            // fricción; lo que el usuario pidió). Los títulos NUEVOS los traduce el alta
            // (`enrichOne`); esto recoge los antiguos. Solo si el modelo está EN DISCO (no fuerza
            // descarga) y respeta las pausas de actividad para no entrecortar la UI. Un título
            // traducido deja de ser foráneo y sale del filtro; los que la IA no pueda traducir se
            // marcan para no reintentarse en bucle.
            .task(priority: .background) {
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled,
                      LocalAIRunner.shared.isDownloaded, !LocalAIRunner.shared.isDeactivated else { return }
                let language = AppSettingsStore.current(in: context).language.rawValue
                var failed: Set<PersistentIdentifier> = []
                while !Task.isCancelled {
                    let pending = ((try? context.fetch(FetchDescriptor<Bookmark>())) ?? [])
                        .filter { $0.deletedAt == nil && LinkTranslator.isForeign($0.title)
                            && !failed.contains($0.persistentModelID) }
                    guard let link = pending.first else { break }
                    // Pausa mientras el usuario interactúa (igual que el enriquecido de fondo).
                    while NSApplication.shared.isActive,
                          UserActivityMonitor.shared.recentlyActive(within: 45.0) {
                        if Task.isCancelled { return }
                        try? await Task.sleep(for: .seconds(2))
                    }
                    guard link.modelContext != nil else { failed.insert(link.persistentModelID); continue }
                    let ok = await AIBatchEnricher.translateForeignTitle(link, in: context, language: language)
                    if !ok { failed.insert(link.persistentModelID) }   // no se pudo → no reintentar
                }
            }
            // IA local: SOLO se carga y enriquece si hay TRABAJO PENDIENTE de verdad. El
            // enriquecido es de UNA SOLA VEZ por enlace (al darlo de alta o con «Mejorar con
            // IA»): una vez completo NO se vuelve a tocar. Si la biblioteca ya está enriquecida,
            // el modelo (8,4 GB) NO se carga al arrancar → arranque fluido y CPU libre. El modelo
            // se carga bajo demanda al abrir el asistente o añadir un enlace (ya no hay preload).
            // Corre en `.background`: si hay backlog, lo va enriqueciendo SIN entrecortar la UI.
            .task(priority: .background) {
                let aiOn = UserDefaults.standard.object(forKey: "stacklume.aiAutoEnrich") as? Bool ?? true
                guard aiOn else { return }
                // Margen para que el usuario se asiente (scroll/clic inicial sin competencia).
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled,
                      LocalAIRunner.shared.isDownloaded,        // modelo ya en disco (no autodescarga)
                      !LocalAIRunner.shared.isDeactivated else { return }
                // Puerta: ¿quedan enlaces que AÚN necesitan IA y que NO se hayan intentado todavía
                // ([[EnrichmentLedger]])? «Necesita IA» = sin colección/etiquetas, sin título, o con
                // la DESCRIPCIÓN en otro idioma que hay que pasar a español ([[AIBatchEnricher]].
                // needsAIEnrichment). Antes la puerta solo miraba enlaces SIN colección, así que un
                // enlace ya categorizado pero con descripción inglesa (GitHub/HF) no despertaba nunca
                // la IA y se quedaba sin traducir. Los ya intentados NO cuentan: si en su día no se
                // pudo completar, NO se reintenta en cada arranque (recargaba el modelo y saturaba la
                // GPU). El `&&` corto-circuita por el ledger (lookup O(1) en memoria) ANTES de evaluar
                // `needsAIEnrichment`, así en estado estable (todo intentado) el filtro es barato y no
                // dispara faults de `.tags` ni el detector NL. Si no hay nada nuevo, el modelo (8,4 GB)
                // ni se carga.
                let candidates = (try? context.fetch(FetchDescriptor<Bookmark>(
                    predicate: #Predicate<Bookmark> { $0.deletedAt == nil }))) ?? []
                let fresh = candidates.filter {
                    !EnrichmentLedger.hasAIAttempt($0.id) && AIBatchEnricher.needsAIEnrichment($0)
                }
                guard !fresh.isEmpty else { return }   // nada nuevo que enriquecer → no se carga el modelo.
                // Hay trabajo real: ahora sí, carga el modelo (en `.background`) y enriquece una
                // pasada acotada. `enrich` cachea por nombre canónico (no duplica colecciones/tags).
                let language = AppSettingsStore.current(in: context).language.rawValue
                _ = await AIBatchEnricher.enrich(in: context, provider: "liquid",
                                                 language: language, limit: 50)
            }
            // Comprobador de enlaces ROTOS en 2.º plano (autodetectable): marca healthStatus
            // de un lote de enlaces (los menos comprobados primero) sin bloquear la UI. Opt-out
            // en Ajustes › Datos. Incremental: a lo largo de varios arranques cubre todo.
            .task(priority: .background) {
                let on = UserDefaults.standard.object(forKey: "stacklume.linkHealthAuto") as? Bool ?? true
                guard on else { return }
                try? await Task.sleep(for: .seconds(45))   // diferido: que no compita con el arranque
                guard !Task.isCancelled else { return }
                _ = await LinkHealthMonitor.runIfNeeded(in: context)
            }
            // Adquisición automática de PORTADAS en 2.º plano (opt-out): asegura imagen a los
            // enlaces que se quedaron sin ella (importaciones masivas que el enriquecido por IA
            // salta por estar ya «completas»). Reutiliza CoverEnsurer; serializado y acotado por
            // sesión. Antes había que pulsar «Obtener imagen» a mano en cada uno.
            .task(priority: .background) {
                try? await Task.sleep(for: .seconds(25))   // diferido: las capturas/descargas no compiten con el arranque
                guard !Task.isCancelled else { return }
                await CoverAutoFiller.runIfNeeded(in: context)
            }
            // Autocurativo de la CAPA GARANTIZADA (sin IA): mop-up del backlog importado que aún
            // quede con favicon genérico o metadatos a medias. Incremental y cede ante la
            // interacción (no toca la GPU/MLX) → no reintroduce el entrecorte. Punto único
            // [[LibraryCompleter]] (portada y salud tienen sus propias pasadas).
            .task(priority: .background) {
                try? await Task.sleep(for: .seconds(30))   // diferido: que no compita con el arranque
                guard !Task.isCancelled else { return }
                await LibraryCompleter.runIfNeeded(in: context)
            }
            // Precarga las listas de bloqueo de anuncios (descarga+compila una vez) para que
            // la primera apertura del navegador interno ya tenga los escudos listos. En
            // `.background`: la compilación de reglas no debe competir con el arranque.
            .task(priority: .background) { _ = await AdBlocker.shared.ruleList() }
            .sheet(isPresented: $showWelcome) {
                WelcomeView(onDone: { showWelcome = false })
                    .interactiveDismissDisabled().themedSheet(palette, theme)
            }
            .dropDestination(
                for: URL.self,
                action: { urls, _ in
                    importDroppedContent(urls)
                    return !urls.isEmpty
                },
                isTargeted: { isDropTargeted = $0 }
            )
            .onOpenURL { url in handleDeepLink(url) }
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                handleSpotlightActivity(activity)
            }
            // Banner flotante sutil arriba con la sugerencia del portapapeles.
            .overlay(alignment: .top) { clipboardBanner }
            // Paleta de comandos (busqueda global + navegacion + acciones), estilo Spotlight.
            .overlay { commandPaletteOverlay }
            // Zona de drop y HUD de importación, siempre por encima del contenido.
            .overlay { dropImportOverlay }
            // Al activarse la app: comprueba el portapapeles.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshClipboardSuggestion()
            }
            // Al abrir la ventana (la app ya esta activa al lanzarse).
            .task { refreshClipboardSuggestion() }
    }
}
