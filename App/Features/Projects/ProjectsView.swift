import SwiftUI
import SwiftData
import StacklumeCore
import StacklumeDesignSystem

struct ProjectsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.themePalette) private var palette
    @Query(filter: #Predicate<Project> { $0.deletedAt == nil }, sort: \Project.order)
    private var projects: [Project]
    @Query private var settingsList: [AppSettings]
    @Query private var allLinks: [Bookmark]
    @AppStorage(ProjectWorkspaceStore.storageKey) private var workspaceJSON = ""
    @State private var editor: ProjectEditorView.Mode?
    @State private var pendingDelete: Project?

    private var confirmBeforeDelete: Bool { settingsList.first?.confirmBeforeDelete ?? true }

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 14)]

    var body: some View {
        Group {
            if projects.isEmpty {
                EmptyStateView(icon: "folder", title: "Proyectos",
                               message: SidebarSection.projects.emptyMessage,
                               actionTitle: "Nuevo proyecto", action: { editor = .create })
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(projects) { proj in
                            // Navega por SELECCIÓN del sidebar (no NavigationLink): así el
                            // workspace se abre en la columna central y NUNCA se queda pegado
                            // en la columna de detalle (que es para la ficha del enlace).
                            Button {
                                NotificationCenter.default.post(
                                    name: .stacklumeGoToSection,
                                    object: NavTarget.project(proj.id).key)
                            } label: {
                                TaxonomyCard(icon: proj.icon, colorHex: proj.colorHex, name: proj.name,
                                             subtitle: subtitle(for: proj))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Editar", systemImage: "pencil") { editor = .edit(proj) }
                                Button("Eliminar", systemImage: "trash", role: .destructive) {
                                    if confirmBeforeDelete { pendingDelete = proj } else { delete(proj) }
                                }
                            }
                        }
                    }
                    .padding(DesignSystem.Spacing.lg)
                }
                .background(WindowBackground())
            }
        }
        .navigationTitle("Proyectos")
        .toolbar { ToolbarItem { Button("Nuevo proyecto", systemImage: "plus") { editor = .create }
                .themedHelp("Crear un nuevo proyecto") } }
        .sheet(item: $editor) { ProjectEditorView(mode: $0).themedSheet(palette) }
        .confirmationDialog("¿Eliminar el proyecto?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { proj in
            Button("Eliminar «\(proj.name)»", role: .destructive) { delete(proj); pendingDelete = nil }
            Button("Cancelar", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("El proyecto se moverá a un estado borrado. Los enlaces no se eliminan.")
        }
    }

    private func delete(_ proj: Project) {
        let now = Date()
        proj.deletedAt = now
        proj.updatedAt = now
        // El proyecto usa borrado lógico: conservar el workspace evita destruir de forma
        // irreversible notas, tareas, comandos y pertenencias durante una acción recuperable.
        context.saveLogging()
    }

    /// Subtítulo de la tarjeta: estado del proyecto + nº de enlaces activos.
    private func subtitle(for proj: Project) -> String {
        let ws = ProjectWorkspaceStore.workspace(for: proj.id, in: workspaceJSON)
        let activeIDs = Set(allLinks.filter { $0.deletedAt == nil }.map(\.id))
        let count = ws.linkIDs.filter { activeIDs.contains($0) }.count
        let countText = count == 0 ? "sin enlaces" : "\(count) \(count == 1 ? "enlace" : "enlaces")"
        return "\(ws.status.displayName) · \(countText)"
    }
}
