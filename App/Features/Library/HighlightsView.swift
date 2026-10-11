import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import StacklumeCore
import StacklumeDesignSystem

/// Vista global de Resaltados (paridad con la colección «Highlights» de Raindrop):
/// reúne TODOS los resaltados de la biblioteca, agrupados por enlace y ordenados por
/// el resaltado más reciente. Tocar un grupo o un resaltado revela la ficha del
/// enlace en la columna de detalle; el menú contextual permite copiar o abrir.
struct HighlightsView: View {
    /// Selección de la columna de detalle (al tocar un resaltado se revela su enlace).
    @Binding var selection: Set<Bookmark.ID>
    @Environment(\.themePalette) private var palette
    @Environment(\.openURL) private var openURL

    @Query(filter: #Predicate<Bookmark> { $0.deletedAt == nil })
    private var links: [Bookmark]

    /// Resaltado en edición (cita + nota), presentado en una hoja.
    @State private var editorMode: HighlightEditorView.Mode?

    /// Enlaces activos con al menos un resaltado, ordenados por el resaltado más reciente.
    private var entries: [Bookmark] {
        // Decorate-sort: calcula la fecha del resaltado más reciente UNA vez por enlace
        // (antes el comparador la recalculaba en cada comparación → O(n² log n)).
        links
            .filter { !$0.highlights.isEmpty }
            .map { ($0, $0.highlights.map(\.createdAt).max() ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Total de resaltados (para la subfila del encabezado).
    private var totalCount: Int { entries.reduce(0) { $0 + $1.highlights.count } }

    var body: some View {
        Group {
            if entries.isEmpty {
                EmptyStateView(
                    icon: "highlighter", title: "Resaltados",
                    message: "Aún no has guardado resaltados. Abre un enlace y guarda fragmentos o cítalos con «+».")
            } else {
                content
            }
        }
        .navigationTitle("Resaltados")
        .sheet(item: $editorMode) { HighlightEditorView(mode: $0) }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                header
                ForEach(entries) { link in
                    linkGroup(link)
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
        .background(WindowBackground())
    }

    /// Encabezado: título + recuento total + exportar a Markdown.
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Resaltados")
                    .stacklumeFont(.title2.weight(.bold))
                    .foregroundStyle(palette.textPrimary)
                Text("\(totalCount) resaltado\(totalCount == 1 ? "" : "s") en \(entries.count) enlace\(entries.count == 1 ? "" : "s")")
                    .stacklumeFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer(minLength: DesignSystem.Spacing.sm)
            Menu {
                Button("Copiar todo (Markdown)", systemImage: "doc.on.doc") {
                    NSPasteboard.copyString(HighlightExport.markdown(for: entries))
                }
                Button("Guardar como .md…", systemImage: "square.and.arrow.down") { saveMarkdown() }
            } label: {
                Label("Exportar", systemImage: "square.and.arrow.up")
                    .stacklumeFont(.callout)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(palette.accent)
            .themedHelp("Exportar los resaltados a Markdown (Obsidian/Notion)")
        }
    }

    /// Guarda los resaltados como un fichero Markdown (panel del sistema).
    @MainActor
    private func saveMarkdown() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Resaltados.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? HighlightExport.markdown(for: entries).data(using: .utf8)?.write(to: url)
    }

    /// Grupo de un enlace: cabecera (icono + título + host + abrir) y sus resaltados.
    private func linkGroup(_ link: Bookmark) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Button {
                selection = [link.id]
            } label: {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    PlatformBadge(platform: link.platform, size: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(link.title.isEmpty ? link.url.urlHost : link.title)
                            .stacklumeFont(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.textPrimary)
                            .stacklumeLineLimit(1)
                        Text(link.url.urlHost)
                            .stacklumeFont(.caption2)
                            .foregroundStyle(palette.textSecondary)
                            .stacklumeLineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button {
                        if let url = StacklumeAutomationPolicy.openableStoredURL(link.url) { openURL(url) }
                    } label: {
                        Image(systemName: "safari").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.textSecondary)
                    .themedHelp("Abrir el enlace")
                    .accessibilityLabel("Abrir el enlace")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ver resaltados de \(link.title.isEmpty ? link.url.urlHost : link.title)")

            ForEach(link.highlights.sorted { $0.createdAt < $1.createdAt }) { highlight in
                highlightCard(highlight, link: link)
            }
        }
    }

    /// Tarjeta de un resaltado: barra de color + cita, teñida con su propio color.
    /// Toda la tarjeta revela la ficha del enlace; el menú contextual copia/abre.
    private func highlightCard(_ highlight: Highlight, link: Bookmark) -> some View {
        let swatch = Color(hex: highlight.colorHex)
        return Button {
            selection = [link.id]
        } label: {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(swatch)
                    .frame(width: 4)
                VStack(alignment: .leading, spacing: 5) {
                    Text(highlight.text)
                        .stacklumeFont(.callout)
                        .foregroundStyle(palette.textPrimary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    let note = HighlightNoteStore.note(for: highlight.id)
                    if !note.isEmpty {
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "text.bubble")
                                .font(.caption2).foregroundStyle(swatch)
                            Text(note)
                                .stacklumeFont(.caption)
                                .italic()
                                .foregroundStyle(palette.textSecondary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(DesignSystem.Spacing.sm)
            .background(swatch.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(swatch.opacity(0.25), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resaltado: \(highlight.text)")
        .contextMenu {
            Button("Editar cita y nota…", systemImage: "pencil") {
                editorMode = .edit(highlight)
            }
            Button("Copiar texto", systemImage: "doc.on.doc") {
                NSPasteboard.copyString(highlight.text)
            }
            Button("Abrir el enlace", systemImage: "safari") {
                if let url = StacklumeAutomationPolicy.openableStoredURL(link.url) { openURL(url) }
            }
        }
    }
}
