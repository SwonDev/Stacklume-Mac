import SwiftUI
import StacklumeCore
import StacklumeDesignSystem

/// Cabecera de búsqueda común a las hojas de lote: campo enfocado al aparecer con icono
/// de lupa y botón de limpiar. Mantiene el estilo del resto de la app (palette + Liquid Glass).
private struct PickerSearchHeader: View {
    let placeholder: String
    @Binding var query: String
    @FocusState.Binding var focused: Bool
    @Environment(\.themePalette) private var palette

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(palette.textSecondary)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .focused($focused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(palette.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Limpiar búsqueda")
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(palette.border.opacity(0.5), lineWidth: 0.5)
        )
        .padding(DesignSystem.Spacing.md)
    }
}

/// Hoja buscable para **mover en lote a una colección**. Se abre desde el menú de lote
/// cuando hay muchas colecciones (escala mejor que una lista plana en un `Menu`, paridad
/// Raindrop). Devuelve la colección elegida —o `nil` («Sin clasificar»)— por `onPick`.
struct BulkCollectionPickerSheet: View {
    let collections: [BookmarkCategory]
    let title: String
    let noneLabel: String
    let onPick: (BookmarkCategory?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    init(collections: [BookmarkCategory], count: Int,
         onPick: @escaping (BookmarkCategory?) -> Void) {
        self.collections = collections
        self.title = "Mover \(count) a colección"
        self.noneLabel = "Sin clasificar"
        self.onPick = onPick
    }

    init(collections: [BookmarkCategory], title: String, noneLabel: String,
         onPick: @escaping (BookmarkCategory?) -> Void) {
        self.collections = collections
        self.title = title
        self.noneLabel = noneLabel
        self.onPick = onPick
    }

    private var filtered: [BookmarkCategory] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty ? collections : collections.filter { $0.name.localizedCaseInsensitiveContains(q) }
        // Siempre ALFABÉTICO: más fácil de recorrer con muchas colecciones.
        return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        EditorScaffold(title: title, confirmTitle: "Cerrar", cancelTitle: nil,
                       onCancel: { dismiss() }, onConfirm: { dismiss() }) {
            VStack(spacing: 0) {
                PickerSearchHeader(placeholder: "Buscar colección…", query: $query, focused: $searchFocused)
                List {
                    Button { onPick(nil); dismiss() } label: {
                        Label(noneLabel, systemImage: "tray")
                            .foregroundStyle(palette.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(noneLabel)
                    .listRowBackground(palette.surface)
                    if !filtered.isEmpty {
                        Section {
                            ForEach(filtered) { collection in
                                Button { onPick(collection); dismiss() } label: {
                                    Label(collection.name, systemImage: collection.icon)
                                        .lineLimit(1)
                                        .foregroundStyle(palette.textPrimary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(collection.name)
                                .listRowBackground(palette.surface)
                            }
                        }
                    } else {
                        Text("Sin resultados")
                            .foregroundStyle(palette.textSecondary)
                            .listRowBackground(palette.surface)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(palette.background)
                .accessibilityElement(children: .contain)
            }
        }
        .frame(width: 380, height: 460)
        .task { searchFocused = true }
        .onExitCommand { dismiss() }
    }
}

/// Hoja buscable para **etiquetar en lote**. Tocar una etiqueta la añade a todos los
/// enlaces seleccionados (paridad con el menú «Etiquetar», pero buscable y multi-añadido:
/// la hoja sigue abierta y marca las ya añadidas en esta sesión). Quitar etiquetas vive en
/// su propio menú «Quitar etiqueta», así que aquí solo se añade.
struct BulkTagPickerSheet: View {
    let tags: [Tag]
    let count: Int
    let onAdd: (Tag) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @State private var query = ""
    @State private var added: Set<UUID> = []
    @FocusState private var searchFocused: Bool

    private var filtered: [Tag] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty ? tags : tags.filter { $0.name.localizedCaseInsensitiveContains(q) }
        // Siempre ALFABÉTICO: más fácil de recorrer con miles de etiquetas.
        return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        EditorScaffold(title: "Etiquetar \(count)", confirmTitle: "Hecho", cancelTitle: nil,
                       onCancel: { dismiss() }, onConfirm: { dismiss() }) {
            VStack(spacing: 0) {
                PickerSearchHeader(placeholder: "Buscar etiqueta…", query: $query, focused: $searchFocused)
                List {
                    if filtered.isEmpty {
                        Text("Sin resultados")
                            .foregroundStyle(palette.textSecondary)
                            .listRowBackground(palette.surface)
                    } else {
                        ForEach(filtered) { tag in
                            let isAdded = added.contains(tag.id)
                            Button {
                                onAdd(tag)
                                added.insert(tag.id)
                            } label: {
                                HStack {
                                    Image(systemName: "number")
                                        .foregroundStyle(Color(hex: tag.colorHex))
                                    Text(tag.name).lineLimit(1).foregroundStyle(palette.textPrimary)
                                    Spacer()
                                    if isAdded {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(palette.accent)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isAdded)
                            .accessibilityLabel(tag.name)
                            .accessibilityValue(isAdded ? "Añadida" : "Sin añadir")
                            .accessibilityAddTraits(isAdded ? .isSelected : [])
                            .listRowBackground(palette.surface)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(palette.background)
                .accessibilityElement(children: .contain)
            }
        }
        .frame(width: 380, height: 460)
        .task { searchFocused = true }
        .onExitCommand { dismiss() }
    }
}
