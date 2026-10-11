import SwiftData
import SwiftUI
import StacklumeCore
import StacklumeDesignSystem

/// Repaso enfocado de los enlaces que han vuelto a estar «en fecha». Convierte `reviewAt`
/// en un flujo breve y accionable: abrir, marcar, posponer o completar sin perder contexto.
struct ReviewSessionView: View {
    let linkIDs: [Bookmark.ID]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var allLinks: [Bookmark]

    @State private var currentIndex = 0
    @State private var handledCount = 0

    private var queue: [Bookmark] {
        var byID: [Bookmark.ID: Bookmark] = [:]
        for link in allLinks where link.deletedAt == nil { byID[link.id] = link }
        return linkIDs.compactMap { byID[$0] }
    }

    private var currentLink: Bookmark? {
        guard queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    private var isComplete: Bool { currentLink == nil }

    var body: some View {
        EditorScaffold(
            title: "Repaso diario",
            confirmTitle: isComplete ? "Hecho" : "Repasado",
            cancelTitle: isComplete ? nil : "Cerrar",
            onCancel: { dismiss() },
            onConfirm: { isComplete ? dismiss() : markReviewed() }
        ) {
            Group {
                if let link = currentLink {
                    reviewContent(link)
                        .id(link.id)
                        .transition(.opacity)
                } else {
                    completionView
                }
            }
            .frame(width: 680, height: 500)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: currentIndex)
        }
    }

    private func reviewContent(_ link: Bookmark) -> some View {
        VStack(spacing: 0) {
            progressHeader
            Divider().overlay(palette.border.opacity(0.4))
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    hero(link)
                    metadata(link)
                    quickActions(link)
                    postponeActions
                }
                .padding(DesignSystem.Spacing.lg)
            }
        }
    }

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack {
                Text("Enlace \(min(currentIndex + 1, max(queue.count, 1))) de \(queue.count)")
                    .stacklumeFont(.caption.weight(.semibold))
                    .foregroundStyle(palette.textSecondary)
                Spacer()
                Text("\(handledCount) resuelto\(handledCount == 1 ? "" : "s")")
                    .stacklumeFont(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
            ProgressView(value: Double(currentIndex), total: Double(max(queue.count, 1)))
                .tint(palette.accent)
                .accessibilityLabel("Progreso del repaso")
                .accessibilityValue("\(currentIndex) de \(queue.count)")
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.sm)
    }

    private func hero(_ link: Bookmark) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.accent.opacity(0.12))
                .frame(width: 150, height: 96)
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

    @ViewBuilder
    private func metadata(_ link: Bookmark) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            if let category = link.category {
                Label(category.name, systemImage: category.icon)
                    .stacklumeFont(.caption)
                    .foregroundStyle(palette.textPrimary)
            } else {
                Label("Sin clasificar", systemImage: "tray")
                    .stacklumeFont(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
            Text("·").foregroundStyle(palette.textSecondary)
            Text("Guardado \(link.createdAt.formatted(.relative(presentation: .named)))")
                .stacklumeFont(.caption)
                .foregroundStyle(palette.textSecondary)
            if !link.tags.isEmpty {
                Text("·").foregroundStyle(palette.textSecondary)
                Text(link.tags.prefix(3).map { "#\($0.name)" }.joined(separator: "  "))
                    .stacklumeFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .stacklumeLineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)

        if let notes = link.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Label("Tus notas", systemImage: "note.text")
                    .stacklumeFont(.caption.weight(.semibold))
                    .foregroundStyle(palette.textPrimary)
                Text(notes)
                    .stacklumeFont(.callout)
                    .foregroundStyle(palette.textSecondary)
                    .stacklumeLineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DesignSystem.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func quickActions(_ link: Bookmark) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Button("Abrir original", systemImage: "arrow.up.right.square") {
                if let url = StacklumeAutomationPolicy.openableStoredURL(link.url) { openURL(url) }
            }
            .keyboardShortcut("o", modifiers: [])
            .themedHelp("Abrir original (O)")

            Button(link.isFavorite ? "Quitar favorito" : "Favorito",
                   systemImage: link.isFavorite ? "star.slash" : "star") {
                BookmarkActions.toggleFavorite(link, in: context)
            }
            .keyboardShortcut("f", modifiers: [])
            .themedHelp("Alternar favorito (F)")

            Button(link.isRead ? "Marcar pendiente" : "Marcar leído",
                   systemImage: link.isRead ? "circle" : "checkmark.circle") {
                BookmarkActions.toggleRead(link, in: context)
            }
            .keyboardShortcut("r", modifiers: [])
            .themedHelp("Alternar leído (R)")

            Spacer()
        }
        .buttonStyle(.bordered)
    }

    private var postponeActions: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("Volver a mostrar")
                .stacklumeFont(.caption.weight(.semibold))
                .foregroundStyle(palette.textSecondary)
            HStack(spacing: DesignSystem.Spacing.sm) {
                postponeButton("En 7 días", days: 7, shortcut: "1")
                postponeButton("En 30 días", days: 30, shortcut: "2")
                postponeButton("En 90 días", days: 90, shortcut: "3")
                Spacer()
            }
        }
    }

    private func postponeButton(_ title: String, days: Int, shortcut: KeyEquivalent) -> some View {
        Button(title, systemImage: "calendar.badge.clock") {
            guard let link = currentLink,
                  let date = Calendar.current.date(byAdding: .day, value: days, to: Date()) else { return }
            BookmarkActions.setReviewDate(date, for: link, in: context)
            advance()
        }
        .buttonStyle(.bordered)
        .keyboardShortcut(shortcut, modifiers: [])
        .themedHelp("\(title) (\(shortcut.character))")
    }

    private var completionView: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(palette.accent)
            Text("Repaso completado")
                .stacklumeFont(.title2.weight(.bold))
                .foregroundStyle(palette.textPrimary)
            Text("Has resuelto \(handledCount) enlace\(handledCount == 1 ? "" : "s"). Los pospuestos volverán a aparecer en la fecha elegida.")
                .stacklumeFont(.callout)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func displayTitle(_ link: Bookmark) -> String {
        link.title.isEmpty ? link.url.urlHost : link.title
    }

    private func markReviewed() {
        guard let link = currentLink else { return }
        BookmarkActions.setReviewDate(nil, for: link, in: context)
        advance()
    }

    private func advance() {
        handledCount += 1
        currentIndex += 1
    }
}
