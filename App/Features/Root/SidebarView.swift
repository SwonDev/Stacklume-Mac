import SwiftUI
import SwiftData
import AppKit
import StacklumeCore
import StacklumeDesignSystem
import StacklumeMetadata
import StacklumePersistence

/// Columna 1: sidebar premium estilo raindrop, reorganizado para reducir la
/// saturación visual (feedback del usuario). Jerarquía en dos niveles:
///
/// **Siempre visible (lo esencial):** «Todos», «Bandeja» y el «Asistente IA» como
/// entradas universales; después, vistas de Biblioteca y Explorar con rótulos claros,
/// seguidas del **árbol de Colecciones** (el corazón de la navegación).
///
/// **Grupos colapsables (lo secundario), COLAPSADOS por defecto:** Etiquetas,
/// Filtros (SmartFilter) y Herramientas (Sesiones/Reglas/Estadísticas).
/// Su estado de expansión se recuerda con `@AppStorage` (convención `stacklume.*`).
///
/// La acción principal («Nuevo enlace») queda fijada abajo como botón de cristal
/// prominente, con la Papelera discreta a su lado. La selección es un `NavTarget?`
/// que dirige la columna central.
struct SidebarView: View {
    @Binding var selection: NavTarget?
    @Environment(\.modelContext) private var context
    @Environment(\.themePalette) private var palette
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(LibraryActions.self) private var actions

    /// Petición de confirmación para «Abrir todos» cuando son muchos enlaces.
    @State private var openAllRequest: OpenAllRequest?

    /// Todos los enlaces activos (no en papelera). Sirve para todos los contadores
    /// de los accesos de sistema sin lanzar varias consultas distintas.
    @Query(filter: #Predicate<Bookmark> { $0.deletedAt == nil })
    private var activeLinks: [Bookmark]
    /// SOLO para el contador de «Resaltados»: un conteo sobre la tabla `Highlight`, en vez de
    /// faultar la relación `.highlights` de cada enlace (eso era un acceso a la BD por enlace →
    /// inviable con decenas de miles). Se borran en cascada con su enlace, así que el total
    /// equivale a los resaltados de enlaces vivos.
    @Query private var allHighlights: [Highlight]

    /// Colecciones raíz (las que no tienen padre); sus hijos se recorren por relación.
    @Query(filter: #Predicate<BookmarkCategory> { $0.deletedAt == nil },
           sort: \BookmarkCategory.order)
    private var categories: [BookmarkCategory]

    /// Etiquetas activas (planas; la jerarquía se muestra indentada).
    @Query(filter: #Predicate<Tag> { $0.deletedAt == nil }, sort: \Tag.order)
    private var tags: [Tag]

    /// Proyectos activos: se listan en el sidebar como destinos de arrastre (soltar un
    /// enlace lo añade al proyecto) y acceso directo a su espacio de trabajo.
    @Query(filter: #Predicate<Project> { $0.deletedAt == nil }, sort: \Project.order)
    private var projects: [Project]
    /// Pertenencia enlace↔proyecto (compartida con [[ProjectWorkspaceStore]]).
    @AppStorage(ProjectWorkspaceStore.storageKey) private var projectsWorkspaceJSON = ""

    @State private var categoryEditor: CategoryEditorView.Mode?
    /// Editor de proyecto (crear/editar) desde la cabecera/menú del sidebar.
    @State private var projectEditor: ProjectEditorView.Mode?
    /// Editor de etiqueta (renombrar/color/anidar) invocado desde el menú contextual.
    @State private var tagEditor: TagEditorView.Mode?
    /// Etiqueta pendiente de confirmar borrado (se desvincula de todos sus enlaces).
    @State private var pendingTagDelete: Tag?
    /// Colección pendiente de confirmar borrado. Su contenido directo se conserva en
    /// «Sin clasificar» y sus hijas se reubican en el nivel superior.
    @State private var pendingCategoryDelete: BookmarkCategory?
    /// Proyecto pendiente de confirmar borrado. El workspace lateral se conserva.
    @State private var pendingProjectDelete: Project?
    /// Presenta el índice buscable completo sin llenar la sidebar con decenas de filas.
    @State private var showAllCollections = false
    /// Presenta la hoja con TODAS las etiquetas (buscable) cuando hay más del límite.
    @State private var showAllTags = false
    /// Renombrado inline (doble clic) de una colección o etiqueta: id de la fila en
    /// edición + texto del campo. El UUID desambigua entre tipos (son únicos). Confirma
    /// con Enter o al perder el foco; Esc cancela. Complementa —no sustituye— al editor
    /// completo (color/anidado) del menú contextual: es solo el camino rápido del nombre.
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @FocusState private var renameFieldFocused: Bool
    /// Orden de las etiquetas: por frecuencia (defecto) o alfabético. Compartido con la
    /// hoja «Ver todas» vía `@AppStorage`. Con muchas etiquetas, la sidebar solo muestra
    /// las más usadas (las demás, en la hoja) para NO crecer sin control (supera a Raindrop).
    @AppStorage("stacklume.sidebar.tagsByFrequency") private var tagsByFrequency = true
    /// Orden MANUAL de etiquetas (por `Tag.order`): lo activa arrastrar una etiqueta sobre
    /// otra. Tiene prioridad sobre frecuencia/nombre. Así el arrastre se ve reflejado.
    @AppStorage("stacklume.sidebar.tagsManualOrder") private var tagsManualOrder = false

    // MARK: - Estado del enriquecido IA por colección

    /// Lanzador de IA: observamos `isReady` para habilitar/deshabilitar el menú.
    @State private var aiRunner = LocalAIRunner.shared
    /// Toggle global «Enriquecido automático con IA» (respetamos la preferencia del usuario).
    @AppStorage("stacklume.aiAutoEnrich") private var aiAutoEnrich = true
    /// Idioma elegido en Ajustes (para el enriquecido con IA).
    @Query private var settingsList: [AppSettings]
    /// ¿Pedir confirmación antes de borrar? (mismo ajuste que respeta el resto de la app).
    private var confirmBeforeDelete: Bool { settingsList.first?.confirmBeforeDelete ?? true }
    /// Progreso del enriquecido por colección en curso: (done, total).
    @State private var collectionEnrichProgress: (done: Int, total: Int)?
    /// Nombre de la colección que se está enriqueciendo (para el HUD).
    @State private var collectionEnrichName: String = ""
    /// Tarea del enriquecido por colección (permite cancelarla).
    @State private var collectionEnrichTask: Task<Void, Never>?

    // MARK: - Estado de drag & drop de colecciones

    /// ID de la colección que está siendo arrastrada actualmente.
    @State private var draggedCategoryID: UUID?

    // MARK: - Estado de indicadores de inserción

    /// ID de la colección cuya zona «insertar antes» está activa (hover).
    @State private var insertBeforeTargetID: UUID?
    /// ID de la colección cuya zona «insertar después» está activa (hover).
    @State private var insertAfterTargetID: UUID?

    // MARK: - Estado de expansión de los grupos secundarios (persistente)

    /// Los grupos secundarios arrancan COLAPSADOS para reducir el ruido visual;
    /// el usuario debe ver de un vistazo lo importante (sistema + colecciones).
    /// El estado se recuerda entre sesiones con `@AppStorage`.
    @AppStorage("stacklume.sidebar.tagsExpanded") private var tagsExpanded = false
    @AppStorage("stacklume.sidebar.filtersExpanded") private var filtersExpanded = false
    @AppStorage("stacklume.sidebar.toolsExpanded") private var toolsExpanded = false
    @AppStorage("stacklume.sidebar.savedExpanded") private var savedExpanded = true
    /// Colecciones: COLAPSABLE (chevron en la cabecera, expandido por defecto porque es el
    /// corazón de la navegación) y con criterio de ORDEN propio (manual/alfabético/por nº de
    /// enlaces), igual de capaz que el grupo de Etiquetas. Lo pidió el usuario.
    @AppStorage("stacklume.sidebar.collectionsExpanded") private var collectionsExpanded = true
    @AppStorage("stacklume.sidebar.collectionsSort") private var collectionsSortMode = "manual"
    /// Búsquedas guardadas (Smart Folders) — mismo almacén que la biblioteca.
    @AppStorage("stacklume.savedSearches") private var savedSearchesJSON = ""
    private var savedSearches: [SavedSearch] { SavedSearchStore.decode(savedSearchesJSON) }

    /// Elimina una búsqueda guardada desde el lateral (su menú contextual).
    private func deleteSavedSearch(_ search: SavedSearch) {
        if selection == .savedSearch(search.id) { selection = .all }
        savedSearchesJSON = SavedSearchStore.encode(savedSearches.filter { $0.id != search.id })
    }

    // MARK: - Contadores de accesos de sistema

    /// Revisión monotónica del modelo; solo cambia tras un guardado correcto. El sidebar
    /// puede repintarse por selección, hover o animaciones sin volver a recorrer la biblioteca.
    @State private var libraryRevision: UInt = 0
    @State private var nativeHeaderHeight: CGFloat = 0
    @State private var nativeFooterHeight: CGFloat = 0

    private struct SidebarMetrics {
        var all = 0
        var inbox = 0
        var unsorted = 0
        var favorites = 0
        var queue = 0
        var categoryTotal = 0
        var tagTotal = 0
        var categoryCounts: [UUID: Int] = [:]
        var tagCounts: [UUID: Int] = [:]
        var bookmarks: [UUID: SidebarBookmarkValue] = [:]
    }

    /// Instantánea única de todos los recuentos. Antes sistema, colecciones y etiquetas
    /// hacían pasadas independientes y el orden por frecuencia volvía a consultar SwiftData
    /// dentro de cada comparación del `sort` (cuello de botella confirmado por `sample`).
    private final class SidebarMetricsCache {
        var key = "\u{0}"
        var value = SidebarMetrics()
    }
    @State private var metricsCache = SidebarMetricsCache()

    private func refreshSidebarMetrics() -> SidebarMetrics {
        // La revisión es la única clave necesaria: todo guardado de la app pasa por
        // `saveLogging`. No leer los tres `@Query.count` en un hit evita materializar sus
        // snapshots observados durante cada frame/recomposición de SwiftUI.
        let key = "\(libraryRevision)"
        if metricsCache.key == key { return metricsCache.value }

        var metrics = SidebarMetrics()
        metrics.categoryTotal = categories.count
        metrics.tagTotal = tags.count
        for link in activeLinks {
            guard link.modelContext != nil, !link.isDeleted, link.deletedAt == nil else { continue }
            metrics.bookmarks[link.id] = SidebarBookmarkValue(
                category: link.category.flatMap { $0.modelContext != nil && !$0.isDeleted ? $0.id : nil },
                tags: Set(link.tags.filter { $0.modelContext != nil && !$0.isDeleted }.map(\.id)),
                favorite: link.isFavorite, inbox: link.readingStatus == .inbox, done: link.readingStatus == .done)

            // La categoría puede estar invalidada por una fusión del mismo ciclo de render.
            if let category = link.category,
               category.modelContext != nil,
               !category.isDeleted {
                metrics.categoryCounts[category.id, default: 0] += 1
            }
            for tag in link.tags where tag.modelContext != nil && !tag.isDeleted {
                metrics.tagCounts[tag.id, default: 0] += 1
            }
            guard !link.isArchived else { continue }
            metrics.all += 1
            if link.readingStatus == .inbox { metrics.inbox += 1 }
            if link.category == nil { metrics.unsorted += 1 }
            if link.isFavorite { metrics.favorites += 1 }
            if link.readingStatus != .done { metrics.queue += 1 }
        }
        metricsCache.key = key
        metricsCache.value = metrics
        return metrics
    }

    private func linkCount(for category: BookmarkCategory) -> Int {
        metricsCache.value.categoryCounts[category.id] ?? 0
    }
    /// «Resaltados»: total vía la consulta `allHighlights` (conteo en la BD), sin faultar la
    /// relación `.highlights` de cada enlace.
    private var highlightsCount: Int { allHighlights.count }

    private func linkCount(_ tag: Tag) -> Int { metricsCache.value.tagCounts[tag.id] ?? 0 }

    /// Caché bajo demanda de filtros inteligentes. El grupo está colapsado por defecto; al
    /// abrirlo cada faceta se calcula una vez por transacción y se reutiliza en hover, scroll,
    /// selección y animaciones. Conserva la lógica compartida sin duplicar sus predicados.
    private final class SmartCountCache {
        var key = "\u{0}"
        var counts: [SmartFilter: Int] = [:]
    }
    @State private var smartCountCache = SmartCountCache()

    /// Recuento de un filtro inteligente para su faceta en el sidebar. REUTILIZA el mismo
    /// `filteredLinks` que la lista, así el número coincide EXACTAMENTE con lo que verá el
    /// usuario al pulsarlo (sin reimplementar la lógica de cada bandera, que vive en el paquete).
    private func smartCount(_ filter: SmartFilter) -> Int {
        let key = "\(libraryRevision)"
        if smartCountCache.key != key {
            smartCountCache.key = key
            smartCountCache.counts.removeAll(keepingCapacity: true)
        }
        if let cached = smartCountCache.counts[filter] { return cached }
        var f = LinkFilter()
        filter.apply(to: &f)
        let count = filteredLinks(activeLinks, using: f, sort: .recent).count
        smartCountCache.counts[filter] = count
        return count
    }

    /// Máximo de etiquetas mostradas directamente en la sidebar; el resto se pliega en
    /// «Ver todas» (hoja buscable), para que la sección no crezca sin control. Se muestran
    /// las MÁS USADAS (orden por frecuencia), que son las más relevantes a mano.
    private static let sidebarTagLimit = 6
    /// Máximo de colecciones raíz visibles a la vez. La selección actual siempre se
    /// mantiene a la vista aunque quede fuera del primer grupo.
    private static let sidebarCollectionLimit = 8

    /// Comparador reutilizable para subetiquetas y reordenado. Lee la instantánea ya
    /// calculada; nunca vuelve a consultar `activeLinks` ni las relaciones de SwiftData.
    private func tagOrder(_ a: Tag, _ b: Tag) -> Bool {
        if tagsManualOrder { return a.order < b.order }
        if tagsByFrequency {
            let left = metricsCache.value.tagCounts[a.id] ?? 0
            let right = metricsCache.value.tagCounts[b.id] ?? 0
            if left != right { return left > right }
        }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    /// Caché del árbol de etiquetas (lista ordenada + raíces): re-ordenar y re-filtrar por
    /// `.parent == nil` —que faulta `.parent` de CADA etiqueta— en cada render del sidebar, y el
    /// sidebar se re-renderiza al NAVEGAR entre secciones (cambia `selection`), era un coste
    /// medido (`sample`: tagOrder/sortedTags/Tag.parent al moverse entre colecciones). Se
    /// reconstruye solo cuando cambian las etiquetas, los enlaces (recuentos) o el criterio.
    private final class TagTreeCache { var key = "\u{0}"; var sorted: [Tag] = []; var roots: [Tag] = [] }
    @State private var tagTreeCache = TagTreeCache()
    private var tagTreeKey: String {
        "\(libraryRevision)|\(tagsByFrequency ? 1 : 0)|\(tagsManualOrder ? 1 : 0)"
    }
    private func ensureTagTree() {
        let key = tagTreeKey
        guard tagTreeCache.key != key else { return }
        let counts = metricsCache.value.tagCounts
        let manual = tagsManualOrder
        let byFrequency = tagsByFrequency
        let sorted = tags.sorted { a, b in
            if manual { return a.order < b.order }
            if byFrequency {
                let left = counts[a.id] ?? 0
                let right = counts[b.id] ?? 0
                if left != right { return left > right }
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        tagTreeCache.sorted = sorted
        tagTreeCache.roots = sorted.filter { $0.parent == nil }
        tagTreeCache.key = key
    }
    /// TODAS las etiquetas ordenadas (para la hoja «Ver todas», que es plana y buscable). Cacheado.
    private var sortedTags: [Tag] { ensureTagTree(); return tagTreeCache.sorted }
    /// Etiquetas RAÍZ (sin padre), ordenadas. Cacheado (no faulta `.parent` por render).
    private var rootTags: [Tag] { ensureTagTree(); return tagTreeCache.roots }
    /// Raíces mostradas directamente en el sidebar (top-N); el resto, en «Ver todas».
    private var sidebarRootTags: [Tag] { Array(rootTags.prefix(Self.sidebarTagLimit)) }

    /// Formatea un contador de forma compacta (1234 → «1,2k»), como Raindrop, para que
    /// los números grandes no ensanchen ni saturen la fila.
    private func compactCount(_ n: Int) -> String {
        guard n >= 1000 else { return "\(n)" }
        let k = Double(n) / 1000
        return String(format: k < 10 ? "%.1fk" : "%.0fk", k)
    }

    /// Orden de colecciones según el criterio elegido (`collectionsSortMode`): manual (arrastre,
    /// por `order`), alfabético, o por nº de enlaces (recuento ya cacheado en `metricsCache`,
    /// así que ordenar por recuento no recorre la biblioteca). Empate → alfabético.
    private func collectionOrder(_ a: BookmarkCategory, _ b: BookmarkCategory) -> Bool {
        switch collectionsSortMode {
        case "alpha":
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        case "count":
            let ca = metricsCache.value.categoryCounts[a.id] ?? 0
            let cb = metricsCache.value.categoryCounts[b.id] ?? 0
            if ca != cb { return ca > cb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        default:   // "manual"
            return a.order < b.order
        }
    }

    /// Caché de raíces: navegar, hacer hover o animar una fila recompone el sidebar, pero no
    /// debería volver a faultar `.parent` de todas las colecciones ni reordenarlas. Se invalida
    /// con la misma revisión transaccional que los contadores y con el criterio visible.
    private final class CategoryRootCache {
        var key = "\u{0}"
        var roots: [BookmarkCategory] = []
    }
    @State private var categoryRootCache = CategoryRootCache()

    /// Colecciones raíz, ordenadas según el criterio (las subcolecciones cuelgan por `DisclosureGroup`).
    private var rootCategories: [BookmarkCategory] {
        let key = "\(libraryRevision)|\(collectionsSortMode)"
        if categoryRootCache.key == key { return categoryRootCache.roots }

        // `modelContext != nil`: excluye categorías INVALIDADAS (recién borradas por la auto-fusión
        // del arranque) que el @Query aún no ha soltado, para no leer sus propiedades y crashear.
        let roots = categories
            .filter { $0.modelContext != nil && $0.parent == nil }
            .sorted(by: collectionOrder)
        categoryRootCache.roots = roots
        categoryRootCache.key = key
        return roots
    }

    /// Raíz de la colección seleccionada. Se usa para que navegar desde «Ver todas» no
    /// haga desaparecer inmediatamente el destino elegido de la barra lateral.
    private var selectedCollectionRootID: UUID? {
        guard let selection,
              case let .collection(selectedID) = selection,
              var current = categories.first(where: { $0.id == selectedID && $0.modelContext != nil })
        else { return nil }
        var visited: Set<UUID> = [current.id]
        while let parent = current.parent,
              parent.modelContext != nil,
              visited.insert(parent.id).inserted {
            current = parent
        }
        return current.id
    }

    /// Colecciones raíz visibles por divulgación progresiva. Mantiene ocho filas como
    /// máximo y sustituye la última por la raíz seleccionada cuando sea necesario.
    private var sidebarRootCategories: [BookmarkCategory] {
        let roots = rootCategories
        guard roots.count > Self.sidebarCollectionLimit else { return roots }
        var visible = Array(roots.prefix(Self.sidebarCollectionLimit))
        guard let selectedCollectionRootID,
              !visible.contains(where: { $0.id == selectedCollectionRootID }),
              let selectedRoot = roots.first(where: { $0.id == selectedCollectionRootID })
        else { return visible }
        visible[visible.count - 1] = selectedRoot
        return visible
    }

    /// Estado breve del asistente que cabe en una sola línea y evita que el usuario
    /// tenga que abrirlo para descubrir si está disponible en este Mac.
    private var assistantStatus: String {
        if aiRunner.isReady { return "Listo en este Mac" }
        if aiRunner.isBusy { return "Preparando el modelo local…" }
        if aiRunner.isDeactivated { return "Desactivado en Ajustes" }
        if aiRunner.isAvailable { return "Disponible en este Mac" }
        return "Pregunta y organiza tu biblioteca"
    }

    var body: some View {
        // Una sola instantánea para sistema, colecciones y etiquetas. Se reutiliza hasta
        // el siguiente guardado real, aunque el sidebar se repinte por navegación.
        let metrics = refreshSidebarMetrics()
        SidebarNativeOutline(
            snapshot: nativeSnapshot(metrics),
            selection: $selection,
            topInset: nativeHeaderHeight, bottomInset: nativeFooterHeight,
            perform: nativePerform,
            acceptDrop: nativeAcceptDrop,
            setGroupExpanded: nativeSetExpanded
        )
        // Rail funcional único. Marca, árbol y footer comparten una sola lente exterior;
        // las filas siguen siendo contenido plano y se desplazan bajo sus zonas fijas.
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .overlay(alignment: .top) {
            BrandMark()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { nativeHeaderHeight = $0 }
        }
        .overlay(alignment: .bottom) {
            // Acción primaria fija abajo + Papelera discreta a su lado.
            HStack(spacing: DesignSystem.Spacing.xs) {
                Button {
                    actions.newLink()
                } label: {
                    Label("Nuevo enlace", systemImage: "plus")
                        .stacklumeFont(.callout.weight(.semibold))
                        .foregroundStyle(palette.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .stacklumeButton()

                Button {
                    selection = .trash
                } label: {
                    Image(systemName: "trash")
                        .stacklumeFont(.callout)
                        .foregroundStyle(palette.textPrimary)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 2)
                }
                .stacklumeButton(prominent: false, compact: true)
                .themedHelp("Papelera")
                .accessibilityLabel("Papelera")
            }
            .padding(DesignSystem.Spacing.xs)
            .background {
                StacklumeGlassBackdrop(
                    shape: RoundedRectangle(cornerRadius: 18, style: .continuous),
                    tint: palette.accent,
                    tintOpacity: 0.022,
                    surfaceOpacity: 0.20,
                    borderOpacity: 0.11
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 11, y: 5)
            // Igual que arriba: conserva la diferenciación, con solo una junta mínima.
            .padding(.horizontal, 5)
            .padding(.top, 1)
            .padding(.bottom, 5)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { nativeFooterHeight = $0 }
        }
        .background {
            StacklumeGlassBackdrop(
                shape: RoundedRectangle(cornerRadius: 24, style: .continuous),
                tint: palette.accent,
                tintOpacity: 0.018,
                surfaceOpacity: 0.14,
                borderOpacity: 0.14
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .padding(.horizontal, 6)
        .padding(.top, 5)
        .padding(.bottom, 7)
        .sheet(item: $categoryEditor) { CategoryEditorView(mode: $0).themedSheet(palette) }
        .sheet(item: $projectEditor) { ProjectEditorView(mode: $0).themedSheet(palette) }
        .sheet(item: $tagEditor) { TagEditorView(mode: $0).themedSheet(palette) }
        .sheet(isPresented: $showAllCollections) {
            AllCollectionsSheet(
                collections: categories,
                counts: metrics.categoryCounts,
                selection: $selection
            )
            .themedSheet(palette)
        }
        .sheet(isPresented: $showAllTags) {
            AllTagsSheet(tags: sortedTags, counts: metrics.tagCounts, selection: $selection)
                .themedSheet(palette)
        }
        .onReceive(NotificationCenter.default.publisher(for: .stacklumeModelDidSave)) { _ in
            libraryRevision &+= 1
        }
        .confirmationDialog(
            "¿Eliminar la colección?",
            isPresented: Binding(get: { pendingCategoryDelete != nil },
                                 set: { if !$0 { pendingCategoryDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingCategoryDelete
        ) { category in
            Button("Eliminar «\(category.name)»", role: .destructive) {
                deleteCategory(category)
                pendingCategoryDelete = nil
            }
            Button("Cancelar", role: .cancel) { pendingCategoryDelete = nil }
        } message: { category in
            let links = linkCount(for: category)
            let children = category.children.filter { $0.deletedAt == nil }.count
            if children > 0 {
                Text("Sus \(children) \(children == 1 ? "subcolección se conservará" : "subcolecciones se conservarán") en el nivel superior. \(links) \(links == 1 ? "enlace pasará" : "enlaces pasarán") a «Sin clasificar».")
            } else {
                Text(links == 0
                     ? "La colección está vacía. Los demás enlaces no se modificarán."
                     : "\(links) \(links == 1 ? "enlace pasará" : "enlaces pasarán") a «Sin clasificar». No se borrará ningún enlace.")
            }
        }
        .confirmationDialog(
            "¿Eliminar el proyecto?",
            isPresented: Binding(get: { pendingProjectDelete != nil },
                                 set: { if !$0 { pendingProjectDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingProjectDelete
        ) { project in
            Button("Eliminar «\(project.name)»", role: .destructive) {
                deleteProject(project)
                pendingProjectDelete = nil
            }
            Button("Cancelar", role: .cancel) { pendingProjectDelete = nil }
        } message: { _ in
            Text("El proyecto se ocultará, pero sus enlaces, nota, tareas y comandos se conservarán. No se borrará ningún enlace de la biblioteca.")
        }
        .confirmationDialog(
            "¿Eliminar la etiqueta?",
            isPresented: Binding(get: { pendingTagDelete != nil },
                                 set: { if !$0 { pendingTagDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingTagDelete
        ) { tag in
            Button("Eliminar «\(tag.name)»", role: .destructive) {
                deleteTag(tag)
                pendingTagDelete = nil
            }
            Button("Cancelar", role: .cancel) { pendingTagDelete = nil }
        } message: { tag in
            let n = tag.activeLinkCount
            Text(n == 0
                 ? "La etiqueta no está en ningún enlace. Se eliminará del sidebar."
                 : "Se quitará de \(n) \(n == 1 ? "enlace" : "enlaces"). Los enlaces NO se borran.")
        }
        .confirmationDialog(
            "¿Abrir todos los enlaces?",
            isPresented: Binding(get: { openAllRequest != nil },
                                 set: { if !$0 { openAllRequest = nil } }),
            titleVisibility: .visible,
            presenting: openAllRequest
        ) { request in
            Button("Abrir \(request.urls.count) en el navegador") {
                request.urls.forEach { openURL($0) }
                openAllRequest = nil
            }
            Button("Cancelar", role: .cancel) { openAllRequest = nil }
        } message: { request in
            Text("Se abrirán \(request.urls.count) pestañas de «\(request.name)».")
        }
        // HUD de progreso del enriquecido por colección: ligero, no intrusivo.
        // Aparece superpuesto al sidebar mientras la tarea está activa.
        .overlay(alignment: .bottom) {
            if let prog = collectionEnrichProgress {
                CollectionEnrichHUD(
                    collectionName: collectionEnrichName,
                    done: prog.done,
                    total: prog.total,
                    palette: palette
                ) {
                    collectionEnrichTask?.cancel()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8),
                           value: collectionEnrichProgress != nil)
                .padding(DesignSystem.Spacing.sm)
            }
        }
    }

    /// Filtros inteligentes que se muestran como accesos rápidos en el sidebar
    /// (los principales según DESIGN.md: artículos/vídeos/imágenes según el enum
    /// disponible, más «rotos»). El enum no distingue artículos/vídeos como tales,
    /// así que se ofrecen los filtros equivalentes más útiles.
    static let sidebarSmartFilters: [SmartFilter] = [.unread, .untagged, .uncategorized, .reminders, .broken, .archived]

    // MARK: - Cabecera de grupo y etiqueta de disclosure

    /// Cabecera de sección con el estilo premium de DESIGN.md (caption semibold,
    /// `textSecondary`) y, opcionalmente, un control accesorio a la derecha (p.ej. «+»).
    @ViewBuilder
    private func sectionHeader<Accessory: View>(_ title: LocalizedStringKey,
                                                @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack {
            Text(title)
                .stacklumeFont(.caption.weight(.semibold))
                .foregroundStyle(palette.textSecondary)
            Spacer()
            accessory()
                .foregroundStyle(palette.textSecondary)
        }
        // Aire a la derecha: el accesorio («+») no debe quedar pegado al borde del sidebar.
        .padding(.trailing, 6)
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        sectionHeader(title) { EmptyView() }
    }

    /// Etiqueta de un `DisclosureGroup` secundario: mismo lenguaje visual sutil que
    /// las cabeceras de sección (caption semibold, `textSecondary`), de modo que el
    /// grupo colapsado no «grita» y se integra con el resto del sidebar.
    private func groupLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .stacklumeFont(.caption.weight(.semibold))
            .foregroundStyle(palette.textSecondary)
    }

    /// Rótulo del grupo «Etiquetas»: nombre + contador total entre paréntesis (como
    /// «Tags (N)» de Raindrop). Menú contextual para ordenar por frecuencia o nombre y
    /// abrir la hoja con todas.
    private func tagsGroupLabel(total: Int) -> some View {
        HStack(spacing: 6) {
            groupLabel("Etiquetas")
            Text("\(total)")
                .stacklumeFont(.caption2.monospacedDigit())
                .foregroundStyle(palette.textSecondary.opacity(0.7))
            Spacer()
        }
        .contextMenu {
            Button { tagsByFrequency = true; tagsManualOrder = false } label: {
                Label("Ordenar por frecuencia",
                      systemImage: (!tagsManualOrder && tagsByFrequency) ? "checkmark" : "arrow.down.circle")
            }
            Button { tagsByFrequency = false; tagsManualOrder = false } label: {
                Label("Ordenar por nombre",
                      systemImage: (!tagsManualOrder && !tagsByFrequency) ? "checkmark" : "textformat")
            }
            Button { tagsManualOrder = true } label: {
                Label("Orden manual (arrastra)", systemImage: tagsManualOrder ? "checkmark" : "hand.draw")
            }
            if total > Self.sidebarTagLimit {
                Divider()
                Button("Ver todas (\(total))", systemImage: "ellipsis.circle") { showAllTags = true }
            }
        }
    }

    /// Etiqueta del `DisclosureGroup` «Colecciones»: rótulo + contador, menú de ORDEN
    /// (manual/alfabético/por nº de enlaces) y botón «+». El chevron y la animación los aporta el
    /// `DisclosureGroup` (igual que Etiquetas). Los dos controles de la derecha comparten EXACTO
    /// el mismo tratamiento (mismo `iconControlFont`), así el «↕» no se ve más grande que el «+».
    private func collectionsGroupLabel(total: Int) -> some View {
        HStack(spacing: 6) {
            groupLabel("Colecciones")
            Text("\(total)")
                .stacklumeFont(.caption2.monospacedDigit())
                .foregroundStyle(palette.textSecondary.opacity(0.7))
            Spacer()
            collectionSortMenu
            Button {
                categoryEditor = .create
            } label: {
                Image(systemName: "plus")
                    .stacklumeFont(Self.iconControlFont)
                    .foregroundStyle(palette.textSecondary)
            }
            .buttonStyle(.plain)
            .themedHelp("Nueva colección")
            .accessibilityLabel("Nueva colección")
        }
    }

    /// Fuente COMÚN de los iconos de control de la cabecera, para que «↕» (ordenar) y «+» (añadir)
    /// se vean exactamente del mismo tamaño y peso.
    private static let iconControlFont: Font = .system(size: 12, weight: .semibold)

    /// Menú de ORDEN de las colecciones (criterio recordado en `@AppStorage`). El check marca el
    /// criterio activo, igual que el menú contextual de Etiquetas. `controlSize(.small)` + el
    /// mismo `iconControlFont` que el «+» para que no quede más grande.
    private var collectionSortMenu: some View {
        Menu {
            Button { collectionsSortMode = "manual" } label: {
                Label("Orden manual (arrastra)",
                      systemImage: collectionsSortMode == "manual" ? "checkmark" : "hand.draw")
            }
            Button { collectionsSortMode = "alpha" } label: {
                Label("Ordenar por nombre",
                      systemImage: collectionsSortMode == "alpha" ? "checkmark" : "textformat")
            }
            Button { collectionsSortMode = "count" } label: {
                Label("Ordenar por nº de enlaces",
                      systemImage: collectionsSortMode == "count" ? "checkmark" : "number")
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .stacklumeFont(Self.iconControlFont)
                .foregroundStyle(palette.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .fixedSize()
        .themedHelp("Ordenar colecciones")
    }

    // MARK: - Filas de accesos de sistema (con contador)

    private func systemRow(_ target: NavTarget, title: String, icon: String, count: Int) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text(compactCount(count))
                    .monospacedDigit()
                    .foregroundStyle(palette.textSecondary)
                    // El contador anima el cambio de cifra (premium) al guardar/quitar enlaces.
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: count)
            }
        } icon: {
            Image(systemName: icon)
        }
        .tag(target)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(count) \(count == 1 ? "enlace" : "enlaces")")
        // Soltar un enlace sobre un acceso de sistema: Favoritos → favorito; Sin
        // clasificar → quitar de su colección; Bandeja/Cola de lectura → marcar como pendiente.
        .dropDestination(for: String.self) { items, _ in
            guard let payload = items.first,
                  let bookmarkID = BookmarkTransfer.bookmarkID(from: payload) else { return false }
            return applySystemDrop(target, bookmarkID: bookmarkID)
        }
    }

    /// Aplica el efecto de soltar un enlace sobre un acceso de sistema del sidebar.
    private func applySystemDrop(_ target: NavTarget, bookmarkID id: UUID) -> Bool {
        guard let link = fetchActiveLink(id) else { return false }
        switch target {
        case .favorites:
            guard !link.isFavorite else { return false }
            link.isFavorite = true
        case .unsorted:
            guard link.category != nil else { return false }
            link.category = nil
            LinkIngest.userChangedOrganization(link.id)
        case .inbox:
            guard link.readingStatus != .inbox else { return false }
            link.readingStatus = .inbox
        case .readingQueue:
            guard link.readingStatus == .done else { return false }
            link.readingStatus = .inbox   // sacarlo de «leído» → vuelve a la cola
        default:
            return false                   // «Todos»/«Descubrir» no aceptan soltar
        }
        link.updatedAt = Date()
        context.saveLogging()
        SpotlightIndexer.index(link)
        return true
    }

    /// Busca un enlace ACTIVO por id (helper compartido por los drops de la sidebar).
    private func fetchActiveLink(_ id: UUID) -> Bookmark? {
        var descriptor = FetchDescriptor<Bookmark>(
            predicate: #Predicate { $0.id == id && $0.deletedAt == nil })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    // MARK: - Nodo de colección (árbol con disclosure)

    /// Fila de una colección con sus subcolecciones. Si tiene hijos activos, usa un
    /// `DisclosureGroup` para poder plegar/desplegar; si no, una fila simple.
    ///
    /// Devuelve `AnyView` para romper la recursión del tipo opaco: una función con
    /// `some View` que se llama a sí misma define el tipo opaco en términos de sí
    /// mismo y no compila. El borrado de tipo aquí es necesario y de coste mínimo.
    private func collectionNode(_ category: BookmarkCategory) -> AnyView {
        let children = category.children
            .filter { $0.deletedAt == nil }
            .sorted(by: collectionOrder)
        if children.isEmpty {
            return AnyView(
                collectionRow(category)
                    .listRowBackground(selectionPill(.collection(category.id)))
            )
        } else {
            return AnyView(
                DisclosureGroup {
                    ForEach(children) { child in
                        collectionNode(child)
                    }
                } label: {
                    collectionRow(category)
                }
                // El fondo de selección del label de la colección. Las subcolecciones
                // fijan el suyo propio (gana sobre este en sus filas).
                .listRowBackground(selectionPill(.collection(category.id)))
            )
        }
    }

    /// Fondo de selección teñido con el ACENTO DEL TEMA (sustituye al resaltado
    /// nativo de macOS, que ignora el tema). Delega en `ThemedSelectionBackground`.
    private func selectionPill(_ target: NavTarget) -> some View {
        ThemedSelectionBackground(isSelected: selection == target, accent: palette.accent)
    }

    /// Fila de colección: miniatura de portada 18×18 (si tiene `coverImageData`) o
    /// icono/punto en su `colorHex`, nombre y contador. Menú contextual con
    /// renombrar/editar, nueva subcolección y eliminar.
    ///
    /// Admite drag & drop en tres zonas:
    ///  - Borde superior (~8pt): «insertar antes» — coloca la arrastrada justo antes
    ///    de esta fila, dentro del mismo padre.
    ///  - Zona central: «anidar dentro» — la arrastrada pasa a ser hija de esta.
    ///  - Borde inferior (~8pt): «insertar después» — coloca la arrastrada justo
    ///    después de esta fila, dentro del mismo padre.
    private func collectionRow(_ category: BookmarkCategory) -> some View {
        let color = Color(hex: category.colorHex)
        return Label {
            HStack {
                editableName(id: category.id, name: category.name) { newName in
                    category.name = newName
                    context.saveLogging()
                    WidgetReloader.reload()
                }
                Spacer(minLength: 8)
                Text(compactCount(linkCount(for: category)))   // contador de la pasada única (no faulta `.links`)
                    .monospacedDigit()
                    .foregroundStyle(palette.textSecondary)
            }
        } icon: {
            collectionThumbnail(category, color: color)
        }
        .tag(NavTarget.collection(category.id))
        .contentShape(Rectangle())
        // Selección INMEDIATA en un clic limpio. Con `.draggable` en la fila, el clic de
        // selección nativo de la `List` se vuelve ambiguo (¿clic o inicio de arrastre?) y a veces
        // no registra a la primera → había que clicar varias veces. Este toque simultáneo fija la
        // selección al instante; el arrastre solo se activa al MOVER el ratón, así que conviven.
        .simultaneousGesture(TapGesture().onEnded { selection = .collection(category.id) })
        .contextMenu {
            Button("Renombrar / Editar", systemImage: "pencil") {
                categoryEditor = .edit(category)
            }
            Button("Nueva subcolección", systemImage: "folder.badge.plus") {
                createSubcollection(of: category)
            }
            Divider()
            Button("Abrir todos los enlaces", systemImage: "safari") {
                openAll(in: category)
            }
            Button("Copiar enlaces", systemImage: "doc.on.doc") {
                copyLinks(in: category)
            }
            Menu("Exportar", systemImage: "square.and.arrow.up") {
                Button("Como JSON…") { CollectionExporter.exportJSON(category, in: context) }
                Button("Como HTML (marcadores)…") { CollectionExporter.exportHTML(category) }
            }
            Divider()
            // «Mejorar con IA»: acción MANUAL explícita. Disponible si el modelo Liquid
            // está cargado y no hay otro enriquecido en curso. NO depende del toggle de
            // auto-IA (ese rige solo el enriquecido automático, no esta acción a demanda).
            if aiRunner.isReady {
                Button("Mejorar con IA", systemImage: "wand.and.stars") {
                    startCollectionEnrich(category)
                }
                .disabled(collectionEnrichTask != nil)
            }
            Divider()
            Button("Eliminar", systemImage: "trash", role: .destructive) {
                requestCategoryDelete(category)
            }
        }
        // Hacer la fila arrastrable: carga = UUID como String
        .draggable(category.id.uuidString) {
            // Vista fantasma durante el arrastre
            Label(category.name, systemImage: category.icon)
                .padding(6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        // Destino zona central: soltar un ENLACE → moverlo a esta colección; soltar otra
        // COLECCIÓN → la arrastrada pasa a ser hija de esta.
        .dropDestination(for: String.self) { items, _ in
            guard let payload = items.first else { return false }
            // ¿Es un enlace (prefijo «bm:»)? → moverlo a esta colección.
            if let bookmarkID = BookmarkTransfer.bookmarkID(from: payload) {
                return moveLink(bookmarkID, toCategory: category)
            }
            guard let draggedID = UUID(uuidString: payload),
                  draggedID != category.id,
                  let dragged = categories.first(where: { $0.id == draggedID })
            else { return false }

            // Prevención de ciclos
            guard !esDescendiente(de: dragged, elDestino: category) else { return false }

            let hermanos = category.children
                .filter { $0.deletedAt == nil && $0.id != draggedID }
                .sorted { $0.order < $1.order }
            recalcularOrden(hermanos: hermanos)
            dragged.order = hermanos.count
            dragged.parent = category
            context.saveLogging()
            return true
        }
        // Superponer zonas de inserción ANTES y DESPUÉS (bordes superior e inferior)
        .overlay(alignment: .top) {
            insertionZone(
                category: category,
                position: .before,
                isActive: insertBeforeTargetID == category.id
            )
        }
        .overlay(alignment: .bottom) {
            insertionZone(
                category: category,
                position: .after,
                isActive: insertAfterTargetID == category.id
            )
        }
    }

    /// Zona de inserción posicional (borde superior o inferior de una fila).
    /// Altura fija de 8pt — solo recibe el gesto de soltar en su borde.
    /// Cuando está activa (`isActive == true`) muestra la línea de acento.
    @ViewBuilder
    private func insertionZone(
        category: BookmarkCategory,
        position: InsertPosition,
        isActive: Bool
    ) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 8)
            // Indicador visual: línea de 2pt de color acento
            .overlay(alignment: position == .before ? .top : .bottom) {
                if isActive {
                    Rectangle()
                        .fill(palette.accent)
                        .frame(height: 2)
                        .padding(.horizontal, 4)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isActive)
                }
            }
            .dropDestination(for: String.self) { items, _ in
                guard let uuidString = items.first,
                      let draggedID = UUID(uuidString: uuidString),
                      draggedID != category.id,
                      let dragged = categories.first(where: { $0.id == draggedID })
                else { return false }

                // Prevención de ciclos: la zona de inserción tampoco puede crear ciclos
                // (solo relevante si category es descendiente de dragged)
                guard !esDescendiente(de: dragged, elDestino: category) else { return false }

                insertar(dragged: dragged, relativoA: category, posicion: position)
                return true
            } isTargeted: { targeted in
                if position == .before {
                    insertBeforeTargetID = targeted ? category.id : nil
                } else {
                    insertAfterTargetID = targeted ? category.id : nil
                }
            }
    }

    /// Posición de inserción respecto a una fila de referencia.
    private enum InsertPosition { case before, after }

    /// Mueve `dragged` para que quede inmediatamente antes o después de `referencia`,
    /// dentro del mismo padre que `referencia`. Reasigna el padre si es necesario y
    /// recalcula los `order` de todos los hermanos resultantes.
    private func insertar(
        dragged: BookmarkCategory,
        relativoA referencia: BookmarkCategory,
        posicion: InsertPosition
    ) {
        // El nuevo padre de la arrastrada es el padre de la referencia (o nil si raíz)
        let nuevoPadre = referencia.parent

        // Obtener todos los hermanos del nuevo destino (excluyendo la arrastrada)
        let hermanosDestino: [BookmarkCategory]
        if let padre = nuevoPadre {
            hermanosDestino = padre.children
                .filter { $0.deletedAt == nil && $0.id != dragged.id }
                .sorted { $0.order < $1.order }
        } else {
            // Destino = raíz
            hermanosDestino = categories
                .filter { $0.parent == nil && $0.deletedAt == nil && $0.id != dragged.id }
                .sorted { $0.order < $1.order }
        }

        // Encontrar la posición de la referencia en esa lista ordenada
        guard let idxReferencia = hermanosDestino.firstIndex(where: { $0.id == referencia.id })
        else { return }

        // Posición de inserción en la lista sin la arrastrada
        let idxInsercion = posicion == .before ? idxReferencia : idxReferencia + 1

        // Construir la lista final con la arrastrada en su nueva posición
        var listadoFinal = hermanosDestino
        listadoFinal.insert(dragged, at: idxInsercion)

        // Actualizar padre y recalcular order de toda la lista
        dragged.parent = nuevoPadre
        recalcularOrden(hermanos: listadoFinal)
        context.saveLogging()
    }

    /// Miniatura 18×18 de la colección: portada redondeada o punto/icono en su color.
    @ViewBuilder
    private func collectionThumbnail(_ category: BookmarkCategory, color: Color) -> some View {
        if let data = category.coverImageData, let image = PlatformImage(data: data) {
            Image(platformImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(systemName: category.icon)
                .foregroundStyle(color)
        }
    }

    /// Crea una subcolección directamente (sin abrir el editor) anidada en `parent`.
    private func createSubcollection(of parent: BookmarkCategory) {
        let used = Set(categories.map { CollectionMerger.canonical($0.name) })
        var suffix = 1
        var candidate = "Nueva subcolección"
        while used.contains(CollectionMerger.canonical(candidate)) {
            suffix += 1
            candidate = "Nueva subcolección \(suffix)"
        }
        guard let child = EntityResolver.category(
            candidate, in: context, colorHex: parent.colorHex, icon: parent.icon) else { return }
        child.order = parent.children.count
        child.parent = parent
        context.saveLogging()
        categoryEditor = .edit(child)
    }

    // MARK: - Enriquecido con IA por colección

    /// Reúne el id de la colección y los de todos sus descendientes activos.
    /// Misma lógica que `SectionContentView.descendantIDs(of:)`.
    private func descendantIDs(of category: BookmarkCategory) -> Set<UUID> {
        var ids: Set<UUID> = [category.id]
        var stack = category.children.filter { $0.deletedAt == nil }
        while let next = stack.popLast() {
            guard ids.insert(next.id).inserted else { continue }
            stack.append(contentsOf: next.children.filter { $0.deletedAt == nil })
        }
        return ids
    }

    // MARK: - Abrir / copiar todos los enlaces de una colección

    /// Enlaces ACTIVOS de una colección y sus descendientes (mismo alcance que su vista).
    private func linksInCollection(_ category: BookmarkCategory) -> [Bookmark] {
        let scope = descendantIDs(of: category)
        return activeLinks.filter { link in
            guard let catID = link.category?.id else { return false }
            return scope.contains(catID)
        }
    }

    /// Abre en el navegador todos los enlaces de una colección. Si son muchos (>10),
    /// pide confirmación antes (evita abrir decenas de pestañas por accidente).
    private func openAll(in category: BookmarkCategory) {
        let urls = linksInCollection(category).compactMap {
            StacklumeAutomationPolicy.openableStoredURL($0.url)
        }
        guard !urls.isEmpty else { return }
        if urls.count <= 10 {
            urls.forEach { openURL($0) }
        } else {
            openAllRequest = OpenAllRequest(name: category.name, urls: urls)
        }
    }

    /// Copia al portapapeles las URLs de la colección (una por línea).
    private func copyLinks(in category: BookmarkCategory) {
        let urls = linksInCollection(category).map(\.url)
        guard !urls.isEmpty else { return }
        NSPasteboard.copyString(urls.joined(separator: "\n"))
    }

    // MARK: - Borrado seguro de colecciones

    private func requestCategoryDelete(_ category: BookmarkCategory) {
        if confirmBeforeDelete { pendingCategoryDelete = category } else { deleteCategory(category) }
    }

    /// Borrado lógico sin pérdida de contenido: los enlaces directos pasan a «Sin
    /// clasificar» y las subcolecciones activas ocupan el lugar de su padre. De esta
    /// forma ninguna rama queda escondida detrás de una categoría borrada.
    private func deleteCategory(_ category: BookmarkCategory) {
        guard category.modelContext != nil, category.deletedAt == nil else { return }
        if selection == .collection(category.id) { selection = .all }

        let now = Date()
        let parent = category.parent
        let children = category.children
            .filter { $0.deletedAt == nil && $0.modelContext != nil }
            .sorted { $0.order < $1.order }
        let childIDs = Set(children.map(\.id))
        var siblings = categories
            .filter {
                $0.id != category.id
                    && !childIDs.contains($0.id)
                    && $0.deletedAt == nil
                    && $0.modelContext != nil
                    && $0.parent?.id == parent?.id
            }
            .sorted { $0.order < $1.order }
        let insertionIndex = min(max(category.order, 0), siblings.count)

        for child in children {
            child.parent = parent
            child.updatedAt = now
        }
        siblings.insert(contentsOf: children, at: insertionIndex)
        recalcularOrden(hermanos: siblings)

        for link in activeLinks where link.category?.id == category.id {
            link.category = nil
            LinkIngest.userChangedOrganization(link.id)
            link.updatedAt = now
            SpotlightIndexer.index(link)
        }
        category.deletedAt = now
        category.updatedAt = now
        context.saveLogging()
        WidgetReloader.reload()
    }

    /// Lanza el enriquecido IA acotado a `category` y sus descendientes.
    /// Muestra un HUD ligero en la parte inferior del sidebar con progreso y botón Detener.
    private func startCollectionEnrich(_ category: BookmarkCategory) {
        guard collectionEnrichTask == nil else { return }
        let scope = descendantIDs(of: category)
        let lang = (settingsList.first?.language ?? .es).rawValue
        collectionEnrichName = category.name
        collectionEnrichProgress = (0, 0)

        collectionEnrichTask = Task {
            await AIBatchEnricher.enrich(
                in: context,
                provider: "liquid",
                language: lang,
                limit: 200,
                collectionScope: scope,
                ignoreLedger: true
            ) { done, total in
                collectionEnrichProgress = (done, total)
            }
            // Tras el await el modelContext puede seguir vivo; guard no necesario aquí
            // porque solo actualizamos @State del View, no un @Model.
            SpotlightIndexer.reindexAll(in: context)
            WidgetReloader.reload()
            collectionEnrichTask = nil
            // Ocultar el HUD tras 1 segundo para que el usuario vea el resultado final.
            try? await Task.sleep(for: .seconds(1))
            collectionEnrichProgress = nil
        }
    }

    // MARK: - Utilidades de drag & drop

    /// Devuelve `true` si `candidato` es `raiz` o alguno de sus descendientes.
    /// Se usa para la prevención de ciclos: no se puede anidar una colección dentro
    /// de sí misma ni dentro de alguno de sus hijos/nietos (reutiliza el mismo recorrido
    /// de pila que `CategoryEditorView.parentOptions`).
    ///
    /// - Parameters:
    ///   - raiz: La colección arrastrada (la que se quiere mover).
    ///   - candidato: La colección destino (sobre la que se suelta).
    private func esDescendiente(de raiz: BookmarkCategory,
                                elDestino candidato: BookmarkCategory) -> Bool {
        // Si el destino ES la propia raíz, es un ciclo directo
        if raiz.id == candidato.id { return true }
        // Si el destino está entre los descendientes de la raíz, también formaría ciclo
        var stack = raiz.children
        var visited: Set<UUID> = [raiz.id]
        while let c = stack.popLast() {
            guard visited.insert(c.id).inserted else { continue }
            if c.id == candidato.id { return true }
            stack.append(contentsOf: c.children)
        }
        return false
    }

    /// Reasigna `order` de 0…n-1 a una lista ya ordenada de colecciones.
    /// Garantiza que los índices son contiguos tras eliminar o mover un elemento.
    private func recalcularOrden(hermanos: [BookmarkCategory]) {
        for (idx, cat) in hermanos.enumerated() {
            cat.order = idx
        }
    }

    /// Mueve un enlace (por id) a `category`, o a «Sin clasificar» si es `nil`. Lo usa el
    /// arrastre de un enlace desde la biblioteca hasta una colección (o la cabecera) del
    /// sidebar. Devuelve `false` si no se encuentra o ya estaba en ese destino.
    private func moveLink(_ id: UUID, toCategory category: BookmarkCategory?) -> Bool {
        guard let link = fetchActiveLink(id) else { return false }
        guard link.category?.id != category?.id else { return false }   // ya está ahí
        link.category = category
        LinkIngest.userChangedOrganization(link.id)
        link.updatedAt = Date()
        context.saveLogging()
        SpotlightIndexer.index(link)
        return true
    }

    // MARK: - Fila de proyecto (acceso + destino de arrastre)

    private func projectRow(_ project: Project) -> some View {
        let color = Color(hex: project.colorHex)
        let count = ProjectWorkspaceStore.workspace(for: project.id, in: projectsWorkspaceJSON).linkIDs.count
        return Label {
            HStack {
                Text(project.name).stacklumeLineLimit(1)
                Spacer(minLength: 8)
                if count > 0 {
                    Text("\(count)").monospacedDigit().foregroundStyle(palette.textSecondary)
                }
            }
        } icon: {
            Image(systemName: project.icon).foregroundStyle(color)
        }
        .tag(NavTarget.project(project.id))
        // Soltar un enlace arrastrado desde la biblioteca → añadirlo al proyecto.
        .dropDestination(for: String.self) { items, _ in
            guard let payload = items.first,
                  let bookmarkID = BookmarkTransfer.bookmarkID(from: payload) else { return false }
            return addLink(bookmarkID, toProject: project)
        }
        .contextMenu {
            Button("Editar", systemImage: "pencil") { projectEditor = .edit(project) }
            Button("Eliminar", systemImage: "trash", role: .destructive) {
                requestProjectDelete(project)
            }
        }
    }

    /// Añade un enlace (por id) al proyecto. Devuelve `false` si no existe o ya estaba.
    private func addLink(_ bookmarkID: UUID, toProject project: Project) -> Bool {
        guard fetchActiveLink(bookmarkID) != nil else { return false }
        let current = ProjectWorkspaceStore.workspace(for: project.id, in: projectsWorkspaceJSON).linkIDs
        guard !current.contains(bookmarkID) else { return false }
        projectsWorkspaceJSON = ProjectWorkspaceStore.updating(projectsWorkspaceJSON, for: project.id) { ws in
            if !ws.linkIDs.contains(bookmarkID) { ws.linkIDs.append(bookmarkID) }
        }
        return true
    }

    private func requestProjectDelete(_ project: Project) {
        if confirmBeforeDelete { pendingProjectDelete = project } else { deleteProject(project) }
    }

    private func deleteProject(_ project: Project) {
        if selection == .project(project.id) { selection = .all }
        let now = Date()
        project.deletedAt = now
        project.updatedAt = now
        // El modelo usa borrado lógico. Mantener el workspace lateral evita que una acción
        // recuperable destruya de forma permanente notas, tareas, comandos y pertenencias.
        context.saveLogging()
        WidgetReloader.reload()
    }

    // MARK: - Nodo de etiqueta (árbol con disclosure)

    /// Nodo de una etiqueta con sus subetiquetas. Si tiene hijas activas, usa un
    /// `DisclosureGroup` (plegable); si no, una fila simple. Igual que `collectionNode`,
    /// devuelve `AnyView` para romper la recursión del tipo opaco. Esto materializa la
    /// JERARQUÍA de etiquetas (`#padre/hijo`) que el modelo ya soportaba pero el sidebar
    /// pintaba en plano — algo que Raindrop no ofrece (sus tags son planos).
    private func tagNode(_ tag: Tag) -> AnyView {
        let children = tag.children
            .filter { $0.deletedAt == nil }
            .sorted(by: tagOrder)
        if children.isEmpty {
            return AnyView(
                tagRow(tag)
                    .listRowBackground(selectionPill(.tag(tag.id)))
            )
        } else {
            return AnyView(
                DisclosureGroup {
                    ForEach(children) { child in
                        tagNode(child)
                    }
                } label: {
                    tagRow(tag)
                }
                .listRowBackground(selectionPill(.tag(tag.id)))
            )
        }
    }

    // MARK: - Fila de etiqueta

    private func tagRow(_ tag: Tag) -> some View {
        let color = Color(hex: tag.colorHex)
        return Label {
            HStack {
                editableName(id: tag.id, name: tag.name) { newName in
                    tag.name = newName
                    context.saveLogging()
                    WidgetReloader.reload()
                }
                Spacer(minLength: 8)
                Text(compactCount(linkCount(tag)))      // recuento cacheado (no faulta `.links`)
                    .monospacedDigit()
                    .foregroundStyle(palette.textSecondary)
            }
        } icon: {
            Image(systemName: "number")
                .foregroundStyle(color)
        }
        .tag(NavTarget.tag(tag.id))
        .contentShape(Rectangle())
        // Selección inmediata en clic limpio (mismo motivo que las colecciones: `.draggable`
        // hace ambiguo el primer clic). El arrastre solo se activa al mover.
        .simultaneousGesture(TapGesture().onEnded { selection = .tag(tag.id) })
        // Paridad con las colecciones: menú contextual para renombrar/recolorear/anidar
        // y eliminar la etiqueta (antes no se podían gestionar desde el sidebar).
        .contextMenu {
            Button("Renombrar / Editar", systemImage: "pencil") {
                tagEditor = .edit(tag)
            }
            Divider()
            Button("Eliminar", systemImage: "trash", role: .destructive) {
                if confirmBeforeDelete {
                    pendingTagDelete = tag
                } else {
                    deleteTag(tag)
                }
            }
        }
        // Arrastrable: carga = UUID como String (para reordenar entre etiquetas).
        .draggable(tag.id.uuidString) {
            Label(tag.name, systemImage: "number")
                .padding(6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        // Soltar un ENLACE → añadirle la etiqueta; soltar OTRA ETIQUETA → reordenar
        // (la arrastrada pasa a ir justo antes de esta y se activa el orden manual).
        .dropDestination(for: String.self) { items, _ in
            guard let payload = items.first else { return false }
            if let bookmarkID = BookmarkTransfer.bookmarkID(from: payload) {
                return addTag(tag, toLinkID: bookmarkID)
            }
            if let draggedID = UUID(uuidString: payload), draggedID != tag.id,
               tags.contains(where: { $0.id == draggedID }) {
                return reorderTag(draggedID, before: tag)
            }
            return false
        }
    }

    /// Reordena la etiqueta arrastrada para que quede JUSTO ANTES de `target`, renumerando
    /// el `order` de las hermanas (mismo nivel) según el nuevo orden y activando el «orden
    /// manual» para que el cambio se refleje. Si venía de otro nivel, se reubica en el de
    /// `target`. Devuelve `true` si reordenó.
    private func reorderTag(_ draggedID: UUID, before target: Tag) -> Bool {
        guard let dragged = tags.first(where: { $0.id == draggedID }) else { return false }
        dragged.parent = target.parent
        var ordered = tags
            .filter { $0.parent?.id == target.parent?.id && $0.id != draggedID }
            .sorted(by: tagOrder)
        guard let targetIndex = ordered.firstIndex(where: { $0.id == target.id }) else { return false }
        ordered.insert(dragged, at: targetIndex)
        for (index, tagItem) in ordered.enumerated() { tagItem.order = index }
        tagsManualOrder = true
        context.saveLogging()
        WidgetReloader.reload()
        return true
    }

    /// Añade `tag` al enlace `id` (si no lo tiene ya). Lo usa el arrastre de un enlace
    /// sobre una etiqueta del sidebar.
    private func addTag(_ tag: Tag, toLinkID id: UUID) -> Bool {
        guard let link = fetchActiveLink(id) else { return false }
        guard !link.tags.contains(where: { $0.id == tag.id }) else { return false }
        link.tags.append(tag)
        LinkIngest.userChangedOrganization(link.id)
        link.updatedAt = Date()
        context.saveLogging()
        SpotlightIndexer.index(link)
        return true
    }

    /// Elimina una etiqueta SIN dejar referencias fantasma: la desvincula de todos sus
    /// enlaces (como hace `cleanTags()` en Mantenimiento), reasigna sus subetiquetas al
    /// padre para no huérfanarlas y la marca como borrada. Los enlaces NO se borran.
    private func deleteTag(_ tag: Tag) {
        if selection == .tag(tag.id) { selection = .all }   // si se estaba viendo, vuelve a «Todos»
        for link in Array(tag.links) {
            link.tags.removeAll { $0.id == tag.id }
            LinkIngest.userChangedOrganization(link.id)
            link.updatedAt = Date()
            SpotlightIndexer.index(link)
        }
        for child in Array(tag.children) { child.parent = tag.parent }
        tag.deletedAt = Date()
        context.saveLogging()
        WidgetReloader.reload()
    }

    // MARK: - Renombrado inline (doble clic)

    /// Nombre editable in situ: doble clic lo convierte en campo de texto (paridad
    /// Finder/Raindrop). Enter o perder el foco confirma (si no queda vacío); Esc
    /// cancela. Reutilizado por colecciones y etiquetas; `id` (UUID único) identifica la
    /// fila en edición. Un solo `@FocusState` basta porque solo hay un campo activo a la vez.
    @ViewBuilder
    private func editableName(id: UUID, name: String, commit: @escaping (String) -> Void) -> some View {
        if renamingID == id {
            TextField("Nombre", text: $renameText)
                .textFieldStyle(.plain)
                .focused($renameFieldFocused)
                .onSubmit { finishRename(commit) }
                .onExitCommand { renamingID = nil }          // Esc cancela sin guardar
                .onChange(of: renameFieldFocused) { _, focused in
                    if !focused { finishRename(commit) }     // perder el foco confirma
                }
                .task { renameFieldFocused = true }          // enfocar al aparecer
        } else {
            Text(name)
                .stacklumeLineLimit(1)
                .onTapGesture(count: 2) {
                    renameText = name
                    renamingID = id
                }
        }
    }

    /// Confirma el renombrado en curso. Pone fin a la edición ANTES de aplicar el cambio
    /// para que la pérdida de foco subsiguiente no vuelva a entrar (el guard corta). Ignora
    /// nombres vacíos (deja el original intacto).
    private func finishRename(_ commit: (String) -> Void) {
        guard renamingID != nil else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingID = nil
        guard !trimmed.isEmpty else { return }
        commit(trimmed)
    }

    // MARK: - Frontera de valores del outline propietario

    private final class NativeSnapshotCache {
        var key = "\u{0}"
        var value: SidebarSnapshot?
    }
    @State private var nativeSnapshotCache = NativeSnapshotCache()

    private func nativeSnapshot(_ metrics: SidebarMetrics) -> SidebarSnapshot {
        let key = "\(libraryRevision)|\(selectedCollectionRootID?.uuidString ?? "")|\(collectionsSortMode)|\(tagsByFrequency)|\(tagsManualOrder)|\(filtersExpanded)|\(savedSearchesJSON)|\(projectsWorkspaceJSON)|\(assistantStatus)|\(aiRunner.isBusy)|\(aiRunner.isReady)|\(collectionEnrichTask != nil)|\(highlightsCount)"
        if nativeSnapshotCache.key != key || nativeSnapshotCache.value == nil {
            nativeSnapshotCache.value = buildNativeSnapshot(metrics)
            nativeSnapshotCache.key = key
        }
        var result = nativeSnapshotCache.value!
        result.nodes[.destination(.ai)]?.iconColor = palette.accent
        result.nodes[.action(.collections)]?.iconColor = palette.accent
        result.nodes[.action(.tags)]?.iconColor = palette.accent
        result.expandedGroups = Set([
            collectionsExpanded ? SidebarGroupID.collections : nil,
            tagsExpanded ? .tags : nil, filtersExpanded ? .filters : nil,
            savedExpanded ? .saved : nil, toolsExpanded ? .tools : nil
        ].compactMap { $0 })
        if let id = renamingID {
            for target in [NavTarget.collection(id), .tag(id)] {
                let node = SidebarNodeID.destination(target)
                if result.nodes[node] != nil {
                    result.nodes[node]?.editingUUID = id
                    result.nodes[node]?.editingText = renameText
                }
            }
        }
        return result
    }

    private func buildNativeSnapshot(_ metrics: SidebarMetrics) -> SidebarSnapshot {
        var roots: [SidebarNodeID] = []
        var nodes: [SidebarNodeID: SidebarDescriptor] = [:]
        var parents: [SidebarNodeID: SidebarNodeID] = [:]
        var depths: [SidebarNodeID: Int] = [:]
        var categoryParents: [UUID: UUID] = [:]
        var tagParents: [UUID: UUID] = [:]
        var categoryIDs: Set<UUID> = []
        var tagIDs: Set<UUID> = []
        var projectLinks: [UUID: Set<UUID>] = [:]
        for category in categories where category.modelContext != nil && !category.isDeleted && category.deletedAt == nil {
            categoryIDs.insert(category.id)
            if let parent = category.parent, parent.modelContext != nil && !parent.isDeleted && parent.deletedAt == nil {
                categoryParents[category.id] = parent.id
            }
        }
        for tag in tags where tag.modelContext != nil && !tag.isDeleted && tag.deletedAt == nil {
            tagIDs.insert(tag.id)
            if let parent = tag.parent, parent.modelContext != nil && !parent.isDeleted && parent.deletedAt == nil {
                tagParents[tag.id] = parent.id
            }
        }
        func add(_ row: SidebarDescriptor, parent: SidebarNodeID? = nil) {
            guard nodes[row.id] == nil else { return }
            nodes[row.id] = row
            depths[row.id] = parent.map { (depths[$0] ?? 0) + 1 } ?? 0
            if let parent { parents[row.id] = parent; nodes[parent]?.children.append(row.id) }
            else { roots.append(row.id) }
        }
        func destination(_ target: NavTarget, _ title: String, _ symbol: String, count: Int? = nil,
                         parent: SidebarNodeID? = nil, style: SidebarCounterStyle = .body) {
            add(SidebarDescriptor(id: .destination(target), title: title, target: target, symbol: symbol,
                counter: style == .caption ? count.flatMap { $0 > 0 ? ($0 > 999 ? "999+" : "\($0)") : nil } : count.map(compactCount),
                counterValue: style == .caption ? count.flatMap { $0 > 0 ? $0 : nil } : count, counterStyle: style), parent: parent)
        }
        destination(.all, "Todos", "square.stack", count: metrics.all)
        destination(.inbox, "Bandeja", "tray.full", count: metrics.inbox)
        add(SidebarDescriptor(id: .destination(.ai), title: "Asistente IA", kind: .assistant,
            target: .ai, symbol: "sparkles", iconColor: palette.accent, status: assistantStatus,
            busy: aiRunner.isBusy, accessibilityHint: "Abre el chat local con tu biblioteca"))
        add(SidebarDescriptor(id: .section(.library), title: "Biblioteca", kind: .header))
        destination(.favorites, "Favoritos", "star", count: metrics.favorites)
        destination(.readingQueue, "Cola de lectura", "clock", count: metrics.queue)
        destination(.highlights, "Resaltados", "highlighter", count: highlightsCount)
        destination(.unsorted, "Sin clasificar", "tray", count: metrics.unsorted)
        add(SidebarDescriptor(id: .section(.explore), title: "Explorar", kind: .header))
        destination(.connections, "Conexiones", "point.3.connected.trianglepath.dotted")
        destination(.discover, "Descubrir", "safari")
        destination(.huggingFace, "Hugging Face", "cpu")
        destination(.civitai, "Civitai", "photo.on.rectangle.angled")
        destination(.x, "X", "at")
        let collectionMenu = [
            SidebarMenuEntry(title: "Orden manual (arrastra)", symbol: "hand.draw", action: .collectionSort("manual"), checked: collectionsSortMode == "manual"),
            SidebarMenuEntry(title: "Ordenar por nombre", symbol: "textformat", action: .collectionSort("alpha"), checked: collectionsSortMode == "alpha"),
            SidebarMenuEntry(title: "Ordenar por nº de enlaces", symbol: "number", action: .collectionSort("count"), checked: collectionsSortMode == "count")
        ]
        add(SidebarDescriptor(id: .group(.collections), title: "Colecciones", kind: .group,
            counter: "\(metrics.categoryTotal)", counterValue: metrics.categoryTotal, counterUnit: "colecciones", counterStyle: .caption2,
            menu: collectionMenu, accessories: [
                SidebarAccessory(title: "Ordenar colecciones", symbol: "arrow.up.arrow.down", menu: collectionMenu),
                SidebarAccessory(title: "Nueva colección", symbol: "plus", action: .createCategory)
            ]))
        var visitedCategories: Set<UUID> = []
        func categoryNode(_ category: BookmarkCategory, parent: SidebarNodeID) {
            guard category.modelContext != nil, !category.isDeleted, category.deletedAt == nil,
                  visitedCategories.insert(category.id).inserted else { return }
            let id = category.id
            let node = SidebarNodeID.destination(.collection(id))
            var menu = [
                SidebarMenuEntry(title: "Renombrar / Editar", symbol: "pencil", action: .editCategory(id)),
                SidebarMenuEntry(title: "Nueva subcolección", symbol: "folder.badge.plus", action: .subcategory(id)), .divider,
                SidebarMenuEntry(title: "Abrir todos los enlaces", symbol: "safari", action: .openCategory(id)),
                SidebarMenuEntry(title: "Copiar enlaces", symbol: "doc.on.doc", action: .copyCategory(id)),
                SidebarMenuEntry(title: "Exportar", symbol: "square.and.arrow.up", children: [
                    SidebarMenuEntry(title: "Como JSON…", action: .exportJSON(id)),
                    SidebarMenuEntry(title: "Como HTML (marcadores)…", action: .exportHTML(id))]), .divider
            ]
            if aiRunner.isReady { menu.append(SidebarMenuEntry(title: "Mejorar con IA", symbol: "wand.and.stars", action: .enrichCategory(id), enabled: collectionEnrichTask == nil)) }
            menu += [.divider, SidebarMenuEntry(title: "Eliminar", symbol: "trash", action: .deleteCategory(id))]
            let count = metrics.categoryCounts[id] ?? 0
            add(SidebarDescriptor(id: node, title: category.name, target: .collection(id), symbol: category.icon,
                iconColor: Color(hex: category.colorHex), imageData: category.coverImageData,
                counter: compactCount(count), counterValue: count, truncatesTitle: true, menu: menu, dragUUID: id), parent: parent)
            for child in category.children.filter({ $0.modelContext != nil && !$0.isDeleted && $0.deletedAt == nil }).sorted(by: collectionOrder) {
                categoryNode(child, parent: node)
            }
        }
        for category in sidebarRootCategories { categoryNode(category, parent: .group(.collections)) }
        if rootCategories.count > Self.sidebarCollectionLimit {
            add(SidebarDescriptor(id: .action(.collections), title: "Ver todas (\(metrics.categoryTotal))", kind: .index,
                symbol: "ellipsis.circle", iconColor: palette.accent, action: .allCollections,
                accessibilityHint: "Abre un índice buscable con todas las colecciones"), parent: .group(.collections))
        }
        if metrics.tagTotal > 0 {
            var menu = [
                SidebarMenuEntry(title: "Ordenar por frecuencia", symbol: "arrow.down.circle", action: .tagSort("frequency"), checked: !tagsManualOrder && tagsByFrequency),
                SidebarMenuEntry(title: "Ordenar por nombre", symbol: "textformat", action: .tagSort("name"), checked: !tagsManualOrder && !tagsByFrequency),
                SidebarMenuEntry(title: "Orden manual (arrastra)", symbol: "hand.draw", action: .tagSort("manual"), checked: tagsManualOrder)
            ]
            if metrics.tagTotal > Self.sidebarTagLimit { menu += [.divider, SidebarMenuEntry(title: "Ver todas (\(metrics.tagTotal))", symbol: "ellipsis.circle", action: .allTags)] }
            add(SidebarDescriptor(id: .group(.tags), title: "Etiquetas", kind: .group,
                counter: "\(metrics.tagTotal)", counterValue: metrics.tagTotal, counterUnit: "etiquetas", counterStyle: .caption2, menu: menu))
            var visitedTags: Set<UUID> = []
            func tagNode(_ tag: Tag, parent: SidebarNodeID) {
                guard tag.modelContext != nil, !tag.isDeleted, tag.deletedAt == nil, visitedTags.insert(tag.id).inserted else { return }
                let id = tag.id, node = SidebarNodeID.destination(.tag(tag.id)), count = metrics.tagCounts[tag.id] ?? 0
                add(SidebarDescriptor(id: node, title: tag.name, target: .tag(id), symbol: "number", iconColor: Color(hex: tag.colorHex),
                    counter: compactCount(count), counterValue: count, truncatesTitle: true,
                    menu: [SidebarMenuEntry(title: "Renombrar / Editar", symbol: "pencil", action: .editTag(id)), .divider,
                           SidebarMenuEntry(title: "Eliminar", symbol: "trash", action: .deleteTag(id))], dragUUID: id), parent: parent)
                for child in tag.children.filter({ $0.modelContext != nil && !$0.isDeleted && $0.deletedAt == nil }).sorted(by: tagOrder) {
                    tagNode(child, parent: node)
                }
            }
            for tag in sidebarRootTags { tagNode(tag, parent: .group(.tags)) }
            if rootTags.count > Self.sidebarTagLimit {
                add(SidebarDescriptor(id: .action(.tags), title: "Ver todas (\(metrics.tagTotal))", kind: .index,
                    symbol: "ellipsis.circle", iconColor: palette.accent, action: .allTags), parent: .group(.tags))
            }
        }
        add(SidebarDescriptor(id: .group(.filters), title: "Filtros", kind: .group))
        for filter in Self.sidebarSmartFilters {
            destination(.smart(filter), filter.title, filter.icon, count: filtersExpanded ? smartCount(filter) : nil,
                        parent: .group(.filters), style: .caption)
        }
        if !savedSearches.isEmpty {
            add(SidebarDescriptor(id: .group(.saved), title: "Búsquedas guardadas", kind: .group))
            for search in savedSearches {
                add(SidebarDescriptor(id: .destination(.savedSearch(search.id)), title: search.name, target: .savedSearch(search.id),
                    symbol: "line.3.horizontal.decrease.circle", menu: [SidebarMenuEntry(title: "Eliminar", symbol: "trash", action: .deleteSearch(search.id))]), parent: .group(.saved))
            }
        }
        add(SidebarDescriptor(id: .section(.projects), title: "Proyectos", kind: .header,
            accessories: [SidebarAccessory(title: "Nuevo proyecto", symbol: "plus", action: .createProject)]))
        for project in projects where project.modelContext != nil && !project.isDeleted && project.deletedAt == nil {
            let links = ProjectWorkspaceStore.workspace(for: project.id, in: projectsWorkspaceJSON).linkIDs
            projectLinks[project.id] = Set(links)
            add(SidebarDescriptor(id: .destination(.project(project.id)), title: project.name, target: .project(project.id), symbol: project.icon,
                iconColor: Color(hex: project.colorHex), counter: links.isEmpty ? nil : "\(links.count)",
                counterValue: links.isEmpty ? nil : links.count, truncatesTitle: true,
                menu: [SidebarMenuEntry(title: "Editar", symbol: "pencil", action: .editProject(project.id)),
                       SidebarMenuEntry(title: "Eliminar", symbol: "trash", action: .deleteProject(project.id))]))
        }
        add(SidebarDescriptor(id: .group(.tools), title: "Herramientas", kind: .group))
        destination(.sessions, "Sesiones", "rectangle.stack.fill", parent: .group(.tools))
        destination(.rules, "Reglas", "wand.and.stars", parent: .group(.tools))
        destination(.stats, "Estadísticas", "chart.bar.fill", parent: .group(.tools))
        return SidebarSnapshot(roots: roots, nodes: nodes, parents: parents, depths: depths, expandedGroups: [],
            categoryParents: categoryParents, categoryIDs: categoryIDs, tagParents: tagParents, tagIDs: tagIDs,
            bookmarks: metrics.bookmarks, projectLinks: projectLinks)
    }

    private func nativeSetExpanded(_ group: SidebarGroupID, _ value: Bool) {
        switch group {
        case .collections: if collectionsExpanded != value { collectionsExpanded = value }
        case .tags: if tagsExpanded != value { tagsExpanded = value }
        case .filters: if filtersExpanded != value { filtersExpanded = value }
        case .saved: if savedExpanded != value { savedExpanded = value }
        case .tools: if toolsExpanded != value { toolsExpanded = value }
        }
    }
    private func nativeCategory(_ id: UUID) -> BookmarkCategory? {
        categories.first { $0.modelContext != nil && !$0.isDeleted && $0.deletedAt == nil && $0.id == id }
    }
    private func nativeTag(_ id: UUID) -> Tag? {
        tags.first { $0.modelContext != nil && !$0.isDeleted && $0.deletedAt == nil && $0.id == id }
    }
    private func nativeProject(_ id: UUID) -> Project? {
        projects.first { $0.modelContext != nil && !$0.isDeleted && $0.deletedAt == nil && $0.id == id }
    }
    private func nativePerform(_ action: SidebarAction) {
        switch action {
        case .allCollections: showAllCollections = true
        case .allTags: showAllTags = true
        case .createCategory: categoryEditor = .create
        case .createProject: projectEditor = .create
        case .collectionSort(let mode): if ["manual", "alpha", "count"].contains(mode) { collectionsSortMode = mode }
        case .tagSort(let mode):
            switch mode {
            case "frequency": tagsByFrequency = true; tagsManualOrder = false
            case "name": tagsByFrequency = false; tagsManualOrder = false
            case "manual": tagsManualOrder = true
            default: break
            }
        case .editCategory(let id): if let model = nativeCategory(id) { categoryEditor = .edit(model) }
        case .subcategory(let id): if let model = nativeCategory(id) { createSubcollection(of: model) }
        case .openCategory(let id): if let model = nativeCategory(id) { openAll(in: model) }
        case .copyCategory(let id): if let model = nativeCategory(id) { copyLinks(in: model) }
        case .exportJSON(let id): if let model = nativeCategory(id) { CollectionExporter.exportJSON(model, in: context) }
        case .exportHTML(let id): if let model = nativeCategory(id) { CollectionExporter.exportHTML(model) }
        case .enrichCategory(let id):
            if aiRunner.isReady, collectionEnrichTask == nil, let model = nativeCategory(id) { startCollectionEnrich(model) }
        case .deleteCategory(let id): if let model = nativeCategory(id) { requestCategoryDelete(model) }
        case .editTag(let id): if let model = nativeTag(id) { tagEditor = .edit(model) }
        case .deleteTag(let id):
            if let model = nativeTag(id) { if confirmBeforeDelete { pendingTagDelete = model } else { deleteTag(model) } }
        case .editProject(let id): if let model = nativeProject(id) { projectEditor = .edit(model) }
        case .deleteProject(let id): if let model = nativeProject(id) { requestProjectDelete(model) }
        case .deleteSearch(let id): if let search = savedSearches.first(where: { $0.id == id }) { deleteSavedSearch(search) }
        case .beginRename(let id):
            if let model = nativeCategory(id) { renameText = model.name; renamingID = id }
            else if let model = nativeTag(id) { renameText = model.name; renamingID = id }
        case .updateRename(let id, let value): if renamingID == id { renameText = value }
        case .finishRename(let id, let value):
            guard renamingID == id else { return }
            renameText = value
            if let model = nativeCategory(id) { finishRename { model.name = $0; context.saveLogging(); WidgetReloader.reload() } }
            else if let model = nativeTag(id) { finishRename { model.name = $0; context.saveLogging(); WidgetReloader.reload() } }
            else { renamingID = nil }
        case .cancelRename: renamingID = nil
        }
    }

    private func nativeAcceptDrop(_ payload: String, _ drop: SidebarDrop) -> Bool {
        // Revalidación fresca después del validateDrop, que solo consultó valores.
        nativeSnapshotCache.key = "\u{0}"
        metricsCache.key = "\u{0}"
        let fresh = nativeSnapshot(refreshSidebarMetrics())
        guard fresh.allows(payload, drop: drop) else { return false }
        if let bookmarkID = BookmarkTransfer.bookmarkID(from: payload) {
            switch drop.target {
            case .group(.collections): return moveLink(bookmarkID, toCategory: nil)
            case .destination(.collection(let id)):
                guard let model = nativeCategory(id) else { return false }
                return moveLink(bookmarkID, toCategory: model)
            case .destination(.tag(let id)):
                guard let model = nativeTag(id) else { return false }
                return addTag(model, toLinkID: bookmarkID)
            case .destination(.project(let id)):
                guard let model = nativeProject(id) else { return false }
                return addLink(bookmarkID, toProject: model)
            case .destination(let target): return applySystemDrop(target, bookmarkID: bookmarkID)
            default: return false
            }
        }
        guard let draggedID = UUID(uuidString: payload) else { return false }
        switch drop.target {
        case .group(.collections):
            guard let dragged = nativeCategory(draggedID), dragged.parent != nil else { return false }
            dragged.parent = nil
            recalcularOrden(hermanos: rootCategories.filter { $0.id != draggedID })
            dragged.order = rootCategories.filter { $0.id != draggedID }.count
            context.saveLogging()
            return true
        case .destination(.collection(let targetID)):
            guard let dragged = nativeCategory(draggedID), let category = nativeCategory(targetID),
                  !esDescendiente(de: dragged, elDestino: category) else { return false }
            if drop.position != .on {
                insertar(dragged: dragged, relativoA: category, posicion: drop.position == .before ? .before : .after)
                return true
            }
            let hermanos = category.children
                .filter { $0.deletedAt == nil && $0.id != draggedID }
                .sorted { $0.order < $1.order }
            recalcularOrden(hermanos: hermanos)
            dragged.order = hermanos.count
            dragged.parent = category
            context.saveLogging()
            return true
        case .destination(.tag(let targetID)):
            guard let model = nativeTag(targetID), nativeTag(draggedID) != nil else { return false }
            return reorderTag(draggedID, before: model)
        default: return false
        }
    }

}
