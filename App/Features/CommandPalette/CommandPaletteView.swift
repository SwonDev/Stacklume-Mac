import SwiftUI
import UniformTypeIdentifiers
import SwiftData
import StacklumeCore
import StacklumeDesignSystem
import StacklumePersistence

/// Paleta de comandos ⌘K estilo Spotlight: búsqueda global de enlaces, navegación
/// rápida a destinos/colecciones/etiquetas y acciones, todo desde el teclado.
///
/// Es un panel flotante (~640 de ancho, centrado-arriba) con fondo Liquid Glass que se
/// monta como `.overlay` sobre `RootWindowView`. Reutiliza el modelo de navegación
/// existente (`NavTarget`), el filtrado compartido (`filteredLinks`), las notificaciones
/// de comandos (`.stacklumeNewLink`, `.stacklumeNewCollection`) y los helpers de UI
/// (`RemoteImage`, `PlatformBadge`, `palette`, `DesignSystem`). No duplica navegación:
/// fija `selection`/`selectedLinks` directamente mediante los bindings del owner.
struct CommandPaletteView: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Selección de navegación del owner (columna izquierda).
    @Binding var selection: NavTarget?
    /// Selección de enlaces del owner (para mostrar la ficha de un enlace elegido).
    @Binding var selectedLinks: Set<Bookmark.ID>
    /// Cierra la paleta (lo controla el owner con animación).
    var onClose: () -> Void

    // Búsqueda global sobre TODA la biblioteca activa.
    @Query(filter: #Predicate<Bookmark> { $0.deletedAt == nil })
    private var allLinks: [Bookmark]
    @Query(filter: #Predicate<BookmarkCategory> { $0.deletedAt == nil },
           sort: \BookmarkCategory.order)
    private var categories: [BookmarkCategory]
    @Query(filter: #Predicate<Tag> { $0.deletedAt == nil },
           sort: \Tag.order)
    private var tags: [Tag]

    @State private var queryText = ""
    @State private var highlighted = 0
    @State private var libraryRevision: UInt = 0
    @State private var semanticMatches: [MultimodalSearchMatch] = []
    @State private var semanticQuery = ""
    @State private var searchFile: URL?
    @State private var showFilePicker = false
    @State private var searching = false
    @State private var searchError: String?
    @State private var semanticRevision: UInt = 0
    /// La misma consulta se solicita desde la vista, el scroll y la navegación por teclado.
    /// Sin esta caja, cada hover/flecha repetía la búsqueda global y el ordenado de enlaces.
    private final class ResultGroupsCache {
        var key = "\u{0}"
        var groups: [CommandGroup] = []
    }
    @State private var resultGroupsCache = ResultGroupsCache()
    /// ¿El último cambio de resaltado vino del TECLADO? Solo entonces se hace scroll
    /// automático al elemento. El hover resalta la fila pero NUNCA arrastra el scroll tras
    /// el ratón (era un problema serio de UX: el contenido saltaba al mover el ratón).
    @State private var keyboardNav = false
    /// Historial de búsquedas recientes (texto que el usuario buscó), persistido para
    /// re-ejecutar consultas habituales con un toque. Deduplicado y capado a 8.
    @AppStorage("stacklume.recentSearches") private var recentSearchesJSON = ""
    @FocusState private var fieldFocused: Bool

    /// Límite de enlaces mostrados para que la paleta siga siendo escaneable.
    private let linkLimit = 8

    var body: some View {
        let panelShape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        VStack(spacing: 0) {
            searchField
            if let file = searchFile {
                HStack {
                    Label(file.lastPathComponent, systemImage: "doc.viewfinder").stacklumeLineLimit(1)
                    Spacer()
                    Button("Quitar archivo") { searchFile = nil; fieldFocused = true }
                        .buttonStyle(.plain)
                }
                .stacklumeFont(.caption)
                .foregroundStyle(palette.textSecondary)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.bottom, DesignSystem.Spacing.sm)
            }
            if let searchError {
                Text(searchError).stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.bottom, DesignSystem.Spacing.sm)
            }
            Divider().overlay(palette.border.opacity(0.6))
            results
        }
        .frame(width: 640)
        .frame(maxHeight: 460)
        // Cristal neutro con respaldo navy: conserva la refracción nativa sin volver
        // a producir el lavado ámbar que causaba el tintado fuerte del efecto anterior.
        .background(palette.background.opacity(0.46), in: panelShape)
        .stacklumeGlass(in: panelShape)
        .overlay {
            panelShape.strokeBorder(palette.textPrimary.opacity(0.16), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.5), radius: 36, y: 18)
        .onAppear { fieldFocused = true }
        // Navegación por teclado (macOS 26): flechas mueven el resaltado, Enter
        // ejecuta, Esc cierra. Se atan al contenedor para funcionar también con el
        // foco en el campo de texto.
        .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
        .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
        .onKeyPress(.return) { runHighlighted(); return .handled }
        .onKeyPress(.escape) { onClose(); return .handled }
        // Si cambia el texto, el resaltado vuelve al primero y se reajusta.
        .onChange(of: queryText) { _, _ in highlighted = 0 }
        .task(id: searchRequestKey) {
            let signature = searchSignature
            let current = queryText
            let query = SearchQuery.parse(current)
            let file = searchFile
            semanticMatches = []
            searchError = nil
            searching = false
            guard query.freeText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 || file != nil else { return }
            let allowed = filteredLinks(allLinks, using: LinkFilter(), sort: .recent)
                .filter { query.matches($0) }.map(\.id)
            searching = true
            do {
                try await Task.sleep(for: .milliseconds(250))
                let matches = try await MultimodalSearchService.shared.search(query.freeText, file: file, allowedIDs: allowed)
                try Task.checkCancellation()
                guard signature == searchSignature else { return }
                semanticMatches = matches
                semanticQuery = signature
                semanticRevision &+= 1
            } catch {
                guard !Task.isCancelled, signature == searchSignature else { return }
                searchError = error.localizedDescription
            }
            searching = false
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.image, .pdf, .audio, .movie, .plainText]) { result in
            if case .success(let url) = result { queryText = ""; searchFile = url }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stacklumeModelDidSave)) { _ in
            libraryRevision &+= 1
        }
    }

    // MARK: - Campo de búsqueda

    private var searchField: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(palette.textSecondary)
                .accessibilityHidden(true)
            TextField("Buscar enlaces, colecciones, secciones o acciones…", text: $queryText)
                .textFieldStyle(.plain)
                .stacklumeFont(.title3)
                .foregroundStyle(palette.textPrimary)
                .focused($fieldFocused)
                .onSubmit { runHighlighted() }
            if searching { ProgressView().controlSize(.small).accessibilityLabel("Buscando") }
            Button { showFilePicker = true } label: {
                Image(systemName: "doc.viewfinder").foregroundStyle(palette.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Buscar con un archivo")
            .themedHelp("Buscar contenido parecido con una imagen, PDF, audio o vídeo")
            if !queryText.isEmpty {
                Button {
                    queryText = ""
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(palette.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Borrar búsqueda")
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm + 2)
    }

    // MARK: - Resultados

    @ViewBuilder
    private var results: some View {
        let groups = resultGroups
        if groups.isEmpty {
            emptyResults
        } else {
            // Aplana UNA vez en este render: los `id` (ahora estables) son consistentes
            // entre `groups` y `flat`, así el índice de cada fila es el real (no 0).
            let flat = groups.flatMap(\.items)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(groups) { group in
                            sectionHeader(group.title)
                            ForEach(group.items) { item in
                                row(for: item, index: flat.firstIndex { $0.id == item.id } ?? 0)
                            }
                        }
                    }
                    .padding(.vertical, DesignSystem.Spacing.xs)
                }
                .onChange(of: highlighted) { _, idx in
                    // Solo el teclado arrastra el scroll; el hover NO (scroll normal).
                    guard keyboardNav else { return }
                    keyboardNav = false
                    if let id = flatItems[safe: idx]?.id {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var emptyResults: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(palette.textSecondary.opacity(0.6))
                .accessibilityHidden(true)
            Text("Sin resultados para «\(queryText)»")
                .stacklumeFont(.callout)
                .foregroundStyle(palette.textSecondary)
            Text("Prueba con otras palabras o pulsa Esc para cerrar")
                .stacklumeFont(.caption)
                .foregroundStyle(palette.textSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSystem.Spacing.lg)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sin resultados para \(queryText). Prueba con otras palabras o pulsa Escape para cerrar.")
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .stacklumeFont(.caption.weight(.semibold))
            .foregroundStyle(palette.textSecondary)
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.top, DesignSystem.Spacing.sm)
            .padding(.bottom, 2)
    }

    @ViewBuilder
    private func row(for item: CommandItem, index: Int) -> some View {
        let isOn = index == highlighted
        HStack(spacing: DesignSystem.Spacing.sm) {
            icon(for: item)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .stacklumeFont(.body.weight(.medium))
                    .foregroundStyle(isOn ? palette.accent : palette.textPrimary)
                    .stacklumeLineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .stacklumeFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .stacklumeLineLimit(1)
                }
            }
            Spacer(minLength: DesignSystem.Spacing.sm)
            if isOn {
                Image(systemName: "return")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.sm - 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isOn ? palette.accent.opacity(0.16) : .clear)
        )
        .padding(.horizontal, DesignSystem.Spacing.xs)
        .id(item.id)
        .contentShape(Rectangle())
        .onTapGesture { run(item) }
        // Resalta al pasar el ratón, pero SIN arrastrar el scroll (eso solo con el teclado).
        .onHover { hovering in if hovering { keyboardNav = false; highlighted = index } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.subtitle.map { "\(item.title), \($0)" } ?? item.title)
        .accessibilityHint(isOn ? "Pulsa Intro para ejecutar" : "")
    }

    @ViewBuilder
    private func icon(for item: CommandItem) -> some View {
        switch item.kind {
        case .link(let link):
            SecureRemoteImage(candidates: [link.faviconURL]) {
                PlatformBadge(platform: link.platform, size: 22)
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        case .navigate, .action, .search:
            Image(systemName: item.systemImage)
                .font(.body)
                .foregroundStyle(item.tint ?? palette.accent)
                .frame(width: 22, height: 22)
        }
    }

    // MARK: - Construcción de resultados

    /// Texto de búsqueda normalizado (sin espacios extremos).
    private var searchSignature: String { queryText + "|" + (searchFile?.path ?? "") }
    private var searchRequestKey: String {
        "\(searchSignature)|\(libraryRevision)|\(MultimodalSearchService.shared.revision)"
    }

    private var trimmedQuery: String {
        queryText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ¿Casa `haystack` con el texto buscado? Insensible a mayúsculas y diacríticos.
    private func matches(_ haystack: String) -> Bool {
        guard !trimmedQuery.isEmpty else { return true }
        return haystack.range(
            of: trimmedQuery,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }

    /// Grupos de resultados según el texto. Si está vacío, accesos rápidos por defecto.
    private var resultGroups: [CommandGroup] {
        let key = "\(libraryRevision)|\(searchSignature)|\(semanticRevision)"
        if resultGroupsCache.key == key { return resultGroupsCache.groups }
        let groups = trimmedQuery.isEmpty && searchFile == nil ? defaultGroups : searchGroups
        resultGroupsCache.key = key
        resultGroupsCache.groups = groups
        return groups
    }

    /// Accesos rápidos por defecto (texto vacío): destinos principales, «Nuevo enlace»
    /// y los enlaces guardados más recientes.
    private var defaultGroups: [CommandGroup] {
        var groups: [CommandGroup] = []

        groups.append(CommandGroup(title: "Ir a", items: [
            navItem(.all, "Todos", "tray.full"),
            navItem(.inbox, "Bandeja", "tray.full.fill"),
            navItem(.favorites, "Favoritos", "star"),
            navItem(.readingQueue, "Cola de lectura", "clock"),
            navItem(.unsorted, "Sin clasificar", "tray"),
            navItem(.connections, "Conexiones", "point.3.connected.trianglepath.dotted"),
            navItem(.discover, "Descubrir", "safari"),
            navItem(.huggingFace, "Hugging Face", "cpu"),
            navItem(.civitai, "Civitai", "photo.on.rectangle.angled"),
        ]))

        let searches = recentSearches
        if !searches.isEmpty {
            groups.append(CommandGroup(title: "Búsquedas recientes",
                                       items: searches.map { searchItem($0) }))
        }

        let recent = filteredLinks(allLinks, using: LinkFilter(), sort: .recent).prefix(5)
        if !recent.isEmpty {
            groups.append(CommandGroup(title: "Recientes",
                                       items: recent.map { linkItem($0) }))
        }

        groups.append(CommandGroup(title: "Acciones", items: actionItems))
        return groups
    }

    /// Grupos filtrados por el texto buscado.
    private var searchGroups: [CommandGroup] {
        var groups: [CommandGroup] = []

        // 1) Enlaces (búsqueda global). El TEXTO lo filtra la capa de app (mira título, URL,
        // descripción, resumen, notas, COLECCIÓN y ETIQUETAS), no el almacén —que no busca en
        // etiquetas—. Así «3D assets» encuentra un enlace cuya coincidencia es la etiqueta.
        let filter = LinkFilter()
        let base = filteredLinks(allLinks, using: filter, sort: .recent)
        let matchedLinks = MultimodalSearchService.shared.hybrid(base, query: trimmedQuery,
            matches: semanticQuery == searchSignature ? semanticMatches : [], limit: linkLimit, includeLiteral: searchFile == nil)
        if !matchedLinks.isEmpty {
            groups.append(CommandGroup(
                title: "Enlaces",
                items: matchedLinks.prefix(linkLimit).map { linkItem($0) }))
        }

        if searchFile != nil { return groups }

        // 2) Ir a: destinos de sistema + colecciones + etiquetas que casen.
        var navItems: [CommandItem] = systemTargets
            .filter { matches($0.title) }
            .map { navItem($0.target, $0.title, $0.symbol) }

        navItems += categories
            .filter { matches($0.name) }
            .prefix(6)
            .map { collectionItem($0) }

        navItems += tags
            .filter { matches($0.name) }
            .prefix(6)
            .map { tagItem($0) }

        if !navItems.isEmpty {
            groups.append(CommandGroup(title: "Ir a", items: navItems))
        }

        // 3) Acciones que casen.
        let matchedActions = actionItems.filter { matches($0.title) }
        if !matchedActions.isEmpty {
            groups.append(CommandGroup(title: "Acciones", items: matchedActions))
        }

        return groups
    }

    /// Destinos de sistema direccionables desde la paleta (título + símbolo).
    private var systemTargets: [(target: NavTarget, title: String, symbol: String)] {
        [
            (.all, "Todos", "tray.full"),
            (.inbox, "Bandeja", "tray.full.fill"),
            (.unsorted, "Sin clasificar", "tray"),
            (.favorites, "Favoritos", "star"),
            (.readingQueue, "Cola de lectura", "clock"),
            (.highlights, "Resaltados", "highlighter"),
            (.connections, "Conexiones", "point.3.connected.trianglepath.dotted"),
            (.discover, "Descubrir", "safari"),
            (.huggingFace, "Hugging Face", "cpu"),
            (.civitai, "Civitai", "photo.on.rectangle.angled"),
            (.x, "X", "at"),
            (.stats, "Estadísticas", "chart.bar"),
            (.sessions, "Sesiones", "rectangle.stack"),
            (.projects, "Proyectos", "folder.badge.gearshape"),
            (.rules, "Reglas", "wand.and.stars"),
            (.ai, "Asistente IA", "sparkles"),
            (.trash, "Papelera", "trash"),
        ]
    }

    /// Acciones disponibles (disparan las notificaciones de comandos existentes).
    private var actionItems: [CommandItem] {
        [
            CommandItem(kind: .action(.newLink), title: "Nuevo enlace",
                        subtitle: "⌘N", systemImage: "plus.circle"),
            CommandItem(kind: .action(.newCollection), title: "Nueva colección",
                        subtitle: "⌘⇧N", systemImage: "folder.badge.plus"),
            CommandItem(kind: .action(.importOpenTabs), title: "Importar pestañas abiertas",
                        subtitle: "⌥⌘I", systemImage: "macwindow.on.rectangle"),
        ]
    }

    // MARK: - Fábricas de `CommandItem`

    private func linkItem(_ link: Bookmark) -> CommandItem {
        CommandItem(kind: .link(link), title: link.title.isEmpty ? link.url : link.title,
                    subtitle: link.url.urlHost, systemImage: "link")
    }

    private func navItem(_ target: NavTarget, _ title: String, _ symbol: String) -> CommandItem {
        CommandItem(kind: .navigate(target), title: title, subtitle: nil, systemImage: symbol)
    }

    private func collectionItem(_ category: BookmarkCategory) -> CommandItem {
        CommandItem(kind: .navigate(.collection(category.id)), title: category.name,
                    subtitle: "Colección", systemImage: category.icon,
                    tint: Color(hex: category.colorHex))
    }

    private func tagItem(_ tag: Tag) -> CommandItem {
        CommandItem(kind: .navigate(.tag(tag.id)), title: tag.name,
                    subtitle: "Etiqueta", systemImage: "tag",
                    tint: Color(hex: tag.colorHex))
    }

    // MARK: - Lista aplanada (para la navegación por teclado)

    /// Todos los `CommandItem` en orden de presentación, sin cabeceras.
    private var flatItems: [CommandItem] {
        resultGroups.flatMap(\.items)
    }

    private func moveHighlight(_ delta: Int) {
        let count = flatItems.count
        guard count > 0 else { return }
        keyboardNav = true   // navegación por teclado → sí desplaza el scroll al elemento
        highlighted = (highlighted + delta + count) % count
    }

    private func runHighlighted() {
        guard let item = flatItems[safe: highlighted] else { return }
        run(item)
    }

    // MARK: - Ejecución de un resultado

    /// Ejecuta el resultado según su tipo y cierra la paleta. Reutiliza el modelo de
    /// navegación (`NavTarget`) y las notificaciones de comandos existentes.
    private func run(_ item: CommandItem) {
        // Búsqueda reciente: rellena el campo y re-busca SIN cerrar la paleta.
        if case .search(let query) = item.kind {
            queryText = query
            highlighted = 0
            return
        }
        // El usuario actuó tras escribir → guarda la consulta en el historial (no-op si vacía).
        recordSearch(trimmedQuery)
        switch item.kind {
        case .link(let link):
            // Lleva el contexto a la colección del enlace (o «Todos») y selecciona el
            // enlace para que la columna de detalle muestre su ficha.
            if let collectionID = link.category?.id {
                selection = .collection(collectionID)
            } else {
                selection = .all
            }
            selectedLinks = [link.id]
        case .navigate(let target):
            selection = target
        case .action(let action):
            NotificationCenter.default.post(name: action.notification, object: nil)
        case .search:
            break   // ya manejado arriba
        }
        onClose()
    }

    // MARK: - Historial de búsquedas

    private var recentSearches: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(recentSearchesJSON.utf8))) ?? []
    }

    /// Guarda una consulta en el historial: la pone primera, sin duplicados (insensible a
    /// mayúsculas) y capa a 8. Ignora consultas de menos de 2 caracteres.
    private func recordSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return }
        var list = recentSearches.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        list.insert(q, at: 0)
        list = Array(list.prefix(8))
        recentSearchesJSON = (try? JSONEncoder().encode(list))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private func searchItem(_ query: String) -> CommandItem {
        CommandItem(kind: .search(query), title: query, subtitle: "Buscar de nuevo",
                    systemImage: "clock.arrow.circlepath")
    }
}

// MARK: - Modelo de resultado

/// Una acción de comando (dispara una notificación existente).
private enum CommandAction {
    case newLink
    case newCollection
    case importOpenTabs

    var notification: Notification.Name {
        switch self {
        case .newLink: .stacklumeNewLink
        case .newCollection: .stacklumeNewCollection
        case .importOpenTabs: .stacklumeImportOpenTabs
        }
    }
}

/// Tipo de un resultado de la paleta.
private enum CommandKind {
    case link(Bookmark)
    case navigate(NavTarget)
    case action(CommandAction)
    /// Búsqueda reciente: al elegirla rellena el campo y re-busca (no cierra la paleta).
    case search(String)
}

/// Un resultado individual (fila) de la paleta.
private struct CommandItem: Identifiable {
    let kind: CommandKind
    let title: String
    var subtitle: String?
    var systemImage: String = "circle"
    var tint: Color?
    /// Id ESTABLE entre evaluaciones de `resultGroups`. Antes era `UUID()` aleatorio:
    /// como `resultGroups` es una propiedad computada que se re-evalúa en cada acceso,
    /// regeneraba ids nuevos, y la búsqueda del índice por id fallaba y caía a 0 → con
    /// `highlighted == 0` TODAS las filas se resaltaban en dorado a la vez. Derivado del
    /// contenido: estable, así solo se resalta la fila activa y el scroll por id funciona.
    var id: String {
        switch kind {
        case .link(let link): "link-\(link.id.uuidString)"
        case .navigate(let target): "nav-\(target.key)"
        case .action: "act-\(title)"
        case .search(let q): "search-\(q)"
        }
    }
}

/// Una sección de resultados (con cabecera).
private struct CommandGroup: Identifiable {
    let id = UUID()
    let title: String
    let items: [CommandItem]
}

// MARK: - Helpers

private extension Array {
    /// Acceso seguro por índice (evita desbordes en la navegación por teclado).
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
