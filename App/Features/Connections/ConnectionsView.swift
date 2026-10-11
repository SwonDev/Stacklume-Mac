import SwiftUI
import SwiftData
import StacklumeCore
import StacklumeDesignSystem

/// Explorador visual de relaciones de la biblioteca. No crea un índice paralelo ni usa
/// servicios externos: reutiliza `SemanticSearch`, sus embeddings de NaturalLanguage y
/// las señales locales de etiquetas, dominio, colección y plataforma.
struct ConnectionsView: View {
    private enum ConnectionLens: String, CaseIterable, Identifiable {
        case all
        case meaning
        case tags
        case collection
        case site

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "Todas"
            case .meaning: "Por tema"
            case .tags: "Por etiquetas"
            case .collection: "Por colección"
            case .site: "Por sitio"
            }
        }

        var systemImage: String {
            switch self {
            case .all: "scope"
            case .meaning: "brain.head.profile"
            case .tags: "tag"
            case .collection: "folder"
            case .site: "globe"
            }
        }
    }

    private struct DisplayMatch: Identifiable, Equatable {
        let id: UUID
        let strength: Double
        let explanation: String
        let sharedTagCount: Int
        let sameDomain: Bool
        let sameCategory: Bool
        let semanticSimilarity: Double

        func belongs(to lens: ConnectionLens) -> Bool {
            switch lens {
            case .all: true
            case .meaning: semanticSimilarity >= 0.35
            case .tags: sharedTagCount > 0
            case .collection: sameCategory
            case .site: sameDomain
            }
        }
    }

    @Binding var selection: Set<Bookmark.ID>

    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Query(filter: #Predicate<Bookmark> { $0.deletedAt == nil },
           sort: \Bookmark.updatedAt, order: .reverse)
    private var allLinks: [Bookmark]
    @Query private var settings: [AppSettings]

    @AppStorage("stacklume.connections.includeArchived") private var includeArchived = false
    @AppStorage("stacklume.connections.lens") private var lensRawValue = ConnectionLens.all.rawValue
    @State private var focusedID: UUID?
    @State private var history: [UUID] = []
    @State private var historyIndex = -1
    @State private var searchText = ""
    @State private var searchResultIDs: [UUID] = []
    @State private var isSearchPresented = false
    @State private var isWarming = false
    @State private var displayMatches: [DisplayMatch] = []
    @State private var hoveredID: UUID?
    @FocusState private var searchFocused: Bool

    private var selectedLens: ConnectionLens {
        ConnectionLens(rawValue: lensRawValue) ?? .all
    }
    private var language: String { (settings.first?.language ?? .es).rawValue }
    private var links: [Bookmark] {
        includeArchived ? allLinks : allLinks.filter { !$0.isArchived }
    }
    private var focusedLink: Bookmark? {
        guard let focusedID else { return nil }
        return links.first { $0.id == focusedID }
    }
    private var resolvedMatches: [(display: DisplayMatch, link: Bookmark)] {
        var byID: [UUID: Bookmark] = [:]
        byID.reserveCapacity(links.count)
        for link in links where byID[link.id] == nil { byID[link.id] = link }
        return displayMatches.compactMap { display in
            guard display.belongs(to: selectedLens), let link = byID[display.id] else { return nil }
            return (display, link)
        }
    }
    private var searchResults: [Bookmark] {
        searchResultIDs.compactMap { id in links.first { $0.id == id } }
    }
    private var warmTaskID: String {
        let newest = links.first?.updatedAt.timeIntervalSinceReferenceDate ?? 0
        return "\(language)|\(links.count)|\(newest)|\(includeArchived)"
    }

    var body: some View {
        VStack(spacing: 0) {
            controlBar

            if links.isEmpty {
                EmptyStateView(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "Aún no hay conexiones",
                    message: includeArchived
                        ? "Guarda algunos enlaces para empezar a descubrir relaciones."
                        : "No hay enlaces activos. Puedes incluir los archivados o guardar uno nuevo."
                )
            } else if let focusedLink {
                explorer(for: focusedLink)
            } else {
                startingPoint
            }
        }
        .background(palette.background)
        .navigationTitle("Conexiones")
        .task(id: warmTaskID) { await warmConnections() }
        .task(id: searchText) { await updateSearchResults() }
        .onAppear { ensureValidFocus() }
        .onChange(of: includeArchived) { _, _ in
            ensureValidFocus()
            refreshConnections()
        }
        .onChange(of: lensRawValue) { _, _ in hoveredID = nil }
        .onChange(of: allLinks.count) { _, _ in
            ensureValidFocus()
            refreshConnections()
        }
    }

    // MARK: - Barra funcional

    private var controlBar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: 2) {
                historyButton(
                    systemImage: "chevron.left",
                    label: "Conexión anterior",
                    isDisabled: historyIndex <= 0,
                    action: goBack
                )
                historyButton(
                    systemImage: "chevron.right",
                    label: "Conexión siguiente",
                    isDisabled: historyIndex < 0 || historyIndex >= history.count - 1,
                    action: goForward
                )
            }
            .padding(2)
            .background(Capsule().fill(palette.surface))
            .overlay(Capsule().strokeBorder(palette.border.opacity(0.35), lineWidth: 0.5))

            lensMenu

            Spacer(minLength: DesignSystem.Spacing.sm)

            Label("100 % local", systemImage: "lock.fill")
                .stacklumeFont(.caption)
                .foregroundStyle(palette.textSecondary)
                .accessibilityLabel("Procesamiento cien por cien local en este Mac")

            Button {
                isSearchPresented.toggle()
            } label: {
                Image(systemName: "magnifyingglass")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSearchPresented ? palette.accent : palette.textSecondary)
            .background(Circle().fill(isSearchPresented ? palette.accent.opacity(0.10) : palette.surface))
            .accessibilityLabel("Buscar punto de partida")
            .themedHelp("Buscar un enlace para convertirlo en el centro")
            .popover(isPresented: $isSearchPresented, arrowEdge: .top) {
                searchPopover
            }

            Button(action: surpriseMe) {
                Label("Al azar", systemImage: "sparkles")
                    .stacklumeFont(.callout.weight(.medium))
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .frame(height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.textPrimary)
            .background(Capsule().fill(palette.surface))
            .overlay(Capsule().strokeBorder(palette.border.opacity(0.35), lineWidth: 0.5))
            .themedHelp("Redescubrir un enlace al azar")
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .background(palette.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.border.opacity(0.35))
                .frame(height: 0.5)
                .accessibilityHidden(true)
        }
    }

    private func historyButton(
        systemImage: String,
        label: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isDisabled ? palette.textSecondary.opacity(0.35) : palette.textSecondary)
        .disabled(isDisabled)
        .accessibilityLabel(label)
        .themedHelp(label)
    }

    private var lensMenu: some View {
        Menu {
            ForEach(ConnectionLens.allCases) { lens in
                Button {
                    lensRawValue = lens.rawValue
                } label: {
                    Label(lens.title, systemImage: lens == selectedLens ? "checkmark" : lens.systemImage)
                }
            }
            Divider()
            Toggle("Incluir archivados", isOn: $includeArchived)
        } label: {
            Label(selectedLens.title, systemImage: selectedLens.systemImage)
                .stacklumeFont(.callout.weight(.medium))
                .foregroundStyle(palette.textPrimary)
                .padding(.horizontal, DesignSystem.Spacing.xs)
                .frame(height: 30)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .themedHelp("Cambiar la lente de relación e incluir archivados")
        .accessibilityLabel("Lente de conexiones: \(selectedLens.title)")
    }

    private var searchPopover: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Buscar punto de partida")
                .stacklumeFont(.headline)
                .foregroundStyle(palette.textPrimary)

            searchField

            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchResultsPanel
            } else {
                Text("Busca por título, dominio o descripción.")
                    .stacklumeFont(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(width: 380)
        .background(palette.popover)
        .task { searchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(palette.textSecondary)
                .accessibilityHidden(true)
            TextField("Título, sitio o idea…", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { if let first = searchResults.first { chooseSearchResult(first) } }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchResultIDs = []
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.textSecondary)
                .accessibilityLabel("Borrar búsqueda")
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
                .fill(palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
                .strokeBorder(searchFocused ? palette.accent.opacity(0.65) : palette.border.opacity(0.45),
                              lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var searchResultsPanel: some View {
        if searchResults.isEmpty {
            Text("No hay enlaces que coincidan.")
                .stacklumeFont(.caption)
                .foregroundStyle(palette.textSecondary)
                .padding(.vertical, DesignSystem.Spacing.xs)
                .accessibilityLabel("No hay enlaces que coincidan con la búsqueda")
        } else {
            VStack(spacing: DesignSystem.Spacing.xxs) {
                ForEach(searchResults) { link in
                    Button { chooseSearchResult(link) } label: {
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            Image(systemName: link.platform.sfSymbol)
                                .foregroundStyle(palette.textSecondary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(displayTitle(link))
                                    .foregroundStyle(palette.textPrimary)
                                    .stacklumeLineLimit(1)
                                Text(host(for: link))
                                    .stacklumeFont(.caption)
                                    .foregroundStyle(palette.textSecondary)
                                    .stacklumeLineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "arrow.right")
                                .foregroundStyle(palette.textSecondary)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, DesignSystem.Spacing.xs)
                        .frame(minHeight: 42)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Usar como centro del mapa")
                }
            }
        }
    }

    // MARK: - Explorador

    @ViewBuilder
    private func explorer(for focused: Bookmark) -> some View {
        let matches = resolvedMatches
        if isWarming && displayMatches.isEmpty {
            VStack(spacing: DesignSystem.Spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                Text("Buscando conexiones locales…")
                    .stacklumeFont(.callout)
                    .foregroundStyle(palette.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else if matches.isEmpty {
            noConnections(for: focused, filtered: !displayMatches.isEmpty)
        } else {
            connectionCanvas(focused: focused, matches: matches)
        }
    }

    private func connectionCanvas(
        focused: Bookmark,
        matches: [(display: DisplayMatch, link: Bookmark)]
    ) -> some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 560
            let visible = Array(matches.prefix(ConnectionMapLayout.maximumVisibleSatellites))
            let hidden = Array(matches.dropFirst(ConnectionMapLayout.maximumVisibleSatellites))
            let points = ConnectionMapLayout.satellitePoints(count: visible.count, compact: compact)
            let center = mapPoint(ConnectionMapLayout.center, in: geometry.size)
            let inspected = visible.first { $0.display.id == hoveredID } ?? visible.first

            ZStack(alignment: .bottom) {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [palette.accent.opacity(0.065), palette.accent.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: compact ? 130 : 180
                        )
                    )
                    .frame(width: compact ? 260 : 360, height: compact ? 260 : 360)
                    .position(center)
                    .accessibilityHidden(true)

                Canvas { context, size in
                    for (index, match) in visible.enumerated() where index < points.count {
                        let end = mapPoint(points[index], in: size)
                        let active = hoveredID == match.display.id
                        let deltaX = end.x - center.x
                        let deltaY = end.y - center.y
                        let control = CGPoint(
                            x: center.x + deltaX * 0.54,
                            y: center.y + deltaY * 0.38
                        )
                        var path = Path()
                        path.move(to: center)
                        path.addQuadCurve(to: end, control: control)
                        context.stroke(
                            path,
                            with: .color(
                                active
                                    ? palette.accent.opacity(0.58)
                                    : palette.textSecondary.opacity(0.08 + match.display.strength * 0.12)
                            ),
                            lineWidth: active ? 1.4 : 0.55 + match.display.strength * 0.45
                        )
                    }
                }
                .accessibilityHidden(true)

                ForEach(Array(visible.enumerated()), id: \.element.display.id) { index, match in
                    if index < points.count {
                        satelliteNode(
                            match.link,
                            compact: compact,
                            reason: match.display.explanation,
                            isHovered: hoveredID == match.display.id
                        ) {
                            focus(on: match.display.id)
                        }
                        .onHover { hovering in
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                                if hovering { hoveredID = match.display.id }
                                else if hoveredID == match.display.id { hoveredID = nil }
                            }
                        }
                        .position(mapPoint(points[index], in: geometry.size))
                    }
                }

                focusNode(focused, compact: compact)
                    .position(center)

                if let inspected {
                    relationshipInspector(inspected, hidden: hidden)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Constelación local de \(displayTitle(focused))")
    }

    private func satelliteNode(
        _ link: Bookmark,
        compact: Bool,
        reason: String,
        isHovered: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: link.platform.sfSymbol)
                    .font(.callout)
                    .foregroundStyle(isHovered ? palette.accent : palette.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(palette.surface.opacity(isHovered ? 1 : 0.72)))
                Text(displayTitle(link))
                    .stacklumeFont(.caption.weight(.semibold))
                    .foregroundStyle(palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .stacklumeLineLimit(2)
                Text(host(for: link))
                    .stacklumeFont(.caption2)
                    .foregroundStyle(palette.textSecondary)
                    .stacklumeLineLimit(1)
            }
            .padding(DesignSystem.Spacing.xs)
            .frame(width: compact ? 132 : 164)
            .frame(minHeight: 78)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
                    .fill(isHovered ? palette.surface.opacity(0.92) : palette.surface.opacity(0.001))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
                    .strokeBorder(isHovered ? palette.accent.opacity(0.28) : palette.border.opacity(0),
                                  lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(displayTitle(link)), \(reason)")
        .accessibilityHint("Convertir en el centro de la constelación")
    }

    private func focusNode(_ link: Bookmark, compact: Bool) -> some View {
        Button {
            selection = [link.id]
        } label: {
            VStack(spacing: DesignSystem.Spacing.xs) {
                Text("Punto de partida")
                    .stacklumeFont(.caption2.weight(.semibold))
                    .foregroundStyle(palette.textSecondary)
                Image(systemName: link.platform.sfSymbol)
                    .font(.title3)
                    .foregroundStyle(palette.accent)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(palette.accent.opacity(0.10)))
                Text(displayTitle(link))
                    .stacklumeFont(.title3.weight(.semibold))
                    .foregroundStyle(palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .stacklumeLineLimit(3)
                Text(host(for: link))
                    .stacklumeFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .stacklumeLineLimit(1)
            }
            .padding(DesignSystem.Spacing.sm)
            .frame(width: compact ? 220 : 286)
            .frame(minHeight: 150)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Enlace central: \(displayTitle(link))")
        .accessibilityHint("Mostrar su ficha")
    }

    private func relationshipInspector(
        _ match: (display: DisplayMatch, link: Bookmark),
        hidden: [(display: DisplayMatch, link: Bookmark)]
    ) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: match.link.platform.sfSymbol)
                .font(.callout)
                .foregroundStyle(palette.accent)
                .frame(width: 28, height: 28)
                .background(Circle().fill(palette.accent.opacity(0.09)))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle(match.link))
                    .stacklumeFont(.callout.weight(.medium))
                    .foregroundStyle(palette.textPrimary)
                    .stacklumeLineLimit(1)
                Text(match.display.explanation)
                    .stacklumeFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .stacklumeLineLimit(2)
            }

            Spacer(minLength: DesignSystem.Spacing.sm)

            if !hidden.isEmpty {
                Menu {
                    ForEach(hidden, id: \.display.id) { item in
                        Button {
                            focus(on: item.display.id)
                        } label: {
                            Label(displayTitle(item.link), systemImage: item.link.platform.sfSymbol)
                        }
                    }
                } label: {
                    Label("\(hidden.count) más", systemImage: "ellipsis")
                        .stacklumeFont(.caption.weight(.medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .themedHelp("Mostrar conexiones adicionales")
            }

            Button {
                focus(on: match.display.id)
            } label: {
                Label("Explorar", systemImage: "arrow.right")
                    .stacklumeFont(.callout.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.accent)
            .accessibilityHint("Convertir este enlace en el punto de partida")
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(palette.surface.opacity(0.78))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(palette.border.opacity(0.40))
                .frame(height: 0.5)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
    }

    private func noConnections(for focused: Bookmark, filtered: Bool) -> some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            focusNode(focused, compact: false)
            VStack(spacing: DesignSystem.Spacing.xs) {
                Text(filtered ? "Ninguna conexión con esta lente" : "Sin conexiones claras")
                    .stacklumeFont(.headline)
                    .foregroundStyle(palette.textPrimary)
                Text(filtered
                     ? "Prueba otra lente para descubrir relaciones distintas."
                     : "Stacklume evita completar el mapa con relaciones débiles o inventadas.")
                    .stacklumeFont(.callout)
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            Button {
                if filtered { lensRawValue = ConnectionLens.all.rawValue }
                else { surpriseMe() }
            } label: {
                Label(filtered ? "Ver todas" : "Probar otro enlace",
                      systemImage: filtered ? "scope" : "sparkles")
            }
            .stacklumeButton(prominent: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignSystem.Spacing.xl)
        .accessibilityElement(children: .contain)
    }

    private var startingPoint: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 42))
                .foregroundStyle(palette.accent)
                .accessibilityHidden(true)
            Text("Elige un punto de partida")
                .stacklumeFont(.title2.weight(.bold))
                .foregroundStyle(palette.textPrimary)
            Text("Busca un enlace o deja que Stacklume rescate uno. Cada salto conserva el camino para que puedas explorar sin perderte.")
                .stacklumeFont(.callout)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button(action: surpriseMe) {
                Label("Redescubrir al azar", systemImage: "sparkles")
            }
            .stacklumeButton()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignSystem.Spacing.xl)
    }

    // MARK: - Acciones

    private func ensureValidFocus() {
        guard !links.isEmpty else {
            focusedID = nil
            history = []
            historyIndex = -1
            displayMatches = []
            selection.removeAll()
            return
        }
        if let focusedID, links.contains(where: { $0.id == focusedID }) { return }
        focus(on: links[0].id, replacingHistory: true)
    }

    private func focus(on id: UUID, replacingHistory: Bool = false) {
        guard links.contains(where: { $0.id == id }) else { return }
        let changes = {
            focusedID = id
            hoveredID = nil
            selection = [id]
            refreshConnections(for: id)
            searchText = ""
            searchResultIDs = []
            if replacingHistory {
                history = [id]
                historyIndex = 0
            } else if !(history.indices.contains(historyIndex) && history[historyIndex] == id) {
                if historyIndex + 1 < history.count {
                    history.removeSubrange((historyIndex + 1)..<history.count)
                }
                history.append(id)
                historyIndex = history.count - 1
                if history.count > 40 {
                    history.removeFirst(history.count - 40)
                    historyIndex = history.count - 1
                }
            }
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { changes() }
    }

    private func goBack() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        applyHistorySelection()
    }

    private func goForward() {
        guard historyIndex >= 0, historyIndex < history.count - 1 else { return }
        historyIndex += 1
        applyHistorySelection()
    }

    private func applyHistorySelection() {
        guard history.indices.contains(historyIndex) else { return }
        let id = history[historyIndex]
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            focusedID = id
            hoveredID = nil
            selection = [id]
            refreshConnections(for: id)
        }
    }

    private func surpriseMe() {
        let candidates = links.filter { $0.id != focusedID }
        guard let pick = (candidates.isEmpty ? links : candidates).randomElement() else { return }
        focus(on: pick.id)
    }

    private func chooseSearchResult(_ link: Bookmark) {
        focus(on: link.id)
        searchFocused = false
        isSearchPresented = false
    }

    private func warmConnections() async {
        let snapshot = links
        guard !snapshot.isEmpty else { return }
        isWarming = true
        await SemanticSearch.warm(snapshot, language: language)
        guard !Task.isCancelled else { return }
        refreshConnections()
        isWarming = false
    }

    private func refreshConnections(for id: UUID? = nil) {
        guard let targetID = id ?? focusedID,
              let target = links.first(where: { $0.id == targetID }) else {
            displayMatches = []
            return
        }
        displayMatches = SemanticSearch.relatedMatches(
            to: target,
            in: links,
            language: language,
            limit: 6
        ).map {
            DisplayMatch(
                id: $0.id,
                strength: $0.strength,
                explanation: $0.explanation,
                sharedTagCount: $0.sharedTagCount,
                sameDomain: $0.sameDomain,
                sameCategory: $0.sameCategory,
                semanticSimilarity: $0.semanticSimilarity
            )
        }
    }

    private func updateSearchResults() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResultIDs = []
            return
        }
        try? await Task.sleep(for: .milliseconds(160))
        guard !Task.isCancelled else { return }

        var result: [UUID] = []
        result.reserveCapacity(5)
        for link in links where result.count < 5 {
            let searchable = [link.title, link.url, link.siteName ?? "", link.details ?? ""]
                .joined(separator: " ")
            if searchable.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                result.append(link.id)
            }
        }
        searchResultIDs = result
    }

    // MARK: - Presentación

    private func displayTitle(_ link: Bookmark) -> String {
        let title = link.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? (host(for: link).isEmpty ? "Enlace sin título" : host(for: link)) : title
    }

    private func host(for link: Bookmark) -> String {
        if link.platform == .local { return "Documento local" }
        if let host = URLComponents(string: link.url)?.host, !host.isEmpty {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        return link.siteName ?? "Enlace"
    }

    private func mapPoint(_ point: ConnectionMapPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: size.width * point.x, y: size.height * point.y)
    }
}
