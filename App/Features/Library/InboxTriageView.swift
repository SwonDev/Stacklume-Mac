import SwiftData
import SwiftUI
import StacklumeCore
import StacklumeDesignSystem
import StacklumePersistence

/// Sesión guiada para convertir capturas pendientes en decisiones concretas. Opera
/// sobre un snapshot de UUID para que el orden no salte mientras se actualiza SwiftData.
struct InboxTriageView: View {
    let linkIDs: [Bookmark.ID]
    let totalPendingAtStart: Int

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Query(filter: #Predicate<Bookmark> { $0.deletedAt == nil })
    private var allLinks: [Bookmark]
    @Query(filter: #Predicate<BookmarkCategory> { $0.deletedAt == nil },
           sort: \BookmarkCategory.order)
    private var categories: [BookmarkCategory]
    @Query(filter: #Predicate<Tag> { $0.deletedAt == nil }, sort: \Tag.order)
    private var tags: [Tag]

    @State private var currentIndex = 0
    @State private var movedToReadingCount = 0
    @State private var readCount = 0
    @State private var archivedCount = 0
    @State private var skippedCount = 0
    @State private var showCategoryPicker = false
    @State private var showTagPicker = false

    private var linkLookup: [Bookmark.ID: Bookmark] {
        var result: [Bookmark.ID: Bookmark] = [:]
        for link in allLinks where link.modelContext != nil {
            result[link.id] = link
        }
        return result
    }

    /// Salta UUID eliminados durante la sesión sin alterar el snapshot ni omitir el
    /// siguiente elemento válido.
    private var currentPair: (index: Int, link: Bookmark)? {
        let lookup = linkLookup
        guard currentIndex < linkIDs.count else { return nil }
        for index in currentIndex..<linkIDs.count {
            if let link = lookup[linkIDs[index]] { return (index, link) }
        }
        return nil
    }

    private var currentLink: Bookmark? { currentPair?.link }
    private var resolvedCount: Int { movedToReadingCount + readCount + archivedCount }

    var body: some View {
        // Resuelve el snapshot una sola vez por render. Con bibliotecas de decenas de
        // miles evita reconstruir el diccionario para título, progreso y contenido.
        let pair = currentPair
        let isComplete = pair == nil
        return EditorScaffold(
            title: "Revisar bandeja",
            confirmTitle: isComplete ? "Hecho" : "Añadir a lectura",
            cancelTitle: isComplete ? nil : "Cerrar",
            onCancel: { dismiss() },
            onConfirm: { isComplete ? dismiss() : moveToReading() }
        ) {
            Group {
                if let pair {
                    triageContent(pair.link, position: pair.index)
                        .id(pair.link.id)
                        .transition(.opacity)
                } else {
                    completionView
                }
            }
            .frame(width: 700, height: 520)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: currentIndex)
            .onKeyPress(keys: ["1"]) { _ in
                guard pair != nil else { return .ignored }
                moveToReading()
                return .handled
            }
        }
        .sheet(isPresented: $showCategoryPicker) {
            BulkCollectionPickerSheet(
                collections: categories,
                title: "Elegir colección",
                noneLabel: "Sin clasificar"
            ) { category in
                guard let link = currentLink else { return }
                BookmarkActions.bulkSetCategory(category, for: [link], in: context)
            }
            .themedSheet(palette)
        }
        .sheet(isPresented: $showTagPicker) {
            BulkTagPickerSheet(tags: tags, count: 1) { tag in
                guard let link = currentLink else { return }
                BookmarkActions.bulkAddTag(tag, to: [link], in: context)
            }
            .themedSheet(palette)
        }
    }

    private func triageContent(_ link: Bookmark, position: Int) -> some View {
        VStack(spacing: 0) {
            progressHeader(position: position)
            Divider().overlay(palette.border.opacity(0.4))
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    hero(link)
                    organization(link)
                    quickActions(link)
                    keyboardHint
                }
                .padding(DesignSystem.Spacing.lg)
            }
        }
    }

    private func progressHeader(position: Int) -> some View {
        let displayPosition = position + 1
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack {
                Text("Captura \(min(displayPosition, linkIDs.count)) de \(linkIDs.count)")
                    .stacklumeFont(.caption.weight(.semibold))
                    .foregroundStyle(palette.textSecondary)
                Spacer()
                Text("\(resolvedCount) resuelta\(resolvedCount == 1 ? "" : "s")")
                    .stacklumeFont(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
            ProgressView(value: Double(position),
                         total: Double(max(linkIDs.count, 1)))
                .tint(palette.accent)
                .accessibilityLabel("Progreso del triaje")
                .accessibilityValue("\(min(displayPosition, linkIDs.count)) de \(linkIDs.count)")
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.sm)
    }

    private func hero(_ link: Bookmark) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.accent.opacity(0.12))
                .frame(width: 156, height: 100)
                .overlay {
                    SecureRemoteImage(candidates: HDImage.candidates(link.imageURL) + [link.faviconURL]) {
                        Image(systemName: link.platform.sfSymbol)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(palette.accent)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityLabel("Portada de \(displayTitle(link))")

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(displayTitle(link))
                    .stacklumeFont(.title3.weight(.bold))
                    .foregroundStyle(palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(link.url.urlHost)
                    .stacklumeFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .stacklumeLineLimit(1)
                if let details = link.details?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !details.isEmpty {
                    Text(details)
                        .stacklumeFont(.callout)
                        .foregroundStyle(palette.textSecondary)
                        .stacklumeLineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DesignSystem.Spacing.md)
        .background(palette.surface,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(palette.border.opacity(0.5), lineWidth: 0.5))
    }

    private func organization(_ link: Bookmark) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Organización")
                .stacklumeFont(.caption.weight(.semibold))
                .foregroundStyle(palette.textSecondary)
            HStack(spacing: DesignSystem.Spacing.sm) {
                Button {
                    showCategoryPicker = true
                } label: {
                    Label(link.category?.name ?? "Sin clasificar",
                          systemImage: link.category?.icon ?? "tray")
                        .stacklumeLineLimit(1)
                }
                .buttonStyle(.bordered)
                .themedHelp("Elegir colección")

                Button("Añadir etiqueta", systemImage: "tag") {
                    showTagPicker = true
                }
                .buttonStyle(.bordered)
                .disabled(tags.isEmpty)
                .themedHelp("Buscar y añadir etiquetas")

                Spacer(minLength: 0)
            }

            if !link.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(link.tags) { tag in
                            Text("#\(tag.name)")
                                .stacklumeFont(.caption2.weight(.semibold))
                                .foregroundStyle(palette.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(palette.surface,
                                            in: Capsule(style: .continuous))
                        }
                    }
                }
                .accessibilityLabel("Etiquetas: \(link.tags.map(\.name).joined(separator: ", "))")
            }
        }
        .padding(DesignSystem.Spacing.sm)
        .background(palette.surface.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func quickActions(_ link: Bookmark) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Button("Abrir", systemImage: "arrow.up.right.square") {
                if let url = StacklumeAutomationPolicy.openableStoredURL(link.url) { openURL(url) }
            }
            .keyboardShortcut("o", modifiers: [])
            .themedHelp("Abrir original (O)")

            Button("Ya leído", systemImage: "checkmark.circle") {
                markAsRead()
            }
            .keyboardShortcut("2", modifiers: [])
            .themedHelp("Marcar como leído (2)")

            Button("Archivar", systemImage: "archivebox") {
                archive()
            }
            .keyboardShortcut("3", modifiers: [])
            .themedHelp("Archivar (3)")

            Button("Omitir", systemImage: "forward") {
                skip()
            }
            .keyboardShortcut("s", modifiers: [])
            .themedHelp("Conservar pendiente y continuar (S)")

            Spacer(minLength: 0)
        }
        .buttonStyle(.bordered)
    }

    private var keyboardHint: some View {
        Label("Intro o 1: añadir a lectura · 2: leído · 3: archivar · S: omitir",
              systemImage: "keyboard")
            .stacklumeFont(.caption2)
            .foregroundStyle(palette.textSecondary)
            .accessibilityLabel("Atajos: Intro o 1 añade a lectura; 2 marca leído; 3 archiva; S omite")
    }

    private var completionView: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(palette.accent)
            Text("Bandeja revisada")
                .stacklumeFont(.title2.weight(.bold))
                .foregroundStyle(palette.textPrimary)
            Text(completionMessage)
                .stacklumeFont(.callout)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var completionMessage: String {
        var parts: [String] = []
        if movedToReadingCount > 0 { parts.append("\(movedToReadingCount) a lectura") }
        if readCount > 0 { parts.append("\(readCount) leído\(readCount == 1 ? "" : "s")") }
        if archivedCount > 0 { parts.append("\(archivedCount) archivado\(archivedCount == 1 ? "" : "s")") }
        if skippedCount > 0 { parts.append("\(skippedCount) pendiente\(skippedCount == 1 ? "" : "s")") }
        let result = parts.isEmpty
            ? "No se modificó ningún enlace."
            : "Resultado: \(parts.joined(separator: " · "))."
        let remaining = max(0, totalPendingAtStart - resolvedCount)
        guard remaining > 0 else { return result }
        return "\(result) Quedan aproximadamente \(remaining) captura\(remaining == 1 ? "" : "s") pendiente\(remaining == 1 ? "" : "s")."
    }

    private func displayTitle(_ link: Bookmark) -> String {
        link.title.isEmpty ? link.url.urlHost : link.title
    }

    private func moveToReading() {
        guard let link = currentLink else { return }
        BookmarkActions.setReadingStatus(.reading, for: link, in: context)
        movedToReadingCount += 1
        advance()
    }

    private func markAsRead() {
        guard let link = currentLink else { return }
        BookmarkActions.markReadingDone(link, in: context)
        readCount += 1
        advance()
    }

    private func archive() {
        guard let link = currentLink else { return }
        if !link.isArchived { BookmarkActions.toggleArchive(link, in: context) }
        archivedCount += 1
        advance()
    }

    private func skip() {
        guard currentLink != nil else { return }
        skippedCount += 1
        advance()
    }

    private func advance() {
        currentIndex = (currentPair?.index ?? currentIndex) + 1
    }
}
