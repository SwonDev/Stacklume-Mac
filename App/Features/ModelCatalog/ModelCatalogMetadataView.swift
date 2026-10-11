import SwiftUI
import AppKit
import StacklumeDesignSystem

struct ModelCatalogMetadataSelection: Identifiable {
    let id = UUID()
    let title: String
    let data: Data
    var sourceURL: URL?
}

@MainActor enum ModelCatalogCopy {
    static func text(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    static func model(_ model: ModelCatalogItem, version: ModelCatalogVersion?) -> String {
        [model.title, model.bookmarkURL(version: version)?.absoluteString, model.author.map { "Autor: \($0)" }, model.kind.map { "Tipo: \($0)" }, version.map { "Versión: \($0.name)" },
         "Licencias: " + model.licenses(for: version).joined(separator: ", "), "Etiquetas: " + model.tags(for: version).joined(separator: ", "),
         model.metadataMatches(version: version) ? model.description : nil, version?.description, version.map { "Activadores: " + $0.trainedWords.joined(separator: ", ") }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

struct ModelCatalogMetadataView: View {
    let selection: ModelCatalogMetadataSelection
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @State private var document: ModelCatalogMetadataDocument?
    @State private var matches: [ModelCatalogMetadataDocument.Line] = []
    @State private var query = ""
    @State private var page = 0
    @State private var error: String?
    @State private var copied = false
    private let pageSize = 200
    private var visible: [ModelCatalogMetadataDocument.Line] { Array(matches.dropFirst(page * pageSize).prefix(pageSize)) }

    var body: some View {
        EditorScaffold(title: selection.title, confirmTitle: "Cerrar", cancelTitle: nil, onCancel: { dismiss() }, onConfirm: { dismiss() }) {
            VStack(spacing: DesignSystem.Spacing.sm) {
                HStack {
                    ModelCatalogField("Buscar campos o valores", text: $query)
                    Button(copied ? "Copiado" : "Copiar JSON completo") { if let document { ModelCatalogCopy.text(document.text); copied = true } }
                        .stacklumeButton(prominent: false).disabled(document == nil).themedHelp("Copiar todos los metadatos recibidos, incluidos los campos que no aparecen en la ficha resumida")
                }
                .padding(.horizontal, DesignSystem.Spacing.md)
                if let source = selection.sourceURL { Link("Fuente original", destination: source).stacklumeFont(.caption) }
                Text("JSON completo de esta respuesta del proveedor. La búsqueda y las páginas son locales.")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                if let error { Text(error).foregroundStyle(palette.textPrimary).padding() }
                else if document == nil { ProgressView("Preparando metadatos…").tint(palette.accent).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else {
                    ScrollView([.horizontal, .vertical]) {
                        // La página ya está acotada; el scroll bidireccional necesita el ancho intrínseco de todas sus filas.
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(visible) { line in
                                HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                                    Text(line.id.formatted()).foregroundStyle(palette.textSecondary).monospacedDigit()
                                    Text(line.text).foregroundStyle(palette.textPrimary).textSelection(.enabled)
                                }
                                .stacklumeFont(.system(.caption, design: .monospaced))
                                .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        .padding(DesignSystem.Spacing.md)
                    }
                    .background(palette.surface)
                    HStack {
                        Text("\(matches.count.formatted()) líneas coincidentes de \(document?.lines.count.formatted() ?? "0") · página \(page + 1)").stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                        Spacer()
                        Button("Anterior") { page -= 1 }.stacklumeButton(prominent: false).disabled(page == 0)
                        Button("Siguiente") { page += 1 }.stacklumeButton(prominent: false).disabled((page + 1) * pageSize >= matches.count)
                    }
                    .padding(DesignSystem.Spacing.md)
                }
            }
            .padding(.top, DesignSystem.Spacing.sm)
        }
        .presentationSizing(.fitted)
        .frame(minWidth: 480, idealWidth: 1_000, maxWidth: 1_300, minHeight: 400, idealHeight: 760, maxHeight: 1_000)
        .onExitCommand { dismiss() }
        .task {
            do {
                let data = selection.data
                let value = try await Task.detached(priority: .userInitiated) { try ModelCatalogMetadataDocument(data: data) }.value
                try Task.checkCancellation(); document = value; matches = value.matching(query)
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .task(id: query) {
            guard let document else { return }
            let search = query
            let value = await Task.detached(priority: .userInitiated) { document.matching(search) }.value
            guard !Task.isCancelled else { return }; matches = value; page = 0
        }
    }
}

struct ModelCatalogArtifactActions: View {
    let favorite: ModelCatalogFavorite
    @Environment(\.themePalette) private var palette
    @Environment(\.appTheme) private var theme
    @State private var isFavorite = false
    @State private var error: String?
    @State private var saveSelection: ModelCatalogSaveSelection?
    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignSystem.Spacing.xs) { buttons }
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) { buttons }
            }
            if let error { Text(error).stacklumeFont(.caption).foregroundStyle(palette.textSecondary) }
        }
        .task(id: favorite.id) {
            do { isFavorite = try ModelCatalogFavorites.load().contains { $0.id == favorite.id }; error = nil }
            catch { self.error = error.localizedDescription }
        }
        .sheet(item: $saveSelection) { selection in ModelCatalogSaveSheet(selection: selection).themedSheet(palette, theme) }
    }
    @ViewBuilder private var buttons: some View {
                Button {
                    do { isFavorite = try ModelCatalogFavorites.toggle(favorite); error = nil }
                    catch { self.error = error.localizedDescription }
                } label: { Label(isFavorite ? "Favorito" : "Añadir favorito", systemImage: isFavorite ? "star.fill" : "star") }
                    .stacklumeButton(prominent: false).themedHelp("Favorito local de este ejemplo o publicación en el catálogo")
                Button("Organizar/Guardar…") { saveSelection = .favorite(favorite) }.stacklumeButton(prominent: false)
                Button("Copiar ejemplo") { ModelCatalogCopy.text([favorite.title, ModelCatalogSaveSelection.favorite(favorite).details].compactMap { $0 }.joined(separator: "\n\n")) }
                    .stacklumeButton(prominent: false)
    }
}
