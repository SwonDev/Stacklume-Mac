import SwiftUI
import SwiftData
import AppKit
import StacklumeCore

/// Petición de «Abrir todos los enlaces» pendiente de confirmación (cuando son muchos).
/// Compartida por el sidebar (por colección) y la cabecera de la lista (por sección).
struct OpenAllRequest: Identifiable {
    let id = UUID()
    let name: String
    let urls: [URL]
}

/// Menú contextual RICO de un enlace, reutilizado por la Lista, la Cuadrícula y el
/// Moodboard (antes la Cuadrícula solo ofrecía favorito/papelera). Abrir original,
/// copiar enlace, editar, favorito, archivar, estado de lectura y papelera. Lee el
/// contexto/acciones del entorno, así que sirve dentro de cualquier `.contextMenu { }`.
struct LinkContextMenu: View {
    let link: Bookmark
    /// Taxonomía INYECTADA por el contenedor (consultada UNA vez), NO con `@Query` propio: en
    /// macOS el menú contextual se construye EAGER al aparecer cada fila, así que un `@Query`
    /// aquí disparaba una consulta (¡cientos de etiquetas!) por CADA fila al hacer scroll →
    /// 100% CPU. Con los datos inyectados, crear el menú por fila es barato.
    var collections: [BookmarkCategory] = []
    var tags: [Tag] = []
    var projects: [Project] = []
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(LibraryActions.self) private var actions
    @AppStorage(ProjectWorkspaceStore.storageKey) private var workspaceJSON = ""

    var body: some View {
        if let url = StacklumeAutomationPolicy.openableStoredURL(link.url) {
            Button("Vista rápida", systemImage: "eye") { actions.quickLook(url, offlineHTML: link.offlineHTML) }
            Button("Abrir original", systemImage: "arrow.up.right.square") { openURL(url) }
        }
        Button("Copiar enlace", systemImage: "doc.on.doc") {
            NSPasteboard.copyString(link.url)
        }
        Button("Copiar como Markdown", systemImage: "text.badge.checkmark") {
            let title = link.title.isEmpty ? link.url.urlHost : link.title
            NSPasteboard.copyString("[\(title)](\(link.url))")
        }
        // Archivado PERMANENTE en internet (Wayback Machine), distinto del «Archivar» de la app
        // (que solo cambia el estado local). Acción explícita; manda la URL a archive.org.
        if WaybackStore.isArchived(link.url) {
            Button("Ver copia archivada (Wayback)", systemImage: "checkmark.seal") {
                if let snap = WaybackArchive.snapshotURL(for: link.url) { openURL(snap) }
            }
        } else {
            Button("Archivar en la Wayback Machine", systemImage: "clock.arrow.circlepath") {
                Task { await WaybackArchive.archive(link.url) }
            }
        }
        Divider()
        Button("Editar", systemImage: "pencil") { actions.edit(link) }
        Button(link.isFavorite ? "Quitar de favoritos" : "Favorito",
               systemImage: link.isFavorite ? "star.slash" : "star") {
            BookmarkActions.toggleFavorite(link, in: context)
        }
        Button(link.isArchived ? "Desarchivar" : "Archivar", systemImage: "archivebox") {
            BookmarkActions.toggleArchive(link, in: context)
        }
        Menu("Mover a colección", systemImage: "folder") {
            Button("Buscar colección…", systemImage: "magnifyingglass") { actions.pickCollection(for: link) }
            Divider()
            Button("Sin colección") { move(to: nil) }
            if !collections.isEmpty { Divider() }
            // Ordenadas ALFABÉTICAMENTE: una lista larga es mucho más fácil de recorrer así
            // que en el orden manual/de inserción.
            ForEach(collections.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }) { collection in
                Button(collection.name) { move(to: collection) }
            }
        }
        Menu("Etiquetar", systemImage: "tag") {
            // Buscador (hoja con List perezosa) en vez de listar TODAS las etiquetas inline: con
            // miles, macOS construía el menú EAGER con un fault de `link.tags` por etiqueta → el
            // menú contextual CONGELABA la app al abrirse. Aquí solo se listan las etiquetas que el
            // enlace YA tiene (pocas, para quitarlas); para añadir se usa el buscador.
            Button("Buscar o añadir etiqueta…", systemImage: "magnifyingglass") { actions.pickTags(for: link) }
            let current = link.tags.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            if !current.isEmpty {
                Divider()
                ForEach(current) { tag in
                    Button(role: .destructive) {
                        BookmarkActions.bulkRemoveTag(tag, from: [link], in: context)
                    } label: {
                        Label("Quitar «\(tag.name)»", systemImage: "checkmark")
                    }
                }
            }
        }
        if !projects.isEmpty {
            Menu("Añadir a proyecto", systemImage: "folder.badge.plus") {
                ForEach(projects.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }) { project in
                    let isMember = ProjectWorkspaceStore
                        .workspace(for: project.id, in: workspaceJSON).linkIDs.contains(link.id)
                    Button {
                        toggleProject(project, member: isMember)
                    } label: {
                        Label(project.name, systemImage: isMember ? "checkmark" : project.icon)
                    }
                }
            }
        }
        Menu("Estado de lectura", systemImage: "book") {
            Picker("Estado de lectura", selection: Binding(
                get: { link.readingStatus },
                set: { BookmarkActions.setReadingStatus($0, for: link, in: context) }
            )) {
                ForEach(ReadingStatus.allCases) { status in
                    Label(status.displayName, systemImage: status.sfSymbol).tag(status)
                }
            }
        }
        // Resurfacing «segundo cerebro»: programa cuándo debe REAPARECER en «Para repasar».
        Menu("Repasar más tarde", systemImage: "arrow.triangle.2.circlepath") {
            Button("En 3 días") { scheduleReview(days: 3) }
            Button("En 1 semana") { scheduleReview(days: 7) }
            Button("En 2 semanas") { scheduleReview(days: 14) }
            Button("En 1 mes") { scheduleReview(days: 30) }
            if link.reviewAt != nil {
                Divider()
                Button("Quitar repaso", role: .destructive) {
                    BookmarkActions.setReviewDate(nil, for: link, in: context)
                }
            }
        }
        Divider()
        Button("Mover a la papelera", systemImage: "trash", role: .destructive) {
            BookmarkActions.moveToTrash(link, in: context)
        }
    }

    /// Programa el repaso del enlace para dentro de `days` días.
    private func scheduleReview(days: Int) {
        let date = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        BookmarkActions.setReviewDate(date, for: link, in: context)
    }

    private func move(to category: BookmarkCategory?) {
        guard link.category?.id != category?.id else { return }
        link.category = category
        LinkIngest.userChangedOrganization(link.id)
        link.updatedAt = Date()
        context.saveLogging()
    }

    /// Añade o quita el enlace del espacio de trabajo de un proyecto (membresía en
    /// `@AppStorage`, sin tocar el esquema read-only). Ver [[ProjectWorkspaceStore]].
    private func toggleProject(_ project: Project, member: Bool) {
        let id = link.id
        workspaceJSON = ProjectWorkspaceStore.updating(workspaceJSON, for: project.id) { ws in
            if member {
                ws.linkIDs.removeAll { $0 == id }
            } else if !ws.linkIDs.contains(id) {
                ws.linkIDs.append(id)
            }
        }
    }
}
