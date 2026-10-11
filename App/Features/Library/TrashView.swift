import SwiftUI
import SwiftData
import StacklumeCore
import StacklumeDesignSystem

/// Papelera: enlaces borrados lógicamente. Restaurar o eliminar definitivamente.
/// Igual que el resto de secciones, permite SELECCIÓN (uno o varios con ⌘/⇧-clic) con el MISMO
/// resaltado temático que la biblioteca (`ThemedSelectionBackground` + supresor del resaltado
/// nativo): el enlace único seleccionado se muestra en la columna de detalle (la ficha sale aunque
/// esté borrado, porque `DetailColumn` no filtra por `deletedAt`), y las acciones del menú
/// contextual operan sobre TODA la selección cuando hay varios marcados.
struct TrashView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.themePalette) private var palette
    /// Selección compartida con la ventana (la MISMA que la biblioteca): así el detalle muestra
    /// el enlace marcado y la selección se limpia al cambiar de sección.
    @Binding var selection: Set<Bookmark.ID>
    @Query(filter: #Predicate<Bookmark> { $0.deletedAt != nil }, sort: \Bookmark.deletedAt, order: .reverse)
    private var trashed: [Bookmark]

    /// Enlaces sobre los que actúa el menú: la selección entera si la fila pulsada está dentro de
    /// una selección múltiple; si no, solo esa fila (comportamiento nativo de macOS).
    private func targets(for link: Bookmark) -> [Bookmark] {
        if selection.contains(link.id), selection.count > 1 {
            return trashed.filter { selection.contains($0.id) }
        }
        return [link]
    }

    var body: some View {
        Group {
            if trashed.isEmpty {
                EmptyStateView(icon: "trash", title: "Papelera", message: SidebarSection.trash.emptyMessage)
            } else {
                List(selection: $selection) {
                    // Fila invisible que SUPRIME el resaltado nativo de macOS (azul del sistema),
                    // para que la selección use el estilo del tema. Mismo patrón que LibraryListView.
                    Color.clear.frame(height: 0)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .suppressNativeListSelectionHighlight()
                    ForEach(trashed) { link in
                        LinkRowView(link: link)
                            .tag(link.id)
                            .listRowInsets(EdgeInsets(
                                top: 0, leading: DesignSystem.Spacing.sm,
                                bottom: 0, trailing: DesignSystem.Spacing.sm))
                            .listRowSeparator(.hidden)
                            // Resaltado temático IDÉNTICO al de la biblioteca (fondo + borde del acento).
                            .listRowBackground(ThemedSelectionBackground(
                                isSelected: selection.contains(link.id), accent: palette.accent))
                            .contextMenu {
                                let items = targets(for: link)
                                Button(items.count > 1 ? "Restaurar \(items.count)" : "Restaurar",
                                       systemImage: "arrow.uturn.backward") {
                                    for l in items where l.modelContext != nil {
                                        BookmarkActions.restore(l, in: context)
                                    }
                                    selection.removeAll()
                                }
                                Button(items.count > 1 ? "Eliminar \(items.count) definitivamente"
                                                       : "Eliminar definitivamente",
                                       systemImage: "trash", role: .destructive) {
                                    BookmarkActions.deleteForever(items, in: context)
                                    selection.removeAll()
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(WindowBackground())
            }
        }
        .navigationTitle("Papelera")
        .toolbar {
            if !trashed.isEmpty {
                ToolbarItem {
                    Button("Vaciar papelera", systemImage: "trash.slash", role: .destructive) {
                        // Guarda: no re-eliminar un objeto ya borrado del store (evita estado
                        // indefinido si se borró individualmente a la vez).
                        BookmarkActions.deleteForever(trashed, in: context)
                    }
                }
            }
        }
    }
}
