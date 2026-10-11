import SwiftUI
import SwiftData
import StacklumeCore
import StacklumePersistence

/// Columna 2: enruta cada destino `NavTarget`. Las vistas de herramienta van dentro
/// de un `NavigationStack` para poder navegar; las de biblioteca reutilizan
/// `LibraryListView` con el filtro/alcance adecuado.
struct SectionContentView: View {
    let target: NavTarget
    @Binding var selectedLinks: Set<Bookmark.ID>
    @Environment(LibraryActions.self) private var actions
    /// Búsquedas guardadas (Smart Folders) — mismo almacén que la biblioteca.
    @AppStorage("stacklume.savedSearches") private var savedSearchesJSON = ""

    /// Colecciones activas: para resolver `.collection(id)` (nombre + descendientes).
    @Query(filter: #Predicate<BookmarkCategory> { $0.deletedAt == nil },
           sort: \BookmarkCategory.order)
    private var categories: [BookmarkCategory]

    /// Etiquetas activas: para resolver el título de `.tag(id)`.
    @Query(filter: #Predicate<Tag> { $0.deletedAt == nil }, sort: \Tag.order)
    private var tags: [Tag]

    /// Proyectos activos: para resolver `.project(id)` → su espacio de trabajo.
    @Query(filter: #Predicate<Project> { $0.deletedAt == nil }, sort: \Project.order)
    private var projects: [Project]

    var body: some View {
        NavigationStack {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch target {
        case .all:
            LibraryListView(
                title: "Todos", icon: "square.stack",
                emptyMessage: "Aún no has guardado ningún enlace. Empieza por el primero y constrúyete una biblioteca a tu medida.",
                baseFilter: LinkFilter(),
                allowsCreate: true,
                viewScope: NavTarget.all.key,
                selection: $selectedLinks)

        case .inbox:
            InboxView(selectedLinks: $selectedLinks)

        case .unsorted:
            LibraryListView(
                title: "Sin clasificar", icon: "tray",
                emptyMessage: "No hay enlaces sin clasificar. Todo está en su sitio.",
                baseFilter: unsortedFilter,
                viewScope: NavTarget.unsorted.key,
                selection: $selectedLinks)

        case .favorites:
            LibraryListView(
                title: "Favoritos", icon: "star",
                emptyMessage: "Marca tus enlaces favoritos para tenerlos siempre a un clic.",
                baseFilter: favoritesFilter,
                viewScope: NavTarget.favorites.key,
                selection: $selectedLinks)

        case .readingQueue:
            // Lista o tablero Kanban por estado de lectura (el contenedor alterna y recuerda).
            ReadingQueueView(selectedLinks: $selectedLinks)

        case .highlights:
            HighlightsView(selection: $selectedLinks)

        case .connections:
            ConnectionsView(selection: $selectedLinks)

        case .collection(let id):
            collectionView(id)

        case .tag(let id):
            tagView(id)

        case .smart(let filter):
            smartView(filter)

        case .savedSearch(let id):
            savedSearchView(id)

        case .discover:
            DiscoverView()

        case .huggingFace:
            ModelCatalogView(provider: .huggingFace)

        case .civitai:
            ModelCatalogView(provider: .civitai)

        case .x:
            XConnectView()

        case .sessions:
            SessionsView()
        case .projects:
            ProjectsView()
        case .project(let id):
            if let project = projects.first(where: { $0.id == id }) {
                ProjectWorkspaceView(project: project)
            } else {
                EmptyStateView(icon: "folder", title: "Proyecto",
                               message: "Este proyecto ya no existe.")
            }
        case .rules:
            ClassificationRulesView()
        case .stats:
            StatsView()
        case .ai:
            AIChatView()
        case .trash:
            TrashView(selection: $selectedLinks)
        }
    }

    // MARK: - Filtros base de accesos de sistema

    private var unsortedFilter: LinkFilter {
        var f = LinkFilter(); f.onlyUncategorized = true; return f
    }

    private var favoritesFilter: LinkFilter {
        var f = LinkFilter(); f.onlyFavorites = true; return f
    }

    // MARK: - Destinos de biblioteca dinámicos

    /// Biblioteca de una colección, incluyendo sus descendientes. Reúne el id de la
    /// colección + todos los ids descendientes (recorrido de `children`) y restringe
    /// la lista a ese conjunto mediante `collectionScope`.
    @ViewBuilder
    private func collectionView(_ id: UUID) -> some View {
        if let category = categories.first(where: { $0.id == id }) {
            LibraryListView(
                title: category.name, icon: category.icon,
                emptyMessage: "Esta colección aún no tiene enlaces.",
                baseFilter: LinkFilter(),
                scopedLinks: scopedLinks(for: category),
                coverImageData: category.coverImageData,
                headerTintHex: category.colorHex,
                headerSubtitle: category.details,
                viewScope: NavTarget.collection(id).key,
                selection: $selectedLinks)
        } else {
            EmptyStateView(icon: "folder", title: "Colección",
                           message: "Esta colección ya no existe.")
        }
    }

    /// Conjunto con el id de la colección y los de todos sus descendientes activos.
    private func descendantIDs(of category: BookmarkCategory) -> Set<UUID> {
        var ids: Set<UUID> = [category.id]
        var stack = category.children.filter { $0.deletedAt == nil }
        while let next = stack.popLast() {
            guard ids.insert(next.id).inserted else { continue }
            stack.append(contentsOf: next.children.filter { $0.deletedAt == nil })
        }
        return ids
    }

    /// Enlaces ACTIVOS de una colección y sus descendientes, vía la relación INVERSA
    /// (`categoria.links`): faulta SOLO el conjunto de cada colección del alcance, NO recorre ni
    /// faultea toda la biblioteca. Sustituye al post-filtro `collectionScope`, que faulteaba
    /// `.category` de CADA enlace al entrar (el coste que hacía lentas las colecciones). Como
    /// cada enlace tiene una sola colección, no hay duplicados entre las del alcance.
    private func scopedLinks(for category: BookmarkCategory) -> [Bookmark] {
        let scope = descendantIDs(of: category)
        var out: [Bookmark] = []
        for cat in categories where scope.contains(cat.id) {
            out.append(contentsOf: cat.links.filter { $0.deletedAt == nil })
        }
        return out
    }

    /// Biblioteca de una etiqueta, vía la relación INVERSA (`tag.links`): una sola faulta del
    /// conjunto de la etiqueta, en vez de `filter.tagID` —que hacía a `filteredLinks` faultear
    /// `.tags` (relación to-many, aún más cara) de CADA enlace de la biblioteca al entrar—. Eso
    /// era lo que hacía lentas las etiquetas.
    private func tagView(_ id: UUID) -> some View {
        let tag = tags.first(where: { $0.id == id })
        let name = tag?.name ?? "Etiqueta"
        let scoped = (tag?.links ?? []).filter { $0.deletedAt == nil }
        return LibraryListView(
            title: name, icon: "number",
            emptyMessage: "Esta etiqueta aún no tiene enlaces.",
            baseFilter: LinkFilter(),
            scopedLinks: scoped,
            viewScope: NavTarget.tag(id).key,
            selection: $selectedLinks)
    }

    /// Biblioteca con un filtro inteligente aplicado (artículos, vídeos, rotos…).
    private func smartView(_ smart: SmartFilter) -> some View {
        var filter = LinkFilter(); smart.apply(to: &filter)
        return LibraryListView(
            title: smart.title, icon: smart.icon,
            emptyMessage: "No hay enlaces que coincidan con este filtro.",
            baseFilter: filter,
            viewScope: NavTarget.smart(smart).key,
            selection: $selectedLinks)
    }

    /// Smart Folder: biblioteca que arranca con la búsqueda guardada (texto + filtros)
    /// aplicada. Si la búsqueda ya no existe, cae a «Todos».
    @ViewBuilder
    private func savedSearchView(_ id: UUID) -> some View {
        if let search = SavedSearchStore.decode(savedSearchesJSON).first(where: { $0.id == id }) {
            LibraryListView(
                title: search.name, icon: "line.3.horizontal.decrease.circle",
                emptyMessage: "Nada coincide con esta búsqueda guardada.",
                baseFilter: LinkFilter(),
                viewScope: NavTarget.savedSearch(id).key,
                initialSavedSearch: search,
                selection: $selectedLinks)
        } else {
            LibraryListView(
                title: "Todos", icon: "square.stack",
                emptyMessage: "Esa búsqueda guardada ya no existe.",
                baseFilter: LinkFilter(),
                viewScope: NavTarget.all.key,
                selection: $selectedLinks)
        }
    }
}
