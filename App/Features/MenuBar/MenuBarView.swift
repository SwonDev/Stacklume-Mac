import SwiftUI
import SwiftData
import StacklumeCore
import StacklumeDesignSystem
import StacklumePersistence

/// Contenido del extra de la barra de menús (arriba a la derecha del Mac): guardado y
/// captura RÁPIDOS de enlaces sin abrir la app. Como la escena `MenuBarExtra` no hereda
/// el entorno de la ventana principal, este wrapper inyecta el tema activo (igual que
/// `SettingsView`/`HelpView`) y delega la UI en `MenuBarContent`.
struct MenuBarView: View {
    @Environment(\.colorScheme) private var systemScheme
    @Query private var settings: [AppSettings]
    @AppStorage("stacklume.accentHex") private var accentHex = ""

    private var theme: Theme { Theme(rawValue: settings.first?.themeID ?? "dark") ?? .dark }
    private var palette: ThemePalette {
        var palette = theme.palette(systemScheme: systemScheme)
        if !accentHex.isEmpty { palette.accent = Color(hex: accentHex) }
        return palette
    }

    var body: some View {
        MenuBarContent()
            .frame(width: 330)
            .environment(\.themePalette, palette)
            .environment(\.appTheme, theme)
            .preferredColorScheme(theme.preferredColorScheme)
            .tooltipLayer(palette)
    }
}

/// UI del popover (lee `themePalette` ya inyectado por el wrapper).
private struct MenuBarContent: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Query private var recentLinks: [Bookmark]
    @Query private var collections: [BookmarkCategory]

    @State private var urlText = ""
    @State private var clipboardURL: String?
    @State private var saveFeedback: SaveFeedback?
    /// Organización al vuelo del guardado rápido (opcional).
    @State private var note = ""
    @State private var collectionID: UUID?
    @State private var showCollectionPicker = false
    @State private var lastClipboardChange = -1

    private struct SaveFeedback: Equatable {
        let message: String
        let systemImage: String
    }

    init() {
        // Últimos 6 guardados activos (más recientes primero).
        var descriptor = FetchDescriptor<Bookmark>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 6
        _recentLinks = Query(descriptor)
        _collections = Query(filter: #Predicate<BookmarkCategory> { $0.deletedAt == nil },
                             sort: \BookmarkCategory.order)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            header
            clipboardCard
            pasteRow
            organizeRow
            if let saveFeedback {
                Label(saveFeedback.message, systemImage: saveFeedback.systemImage)
                    .stacklumeFont(.caption.weight(.semibold))
                    .foregroundStyle(palette.accent)
                    .transition(.opacity)
            }
            if !recentLinks.isEmpty {
                Divider().overlay(palette.border.opacity(0.4))
                recentSection
            }
            Divider().overlay(palette.border.opacity(0.4))
            footer
        }
        .padding(DesignSystem.Spacing.md)
        .background(palette.background)
        .onAppear(perform: refreshClipboard)
        .onReceive(NotificationCenter.default.publisher(for: .stacklumeModelDidSave)) { _ in
            lastClipboardChange = -1
            refreshClipboard()
        }
        .sheet(isPresented: $showCollectionPicker) {
            BulkCollectionPickerSheet(
                collections: collections,
                title: "Guardar en colección",
                noneLabel: "Sin clasificar"
            ) { collectionID = $0?.id }
            .themedSheet(palette)
        }
        // Refresca el portapapeles mientras el popover está abierto: si copias un enlace con el
        // popover delante, la tarjeta «Guardar del portapapeles» aparece al instante.
        .task {
            while !Task.isCancelled {
                refreshClipboard()
                try? await Task.sleep(for: .milliseconds(800))
            }
        }
    }

    // MARK: - Secciones

    private var header: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image("StacklumeLogo")
                .resizable().scaledToFit()
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text("Stacklume").stacklumeFont(.headline).foregroundStyle(palette.textPrimary)
                Text("Guardado rápido").stacklumeFont(.caption2).foregroundStyle(palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// Tarjeta de la URL del portapapeles (si hay una nueva y no está ya en la biblioteca).
    @ViewBuilder
    private var clipboardCard: some View {
        if let url = clipboardURL {
            Button {
                save(url)
            } label: {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    SecureRemoteImage(candidates: [faviconURL(for: url)]) {
                        Image(systemName: "doc.on.clipboard.fill").foregroundStyle(palette.accent)
                    }
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Guardar del portapapeles").stacklumeFont(.callout.weight(.semibold))
                            .foregroundStyle(palette.textPrimary)
                        Text(url.urlHost).stacklumeFont(.caption2).foregroundStyle(palette.textSecondary).stacklumeLineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "plus.circle.fill").foregroundStyle(palette.accent)
                }
                .padding(DesignSystem.Spacing.sm)
                .frame(maxWidth: .infinity)
                .background(palette.accent.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(palette.accent.opacity(0.3), lineWidth: 0.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Fila para pegar/escribir una URL y guardarla.
    private var pasteRow: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            TextField("Pega una URL…", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveTypedURL() }
            Button("Guardar") { saveTypedURL() }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .disabled(normalizedURL(urlText) == nil)
        }
    }

    /// Organización OPCIONAL al vuelo: colección destino + nota inicial. Se aplica al
    /// guardar (tanto desde la tarjeta del portapapeles como desde el campo de URL).
    private var organizeRow: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            if !collections.isEmpty {
                Button {
                    showCollectionPicker = true
                } label: {
                    Label(selectedCollection?.name ?? "Sin clasificar",
                          systemImage: selectedCollection?.icon ?? "tray")
                        .stacklumeLineLimit(1)
                }
                .buttonStyle(.bordered)
                .themedHelp("Elegir colección de destino")
            }
            TextField("Nota (opcional)…", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recientes").stacklumeFont(.caption.weight(.semibold)).foregroundStyle(palette.textSecondary)
            ForEach(recentLinks) { link in
                Button {
                    if let url = StacklumeAutomationPolicy.openableStoredURL(link.url) { openURL(url) }
                } label: {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        SecureRemoteImage(candidates: [link.faviconURL]) {
                            Image(systemName: link.platform.sfSymbol)
                                .font(.caption2).foregroundStyle(palette.textSecondary)
                        }
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        Text(link.title.isEmpty ? link.url.urlHost : link.title)
                            .stacklumeFont(.caption).foregroundStyle(palette.textPrimary).stacklumeLineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button { openMainApp() } label: {
                Label("Abrir Stacklume", systemImage: "macwindow")
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.accent)
            Spacer(minLength: 0)
            Button { NSApplication.shared.terminate(nil) } label: {
                Text("Salir").foregroundStyle(palette.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .stacklumeFont(.callout)
    }

    // MARK: - Acciones

    private func refreshClipboard() {
        guard lastClipboardChange != ClipboardLink.changeCount else { return }
        lastClipboardChange = ClipboardLink.changeCount
        let candidate = ClipboardLink.currentURLString()
        clipboardURL = candidate.flatMap { isInLibrary($0) ? nil : $0 }
    }

    private func saveTypedURL() {
        guard let url = normalizedURL(urlText) else { return }
        save(url)
        urlText = ""
    }

    private func save(_ urlString: String) {
        let result = LinkIngest.ingestLinks(
            [LinkIngest.IngestItem(urlString: urlString)],
            in: context,
            category: selectedCollection,
            aiEnrich: true
        )
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let link = result.added.first {
            // Solo el alta NUEVA recibe la nota/colección elegidas. Un duplicado nunca
            // debe sobrescribir silenciosamente datos de un enlace existente.
            if !trimmedNote.isEmpty { link.notes = trimmedNote }
            context.saveLogging()
            MenuBarController.shared.pulse()
            showFeedback("Guardado · \(urlString.urlHost)", systemImage: "checkmark.circle.fill")
        } else {
            showFeedback("Ya estaba guardado · \(urlString.urlHost)",
                         systemImage: "checkmark.circle")
        }
        note = ""
        if clipboardURL == urlString { clipboardURL = nil }
        MenuBarController.shared.suggestClipboard(nil)
    }

    private var selectedCollection: BookmarkCategory? {
        guard let collectionID else { return nil }
        return collections.first { $0.id == collectionID }
    }

    private func showFeedback(_ message: String, systemImage: String) {
        withAnimation(.snappy) {
            saveFeedback = SaveFeedback(message: message, systemImage: systemImage)
        }
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard saveFeedback?.message == message else { return }
            withAnimation(.snappy) { saveFeedback = nil }
        }
    }

    /// Normaliza una entrada a una URL `http(s)` válida (antepone `https://` si falta el
    /// esquema). Devuelve `nil` si no parece una URL con host.
    private func normalizedURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        return StacklumeAutomationPolicy.openableStoredURL(withScheme)?.absoluteString
    }

    private func isInLibrary(_ urlString: String) -> Bool {
        SavedLinkLookup.shared.contains(urlString, in: context)
    }

    private func openMainApp() {
        MenuBarController.shared.showMainWindow()
    }

    private func faviconURL(for urlString: String) -> String {
        "https://www.google.com/s2/favicons?domain=\(urlString.urlHost)&sz=128"
    }
}
