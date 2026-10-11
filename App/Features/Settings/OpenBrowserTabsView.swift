import SwiftData
import SwiftUI
import StacklumeCore
import StacklumeDesignSystem

/// Importación selectiva de pestañas abiertas. Mantiene al usuario en control: enseña
/// exactamente qué URL se guardará, marca duplicados y no cierra ninguna pestaña externa.
struct OpenBrowserTabsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.themePalette) private var palette
    @Query private var allLinks: [Bookmark]
    @Query(sort: \BookmarkCategory.order) private var allCategories: [BookmarkCategory]

    @State private var report: BrowserTabLoadReport?
    @State private var selectedIDs: Set<String> = []
    @State private var query = ""
    @State private var browserFilter = "all"
    @State private var selectedCategory: BookmarkCategory?
    @State private var showCategoryPicker = false
    @State private var isLoading = true
    @State private var summary: ImportSummary?
    @FocusState private var queryFocused: Bool

    private struct ImportSummary {
        let added: Int
        let skipped: Int
    }

    private var activeCategories: [BookmarkCategory] {
        allCategories.filter { $0.deletedAt == nil }
    }

    private var existingKeys: Set<String> {
        Set(allLinks.lazy.filter { $0.deletedAt == nil }.map { CanonicalURL.key($0.url) })
    }

    private var tabs: [OpenBrowserTab] { report?.tabs ?? [] }

    private var importableTabs: [OpenBrowserTab] {
        tabs.filter { !existingKeys.contains(CanonicalURL.key($0.url)) }
    }

    private var visibleTabs: [OpenBrowserTab] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return tabs.filter { tab in
            let matchesBrowser = browserFilter == "all" || tab.browserID == browserFilter
            let matchesQuery = cleanQuery.isEmpty
                || tab.title.localizedCaseInsensitiveContains(cleanQuery)
                || tab.host.localizedCaseInsensitiveContains(cleanQuery)
            return matchesBrowser && matchesQuery
        }
    }

    private var selectedTabs: [OpenBrowserTab] {
        importableTabs.filter { selectedIDs.contains($0.id) }
    }

    private var browserChoices: [(id: String, name: String)] {
        var seen = Set<String>()
        return tabs.compactMap { tab in
            guard seen.insert(tab.browserID).inserted else { return nil }
            return (tab.browserID, tab.browserName)
        }
    }

    var body: some View {
        EditorScaffold(
            title: summary == nil ? "Importar pestañas abiertas" : "Importación completada",
            confirmTitle: summary == nil ? confirmTitle : "Hecho",
            canConfirm: summary != nil || (!selectedIDs.isEmpty && !isLoading),
            cancelTitle: summary == nil ? "Cancelar" : nil,
            onCancel: { dismiss() },
            onConfirm: { summary == nil ? importSelection() : dismiss() }
        ) {
            Group {
                if let summary {
                    completionView(summary)
                } else {
                    importerContent
                }
            }
            .frame(width: 720, height: 500)
        }
        .sheet(isPresented: $showCategoryPicker) {
            BulkCollectionPickerSheet(
                collections: activeCategories,
                title: "Guardar en colección",
                noneLabel: "Sin clasificar"
            ) { selectedCategory = $0 }
            .themedSheet(palette)
        }
        .task { await reload() }
    }

    private var confirmTitle: String {
        let count = selectedIDs.count
        return count == 1 ? "Importar 1 pestaña" : "Importar \(count) pestañas"
    }

    @ViewBuilder
    private var importerContent: some View {
        if isLoading {
            VStack(spacing: DesignSystem.Spacing.md) {
                ProgressView()
                    .controlSize(.large)
                Text("Leyendo las pestañas abiertas…")
                    .stacklumeFont(.headline)
                    .foregroundStyle(palette.textPrimary)
                Text("macOS puede pedir permiso para que Stacklume consulte el navegador.")
                    .stacklumeFont(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else if tabs.isEmpty {
            emptyOrErrorView
        } else {
            VStack(spacing: 0) {
                controls
                Divider().overlay(palette.border.opacity(0.4))
                tabList
                Divider().overlay(palette.border.opacity(0.4))
                destinationBar
            }
        }
    }

    private var controls: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(palette.textSecondary)
                    TextField("Buscar por título o dominio…", text: $query)
                        .textFieldStyle(.plain)
                        .focused($queryFocused)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.textSecondary)
                        .accessibilityLabel("Limpiar búsqueda")
                    }
                }
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xs)
                .background(palette.surface,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(palette.border.opacity(0.5), lineWidth: 0.5))

                if browserChoices.count > 1 {
                    Picker("Navegador", selection: $browserFilter) {
                        Text("Todos").tag("all")
                        ForEach(browserChoices, id: \.id) { choice in
                            Text(choice.name).tag(choice.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                    .accessibilityLabel("Filtrar por navegador")
                }

                Button { Task { await reload() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .themedHelp("Volver a leer las pestañas abiertas")
                .accessibilityLabel("Actualizar pestañas")
            }

            HStack {
                Text(selectionDescription)
                    .stacklumeFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                Spacer()
                Button(allVisibleImportableSelected ? "Quitar selección visible" : "Seleccionar visibles") {
                    toggleVisibleSelection()
                }
                .buttonStyle(.borderless)
                .disabled(visibleImportableTabs.isEmpty)
            }
        }
        .padding(DesignSystem.Spacing.md)
    }

    private var tabList: some View {
        let savedKeys = existingKeys
        return List(visibleTabs) { tab in
            let alreadySaved = savedKeys.contains(CanonicalURL.key(tab.url))
            Toggle(isOn: selectionBinding(for: tab)) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: tab.browserIcon)
                        .foregroundStyle(palette.accent)
                        .frame(width: 24, height: 24)
                        .background(palette.accent.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tab.title)
                            .stacklumeFont(.callout)
                            .foregroundStyle(palette.textPrimary)
                            .stacklumeLineLimit(1)
                        Text("\(tab.host) · \(tab.browserName)")
                            .stacklumeFont(.caption2)
                            .foregroundStyle(palette.textSecondary)
                            .stacklumeLineLimit(1)
                    }
                    Spacer(minLength: DesignSystem.Spacing.sm)
                    if alreadySaved {
                        Label("Guardada", systemImage: "checkmark.circle.fill")
                            .stacklumeFont(.caption2)
                            .foregroundStyle(palette.textSecondary)
                    } else if tab.isActive {
                        Label("Activa", systemImage: "circle.fill")
                            .stacklumeFont(.caption2)
                            .foregroundStyle(palette.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .toggleStyle(.checkbox)
            .disabled(alreadySaved)
            .accessibilityHint(alreadySaved ? "Esta página ya está en Stacklume" : "Incluye o excluye esta pestaña del lote")
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(palette.background)
        .overlay {
            if visibleTabs.isEmpty {
                ContentUnavailableView.search(text: query)
                    .foregroundStyle(palette.textSecondary)
            }
        }
    }

    private var destinationBar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "lock.shield")
                .foregroundStyle(palette.textSecondary)
                .accessibilityHidden(true)
            Text("Solo se leen título y URL; no el contenido ni el historial.")
                .stacklumeFont(.caption2)
                .foregroundStyle(palette.textSecondary)
            if let failedCount = report?.failures.count, failedCount > 0 {
                Label("\(failedCount) navegador\(failedCount == 1 ? "" : "es") sin acceso",
                      systemImage: "exclamationmark.triangle")
                    .stacklumeFont(.caption2)
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer()
            Button {
                showCategoryPicker = true
            } label: {
                Label(selectedCategory?.name ?? "Sin clasificar",
                      systemImage: selectedCategory?.icon ?? "tray")
                    .stacklumeLineLimit(1)
            }
            .buttonStyle(.bordered)
            .themedHelp("Elegir colección de destino")
        }
        .padding(DesignSystem.Spacing.md)
    }

    private var emptyOrErrorView: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: report?.runningBrowserNames.isEmpty == false
                  ? "exclamationmark.triangle" : "macwindow")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(palette.accent)
            Text(emptyTitle)
                .stacklumeFont(.title3.weight(.semibold))
                .foregroundStyle(palette.textPrimary)
            Text(emptyMessage)
                .stacklumeFont(.callout)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 470)
            if let failures = report?.failures, !failures.isEmpty {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    ForEach(failures) { failure in
                        Label("\(failure.browserName): \(failure.message)",
                              systemImage: "exclamationmark.circle")
                            .stacklumeFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                .padding(DesignSystem.Spacing.sm)
                .background(palette.surface,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            Button("Volver a intentar", systemImage: "arrow.clockwise") {
                Task { await reload() }
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.accent)
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func completionView(_ summary: ImportSummary) -> some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(palette.accent)
            Text(summary.added == 1 ? "1 pestaña añadida" : "\(summary.added) pestañas añadidas")
                .stacklumeFont(.title2.weight(.bold))
                .foregroundStyle(palette.textPrimary)
            Text(completionMessage(summary))
                .stacklumeFont(.callout)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Label("Stacklume completará metadatos, portada y organización en segundo plano.",
                  systemImage: "sparkles")
                .stacklumeFont(.caption)
                .foregroundStyle(palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var emptyTitle: String {
        if report?.failures.isEmpty == false { return "No se pudieron leer las pestañas" }
        if report?.runningBrowserNames.isEmpty == false { return "No hay pestañas web para importar" }
        return "No hay navegadores compatibles abiertos"
    }

    private var emptyMessage: String {
        if report?.failures.isEmpty == false {
            return "Revisa el permiso de Automatización de macOS y vuelve a intentarlo."
        }
        if report?.runningBrowserNames.isEmpty == false {
            return "Las pestañas internas del navegador, como Ajustes o una página nueva, no se importan."
        }
        return "Abre Safari, Brave, Chrome, Edge, Vivaldi u Opera y vuelve a intentarlo."
    }

    private var selectionDescription: String {
        let duplicateCount = tabs.count - importableTabs.count
        let selected = selectedIDs.count == 1 ? "1 seleccionada" : "\(selectedIDs.count) seleccionadas"
        guard duplicateCount > 0 else { return selected }
        return "\(selected) · \(duplicateCount) ya guardada\(duplicateCount == 1 ? "" : "s")"
    }

    private var visibleImportableTabs: [OpenBrowserTab] {
        visibleTabs.filter { !existingKeys.contains(CanonicalURL.key($0.url)) }
    }

    private var allVisibleImportableSelected: Bool {
        !visibleImportableTabs.isEmpty && visibleImportableTabs.allSatisfy { selectedIDs.contains($0.id) }
    }

    private func selectionBinding(for tab: OpenBrowserTab) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(tab.id) },
            set: { selected in
                if selected { selectedIDs.insert(tab.id) }
                else { selectedIDs.remove(tab.id) }
            }
        )
    }

    private func toggleVisibleSelection() {
        if allVisibleImportableSelected {
            selectedIDs.subtract(visibleImportableTabs.map(\.id))
        } else {
            selectedIDs.formUnion(visibleImportableTabs.map(\.id))
        }
    }

    private func reload() async {
        isLoading = true
        let loaded = await OpenBrowserTabsLoader.load()
        report = loaded
        let currentExisting = existingKeys
        selectedIDs = Set(loaded.tabs.lazy
            .filter { !currentExisting.contains(CanonicalURL.key($0.url)) }
            .map(\.id))
        if browserFilter != "all", !loaded.tabs.contains(where: { $0.browserID == browserFilter }) {
            browserFilter = "all"
        }
        isLoading = false
        queryFocused = !loaded.tabs.isEmpty
    }

    private func importSelection() {
        let result = LinkIngest.ingestLinks(
            selectedTabs.map {
                LinkIngest.IngestItem(urlString: $0.url, suggestedTitle: $0.title)
            },
            in: context,
            category: selectedCategory,
            aiEnrich: true
        )
        summary = ImportSummary(added: result.added.count, skipped: result.skipped.count)
    }

    private func completionMessage(_ summary: ImportSummary) -> String {
        guard summary.skipped > 0 else {
            return "Las encontrarás en \(selectedCategory?.name ?? "Sin clasificar")."
        }
        return "Se omitieron \(summary.skipped) porque ya estaban en la biblioteca. Las nuevas están en \(selectedCategory?.name ?? "Sin clasificar")."
    }
}

/// Presenta el importador desde el menú Archivo sin añadir estado ni complejidad al cuerpo de
/// `RootWindowView`, que ya concentra la navegación principal.
struct OpenBrowserTabsHandler: ViewModifier {
    let palette: ThemePalette
    let theme: Theme
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .stacklumeImportOpenTabs)) { _ in
                isPresented = true
            }
            .sheet(isPresented: $isPresented) {
                OpenBrowserTabsView().themedSheet(palette, theme)
            }
    }
}
