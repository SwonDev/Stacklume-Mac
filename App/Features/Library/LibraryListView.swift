import SwiftUI
import SwiftData
import AppKit
import StacklumeCore
import StacklumeDesignSystem
import StacklumePersistence

/// Acción primaria opcional de una sección de biblioteca. Se representa en la cabecera
/// funcional —junto al selector de vista— y evita crear toolbars o cabeceras paralelas.
struct LibraryHeaderAction {
    let title: String
    let systemImage: String
    let action: () -> Void
}

/// Mantiene la identidad y los controles en una fila mientras conserven su ancho
/// legible; cuando la columna central se estrecha, crea una segunda fila alineada
/// a la derecha en vez de permitir que SwiftUI comprima texto letra por letra.
private struct CollectionHeaderAdaptiveLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count == 2 else { return .zero }

        let identityIdeal = subviews[0].sizeThatFits(.unspecified)
        let controlsIdeal = subviews[1].sizeThatFits(.unspecified)
        let availableWidth = resolvedWidth(
            proposal.width,
            fallback: identityIdeal.width + spacing + controlsIdeal.width
        )
        let stacked = CollectionHeaderLayoutPolicy.shouldStack(
            availableWidth: availableWidth,
            identityIdealWidth: identityIdeal.width,
            controlsIdealWidth: controlsIdeal.width,
            spacing: spacing
        )

        if stacked {
            let identity = subviews[0].sizeThatFits(
                ProposedViewSize(width: availableWidth, height: nil)
            )
            let controls = subviews[1].sizeThatFits(
                ProposedViewSize(width: availableWidth, height: nil)
            )
            return CGSize(
                width: availableWidth,
                height: identity.height + spacing + controls.height
            )
        }

        let identityWidth = max(0, availableWidth - controlsIdeal.width - spacing)
        let identity = subviews[0].sizeThatFits(
            ProposedViewSize(width: identityWidth, height: nil)
        )
        return CGSize(
            width: availableWidth,
            height: max(identity.height, controlsIdeal.height)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 2 else { return }

        let identityIdeal = subviews[0].sizeThatFits(.unspecified)
        let controlsIdeal = subviews[1].sizeThatFits(.unspecified)
        let stacked = CollectionHeaderLayoutPolicy.shouldStack(
            availableWidth: bounds.width,
            identityIdealWidth: identityIdeal.width,
            controlsIdealWidth: controlsIdeal.width,
            spacing: spacing
        )

        if stacked {
            let identityProposal = ProposedViewSize(width: bounds.width, height: nil)
            let identity = subviews[0].sizeThatFits(identityProposal)
            let controlsProposal = ProposedViewSize(width: bounds.width, height: nil)
            subviews[0].place(
                at: bounds.origin,
                anchor: .topLeading,
                proposal: identityProposal
            )
            subviews[1].place(
                at: CGPoint(x: bounds.maxX, y: bounds.minY + identity.height + spacing),
                anchor: .topTrailing,
                proposal: controlsProposal
            )
            return
        }

        let identityWidth = max(0, bounds.width - controlsIdeal.width - spacing)
        let identityProposal = ProposedViewSize(width: identityWidth, height: nil)
        let controlsProposal = ProposedViewSize(width: controlsIdeal.width, height: nil)
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.midY),
            anchor: .leading,
            proposal: identityProposal
        )
        subviews[1].place(
            at: CGPoint(x: bounds.maxX, y: bounds.midY),
            anchor: .trailing,
            proposal: controlsProposal
        )
    }

    private func resolvedWidth(_ proposedWidth: CGFloat?, fallback: CGFloat) -> CGFloat {
        guard let proposedWidth, proposedWidth.isFinite else { return max(0, fallback) }
        return max(0, proposedWidth)
    }
}

/// Lista de enlaces filtrada (columna central o destino de una taxonomía), con
/// búsqueda y ordenación. Reutilizable con cualquier `LinkFilter` base.
///
/// La cabecera de colección (banner + título + selector de vista + metadatos/orden/
/// filtros) vive DENTRO de la vista, fija arriba (no la toolbar del sistema): solo
/// el contenido (lista/cuadrícula/moodboard/titulares) hace scroll debajo.
/// Ver DESIGN.md §4.
struct LibraryListView: View {
    let title: String
    let icon: String
    let emptyMessage: String
    let baseFilter: LinkFilter
    var allowsCreate: Bool = false
    var headerAction: LibraryHeaderAction? = nil
    /// Cuando es `true`, muestra la cola de lectura: todo lo que no esté «leído»
    /// (`readingStatus != .done`), igual que el iPhone. Se aplica como filtro
    /// adicional porque `LinkFilter.readingStatus` solo admite igualdad exacta.
    var readingQueueMode: Bool = false
    /// Conjunto de ids de colección (la propia + todos sus descendientes) al que se
    /// restringe la lista. Se aplica como post-filtro porque `LinkFilter.categoryID`
    /// solo admite una colección exacta y aquí queremos incluir las subcolecciones.
    /// `nil` = sin restricción por alcance de colección.
    var collectionScope: Set<UUID>? = nil
    /// Enlaces YA ACOTADos por la relación INVERSA (colección.links / etiqueta.links),
    /// preparados por `SectionContentView`. Cuando está presente, la lista filtra/ordena SOBRE
    /// este subconjunto en vez de recorrer y faultear toda la biblioteca: entrar en una colección
    /// o etiqueta con pocos enlaces NO debe tocar los miles restantes (era el coste de entrar).
    /// `nil` = biblioteca completa (`@Query links`), p. ej. en «Todos»/Favoritos/filtros.
    var scopedLinks: [Bookmark]? = nil
    /// Portada opcional de la colección (JPEG). Si está presente, la cabecera muestra
    /// un banner con degradado. Solo se alimenta para destinos `.collection(id)`.
    var coverImageData: Data? = nil
    /// Color de marca de la colección (`colorHex`) para teñir el degradado del banner.
    /// `nil` = se usa el acento por defecto del tema.
    var headerTintHex: String? = nil
    /// Descripción/nota de la colección que se muestra en la subfila de metadatos,
    /// junto al contador de enlaces. `nil` = sin descripción.
    var headerSubtitle: String? = nil
    /// Clave estable de la sección (la `key` del `NavTarget`: `all`, `collection:<uuid>`,
    /// `tag:<uuid>`, `smart:<f>`…). Identifica las preferencias de vista propias de esta
    /// sección (modo + tamaño de portada), para que CADA colección las recuerde por
    /// separado (paridad con Raindrop). `"global"` = sin sección concreta.
    var viewScope: String = "global"
    /// Búsqueda guardada a aplicar AL APARECER (Smart Folder abierto desde el lateral):
    /// fija texto + filtros del usuario como punto de partida. `nil` = sección normal.
    var initialSavedSearch: SavedSearch? = nil
    /// Selección MÚLTIPLE nativa: los modos basados en `List` (Lista/Titulares) la
    /// reciben directamente en `List(selection:)` (⌘/⇧-clic gratis); Cuadrícula y
    /// Moodboard la operan con tap (reemplaza por uno) y ⌘-clic (alterna pertenencia).
    @Binding var selection: Set<Bookmark.ID>

    @Environment(\.modelContext) private var context
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @Environment(LibraryActions.self) private var actions
    // Solo ACTIVOS, filtrados en la BD (SQLite): no traer borrados reduce el conjunto que se
    // recorre/filtra/ordena en memoria. La papelera usa su propia consulta; esta vista nunca
    // muestra borrados (todos los flujos ya descartaban `deletedAt != nil`). Clave a escala.
    @Query(filter: #Predicate<Bookmark> { $0.deletedAt == nil })
    private var links: [Bookmark]
    /// Conjunto base sobre el que filtra/ordena la vista: el subconjunto YA acotado por la
    /// relación inversa (`scopedLinks`, en colección/etiqueta) o, si no, la biblioteca completa.
    /// Usar esto —y no `links`— en todo el camino de filtrado evita faultear `.category`/`.tags`
    /// de los miles de enlaces de fuera del alcance al entrar en una colección o etiqueta.
    private var sourceLinks: [Bookmark] { scopedLinks ?? links }
    /// Espacio para el morphing de cristal del realce del modo de vista activo: el
    /// «pill» dorado se desliza entre iconos al alternar de modo (DESIGN.md §8).
    @Namespace private var viewModeGlass
    /// Categorías activas (para el submenú «Categoría» de los filtros y el menú «Mover a
    /// colección» de la barra de lote).
    @Query(filter: #Predicate<BookmarkCategory> { $0.deletedAt == nil }, sort: \BookmarkCategory.order)
    private var categories: [BookmarkCategory]
    /// Etiquetas activas (para el menú «Etiquetar» de la barra de lote).
    @Query(filter: #Predicate<Tag> { $0.deletedAt == nil }, sort: \Tag.order)
    private var tags: [Tag]
    // Proyectos: SOLO para inyectar en el menú contextual de cada fila (consulta UNA vez aquí,
    // no un @Query por fila dentro de `LinkContextMenu` —eso costaba en el scroll).
    @Query(filter: #Predicate<Project> { $0.deletedAt == nil }, sort: \Project.order)
    private var menuProjects: [Project]
    /// Ajustes (para respetar `confirmBeforeDelete` al mover varios a la papelera).
    @Query private var settingsList: [AppSettings]
    /// `true` si hay que confirmar antes de borrar (por defecto, sí).
    private var confirmBeforeDelete: Bool { settingsList.first?.confirmBeforeDelete ?? true }

    @State private var searchText = ""
    /// Diálogo de confirmación del borrado en lote (solo si `confirmBeforeDelete`).
    @State private var showBulkDeleteConfirm = false
    /// Hojas buscables de lote (mover a colección / etiquetar). Escalan mejor que la lista
    /// plana del `Menu` cuando hay muchas colecciones o etiquetas. Ver [[BulkPickerSheets]].
    @State private var showCollectionPicker = false
    @State private var showFilterCollectionPicker = false
    @State private var showTagPicker = false
    /// Confirmación de «Abrir todos» cuando son muchos enlaces.
    @State private var openAllRequest: OpenAllRequest?
    /// Orden activo, PERSISTIDO entre sesiones y secciones (antes era `@State` y se
    /// reiniciaba a «recientes» al navegar o reabrir la app). Global a la biblioteca.
    @AppStorage("stacklume.librarySort") private var sortRaw = LinkSort.recent.rawValue
    private var sort: LinkSort { LinkSort(rawValue: sortRaw) ?? .recent }
    private var sortBinding: Binding<LinkSort> {
        Binding(get: { LinkSort(rawValue: sortRaw) ?? .recent },
                set: { sortRaw = $0.rawValue })
    }

    // Búsqueda por significado (embeddings on-device). Persistida entre sesiones para
    // que el usuario que la prefiere no tenga que reactivarla. Paridad con el iPhone,
    // pero con su propio modo de vista (es un MODO de búsqueda, no un filtro).
    @AppStorage("stacklume.search.embeddinggemma2.enabled") private var semanticMode = true
    @State private var multimodalMatches: [MultimodalSearchMatch] = []
    @State private var multimodalInputKey = ""
    @State private var searchFile: URL?
    @State private var showSearchFilePicker = false
    @State private var searchError: String?
    @State private var multimodalTask: Task<Void, Never>?
    /// Sube al terminar el precalentado semántico, para re-evaluar los resultados sin
    /// bloquear la UI mientras se calculan los vectores en 2.º plano.
    @State private var semanticReadyToken = 0
    @State private var warmingSemantic = false
    /// Revisión monotónica del modelo. La incrementa cada guardado correcto y permite que
    /// las claves derivadas sean O(1), sin recorrer toda la biblioteca por cada render.
    @State private var libraryRevision: UInt = 0
    /// Generación del precalentado semántico (debounce + descarte de tareas obsoletas).
    @State private var warmGeneration = 0
    /// Progreso del enriquecido con IA en lote sobre la selección (done, total).
    @State private var aiEnrichProgress: (done: Int, total: Int)?

    // Búsquedas guardadas: capturan texto + filtros activos y se muestran como chips
    // en la cabecera. Persisten en JSON (`@AppStorage`), igual que el iPhone (forma
    // interoperable). Es global a la app (no por sección) para que estén siempre a mano.
    @AppStorage("stacklume.savedSearches") private var savedSearchesJSON = ""
    /// Preferencias de vista POR SECCIÓN (modo + tamaño de portada), JSON `scope → pref`.
    /// Paridad con Raindrop: cada colección recuerda su propia vista. Ver `viewScope`.
    @AppStorage("stacklume.libraryViewPrefs") private var viewPrefsJSON = ""
    /// Modo por defecto heredado (clave histórica): se usa cuando una sección aún no
    /// tiene preferencia propia, conservando el último modo global elegido como base.
    @AppStorage("stacklume.libraryViewMode") private var defaultModeRaw = LibraryViewMode.list.rawValue
    /// Borrador del tamaño de portada mientras se arrastra el deslizador: redimensiona la
    /// rejilla EN VIVO sin escribir en disco hasta soltar (evita escrituras por frame).
    @State private var coverScaleDraft: Double?
    /// Presentación del popover de tamaño de portada.
    @State private var showingCoverSize = false

    /// Caché de la preferencia decodificada: `currentPref` se consulta varias veces por render
    /// (`mode`, `grouping`, `groupingApplies`, `coverScale`, `viewScope`…) y CADA acceso
    /// decodificaba el JSON de `@AppStorage` entero (un `JSONDecoder` por acceso, visible en el
    /// `sample` del scroll). Se decodifica solo cuando cambia el JSON o el modo por defecto.
    private final class PrefCache { var key = "\u{0}"; var pref: LibraryViewPref? }
    @State private var prefCache = PrefCache()

    /// Preferencia de la sección actual (o la base heredada si aún no tiene una propia). Cacheada.
    private var currentPref: LibraryViewPref {
        let key = "\(viewPrefsJSON)|\(defaultModeRaw)"
        if prefCache.key == key, let p = prefCache.pref { return p }
        let pref = LibraryViewPrefsStore.decode(viewPrefsJSON)[viewScope]
            ?? LibraryViewPref(mode: defaultModeRaw, coverScale: 1.0)
        prefCache.key = key
        prefCache.pref = pref
        return pref
    }
    private var mode: LibraryViewMode {
        if MarketingDemoRuntime.isActive, let override = MarketingDemoRuntime.viewModeOverride {
            return override
        }
        return LibraryViewMode(rawValue: currentPref.mode) ?? .list
    }

    /// Agrupación activa de esta sección (Group by). Persistida por sección como el modo.
    private var grouping: LibraryGrouping { LibraryGrouping(rawValue: currentPref.grouping) ?? .none }
    /// ¿La vista actual admite agrupar? Lista, Titulares y Cuadrícula. El Moodboard
    /// (masonry por columnas) no se agrupa: las secciones romperían el apilado.
    private var groupingApplies: Bool { mode == .list || mode == .headlines || mode == .grid }
    private var groupingBinding: Binding<LibraryGrouping> {
        Binding(get: { grouping },
                set: { newValue in updatePref { $0.grouping = newValue.rawValue } })
    }
    /// Tamaño de portada efectivo: el borrador en vivo si se está arrastrando, si no el
    /// persistido. Acotado a un rango cómodo (Cuadrícula/Moodboard).
    private var coverScale: Double {
        min(1.6, max(0.7, coverScaleDraft ?? currentPref.coverScale))
    }

    /// Aplica un cambio a la preferencia de la sección actual y lo persiste.
    private func updatePref(_ transform: (inout LibraryViewPref) -> Void) {
        var dict = LibraryViewPrefsStore.decode(viewPrefsJSON)
        var pref = dict[viewScope] ?? LibraryViewPref(mode: defaultModeRaw, coverScale: 1.0)
        transform(&pref)
        dict[viewScope] = pref
        viewPrefsJSON = LibraryViewPrefsStore.encode(dict)
    }

    // Filtros (paridad con el iPhone). Cada uno se compone sobre `baseFilter`.
    @State private var selectedType: ContentType?
    @State private var selectedPlatform: Platform?
    @State private var selectedCategoryID: UUID?
    @State private var smartFilter: SmartFilter?
    /// ¿Ya se aplicó `initialSavedSearch`? (solo una vez al abrir un Smart Folder).
    @State private var appliedInitialSearch = false

    /// Plataformas realmente presentes en la biblioteca (frecuencia desc.), para no
    /// ofrecer plataformas sin enlaces. Se omite `.generic` (la mayoría de webs).
    @MainActor
    private var availablePlatforms: [Platform] {
        // La revisión cubre altas, bajas y cambios de plataforma. No se consulta siquiera
        // `sourceLinks.count` en un hit: acceder a un `@Query` puede materializar su snapshot
        // observado y era apreciable durante recomposiciones rápidas.
        let key = "\(libraryRevision)"
        if platformsCache.key == key { return platformsCache.result }
        let counts = Dictionary(grouping: sourceLinks.filter { $0.platform != .generic },
                                by: \.platform).mapValues(\.count)
        let result = counts.keys.sorted { counts[$0] ?? 0 > counts[$1] ?? 0 }
        platformsCache.key = key
        platformsCache.result = result
        return result
    }

    /// Número de filtros activos (excluye el filtro base de la sección y la búsqueda),
    /// para resaltar el menú como detalle premium.
    private var activeFilterCount: Int {
        var n = 0
        if selectedType != nil { n += 1 }
        if selectedPlatform != nil { n += 1 }
        if selectedCategoryID != nil { n += 1 }
        if smartFilter != nil { n += 1 }
        return n
    }

    /// Idioma activo (de los ajustes) que elige el modelo de embeddings de oraciones.
    /// Por defecto español, igual que el iPhone.
    private var language: String { (settingsList.first?.language ?? .es).rawValue }

    /// Texto de búsqueda recortado (sin espacios), reutilizado por la lógica semántica.
    private var trimmedQuery: String { searchText.trimmingCharacters(in: .whitespaces) }

    /// Caché de `filtered` por huella (clase de referencia: mutar sus campos NO reasigna
    /// el `@State`, así que no dispara «modifying state during update» ni recomputa en
    /// cada repintado). `filtered` se invocaba varias veces por `body` (contenido,
    /// contador, selección) y se recalculaba en cada render (hover, selección, resize…).
    private final class FilterCache {
        var key = "\u{0}"   // valor imposible: fuerza el primer cálculo
        var result: [Bookmark] = []
    }
    @State private var filterCache = FilterCache()

    /// Caché del AGRUPADO (mismo patrón que `FilterCache`): reagrupar (diccionario + orden
    /// localizado de títulos de grupo) en cada render es O(n) y, en modo «por colección»,
    /// faulta `.category` por enlace. Se cachea por (clave de filtrado ya calculada · modo de
    /// agrupado), así solo se recalcula cuando cambia el conjunto visible o el criterio.
    private final class GroupCache {
        var key = "\u{0}"
        var result: [LinkGroup] = []
    }
    @State private var groupCache = GroupCache()

    /// Caché de `availablePlatforms` (mismo patrón que las anteriores): construir el
    /// `Dictionary(grouping:)` sobre TODA la biblioteca —faulteando `.platform` por enlace— en
    /// cada render, aun solo para el `if !isEmpty` del menú de filtros, era un coste O(n) que
    /// medía el `sample` del arranque. La plataforma de un enlace no cambia, así que basta con
    /// recalcular cuando cambia el nº de enlaces.
    private final class PlatformsCache { var key = "\u{0}"; var result: [Platform] = [] }
    @State private var platformsCache = PlatformsCache()

    /// Ancla para la selección por ⇧-clic (rango) en la lista perezosa (antes la daba el `List`).
    @State private var selectionAnchor: Bookmark.ID?
    /// Objetivo de scroll para navegar con las flechas ↑/↓ en la lista perezosa.
    @State private var scrollToID: Bookmark.ID?

    /// Item de fila con identidad e igualdad de VALOR (no del @Model). Acceder a `Bookmark.id`
    /// pasa por el backing de SwiftData y era EL coste dominante del scroll: el `ForEach`
    /// enumeraba los ~694 ids POR FOTOGRAMA. Extrayendo `id`/`version` UNA vez a este struct,
    /// el `ForEach` usa un `UUID`/`Date` baratos durante el scroll. `link` es solo una
    /// referencia (no toca SwiftData hasta pintar la fila).
    private struct RowItem: Identifiable, Equatable {
        let id: UUID
        let version: Date
        let link: Bookmark
        init(link: Bookmark) { self.id = link.id; self.version = link.updatedAt; self.link = link }
        static func == (lhs: RowItem, rhs: RowItem) -> Bool {
            lhs.id == rhs.id && lhs.version == rhs.version
        }
    }

    /// Caché PEREZOSA del snapshot de fila (`LinkRowData`): se construye SOLO para las filas que
    /// realmente se renderizan (no las ~500 de una colección al entrar) y se REUTILIZA en cada
    /// re-render mientras el enlace no cambie (clave id+updatedAt). Así entrar en una colección
    /// grande NO faulta las ~10 propiedades de cientos de enlaces de golpe (eso era el coste de
    /// entrar), y el scroll sigue sin faultar el `@Model` por fotograma.
    private final class RowDataCache { var map: [UUID: (version: Date, data: LinkRowData)] = [:] }
    @State private var rowDataCache = RowDataCache()
    private func rowData(for item: RowItem) -> LinkRowData {
        if let c = rowDataCache.map[item.id], c.version == item.version { return c.data }
        let data = LinkRowData(link: item.link)
        // Cota de memoria (decenas de miles): si se cachearon demasiados, vacía y reconstruye lo
        // visible bajo demanda. Nunca incorrecto, solo recomputa perezosamente.
        if rowDataCache.map.count > 4000 { rowDataCache.map.removeAll(keepingCapacity: true) }
        rowDataCache.map[item.id] = (item.version, data)
        return data
    }
    private final class RowItemsCache { var key = "\u{0}"; var result: [RowItem] = [] }
    @State private var rowItemsCache = RowItemsCache()
    /// `filtered` envuelto en `RowItem`, cacheado por la MISMA clave que `filtered`: se
    /// reconstruye solo al cambiar el conjunto/filtros (ahí se accede a `Bookmark.id` una vez
    /// por enlace), NO por fotograma de scroll.
    private var rowItems: [RowItem] {
        let links = filtered                // asegura que `filterCache.key` está al día
        let key = filterCache.key
        if rowItemsCache.key == key { return rowItemsCache.result }
        let items = links.map(RowItem.init(link:))
        rowItemsCache.key = key
        rowItemsCache.result = items
        return items
    }

    /// Huella de TODO lo que afecta a `filtered`: revisión del modelo, recuento, texto,
    /// orden, filtros, modo semántico y alcance. Es O(1). Antes buscaba el `updatedAt`
    /// máximo recorriendo `sourceLinks` en CADA acceso; cabecera, contenido, atajos y barra
    /// de lote podían provocar varias pasadas completas dentro de un único render.
    private var filterCacheKey: String {
        let scopeKey = collectionScope.map { $0.map(\.uuidString).sorted().joined(separator: ",") } ?? "-"
        return [
            "\(libraryRevision)",
            searchText, searchFile?.path ?? "", sortRaw,
            selectedType?.rawValue ?? "-", selectedPlatform?.rawValue ?? "-",
            selectedCategoryID?.uuidString ?? "-", smartFilter?.rawValue ?? "-",
            semanticMode ? "sem" : "lex", "\(semanticReadyToken)", language,
            readingQueueMode ? "q" : "-", scopeKey,
        ].joined(separator: "|")
    }

    @MainActor
    private var filtered: [Bookmark] {
        let key = filterCacheKey
        if filterCache.key == key { return filterCache.result }
        let result = computeFiltered()
        filterCache.key = key
        filterCache.result = result
        return result
    }

    @MainActor
    private func computeFiltered() -> [Bookmark] {
        // Operadores de búsqueda (title:/tag:/type:/domain:/created:, # y exclusión -):
        // el texto LIBRE va al almacén (full-text/semántica) y los operadores se aplican
        // como post-filtro en la capa de app (sin tocar el paquete read-only).
        let query = SearchQuery.parse(searchText)
        var filter = baseFilter
        filter.searchText = query.freeText
        // Componer los filtros de la barra SOBRE el filtro base de la sección.
        if let type = selectedType { filter.contentType = type }
        if let platform = selectedPlatform { filter.platform = platform }
        if let categoryID = selectedCategoryID { filter.categoryID = categoryID }
        smartFilter?.apply(to: &filter)

        let meaning = query.freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if searchFile != nil || (semanticMode && !meaning.isEmpty) {
            _ = semanticReadyToken
            let base = semanticCandidates()
            let matches = multimodalInputKey == semanticInputKey ? multimodalMatches : []
            return MultimodalSearchService.shared.hybrid(base, query: searchText, matches: matches,
                                                        includeLiteral: searchFile == nil)
        }

        // LÉXICO: el filtrado de TEXTO lo hace la capa de app (`lexicalMatches` mira título,
        // URL, descripción, resumen, notas, COLECCIÓN y ETIQUETAS), no el almacén —que no
        // busca en etiquetas—. Así «3D assets» encuentra un enlace cuya única coincidencia es
        // la etiqueta «3d assets». El paquete aplica solo los filtros ESTRUCTURALES.
        var lexFilter = filter
        lexFilter.searchText = ""
        let result = applyScope(filteredLinks(sourceLinks, using: lexFilter, sort: sort))
            .filter { query.lexicalMatches($0) }
        // Cola de lectura: oculta solo lo «leído» (incluye «pendiente» y «leyendo»).
        guard readingQueueMode else { return result }
        return result.filter { $0.readingStatus != .done }
    }

    /// Post-filtros que NO dependen del texto de búsqueda y deben aplicarse tanto en
    /// modo léxico como semántico: alcance por colección (la colección elegida + sus
    /// descendientes) y cola de lectura. Centralizado para no divergir entre ramas.
    private func applyScope(_ links: [Bookmark]) -> [Bookmark] {
        var result = links
        if let scope = collectionScope {
            result = result.filter { link in
                guard let id = link.category?.id else { return false }
                return scope.contains(id)
            }
        }
        return result
    }

    // MARK: - Búsqueda por significado (semántica)

    private var semanticAvailable: Bool { true }
    private var semanticInputKey: String { searchText + "\u{0}" + (searchFile?.path ?? "") }

    /// Los filtros se aplican antes del ranking del servidor, también en consultas por archivo.
    private func semanticCandidates() -> [Bookmark] {
        let query = SearchQuery.parse(searchText)
        var filter = baseFilter
        filter.searchText = ""
        if let type = selectedType { filter.contentType = type }
        if let platform = selectedPlatform { filter.platform = platform }
        if let categoryID = selectedCategoryID { filter.categoryID = categoryID }
        smartFilter?.apply(to: &filter)
        return applyScope(filteredLinks(sourceLinks, using: filter, sort: sort)).filter {
            query.matches($0) && (!readingQueueMode || $0.readingStatus != .done)
        }
    }

    private var semanticRequestKey: String {
        let scope = collectionScope.map { $0.map(\.uuidString).sorted().joined(separator: ",") } ?? "*"
        return [searchText, searchFile?.path ?? "", semanticMode ? "sem" : "lex",
                selectedType?.rawValue ?? "", selectedPlatform?.rawValue ?? "",
                selectedCategoryID?.uuidString ?? "", smartFilter?.rawValue ?? "",
                scope, readingQueueMode ? "q" : "", "\(libraryRevision)",
                "\(MultimodalSearchService.shared.revision)"].joined(separator: "|")
    }

    private func warmSemanticCache() {
        multimodalTask?.cancel()
        warmGeneration &+= 1
        let generation = warmGeneration
        let text = searchText
        let inputKey = semanticInputKey
        let file = searchFile
        let query = SearchQuery.parse(text).freeText
        searchError = nil
        guard semanticMode || file != nil, query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 || file != nil else {
            multimodalMatches = []
            multimodalInputKey = inputKey
            semanticReadyToken &+= 1
            warmingSemantic = false
            return
        }
        // Mantener la última respuesta mientras se actualiza el índice. Vaciarla aquí
        // alternaba resultados semánticos→léxicos→semánticos sin tocar la consulta y
        // agrandaba/encogía el indicador de scroll. El reemplazo es atómico al terminar.
        let allowed = semanticCandidates().map(\.id)
        warmingSemantic = true
        multimodalTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                let matches = try await MultimodalSearchService.shared.search(query, file: file, allowedIDs: allowed)
                try Task.checkCancellation()
                guard generation == warmGeneration else { return }
                multimodalMatches = matches
                multimodalInputKey = inputKey
            } catch {
                guard generation == warmGeneration, !Task.isCancelled else { return }
                searchError = error.localizedDescription
            }
            guard generation == warmGeneration else { return }
            warmingSemantic = false
            semanticReadyToken &+= 1
        }
    }

    // MARK: - Búsquedas guardadas

    /// Búsquedas guardadas decodificadas del JSON persistido.
    private var savedSearches: [SavedSearch] { SavedSearchStore.decode(savedSearchesJSON) }

    /// Búsquedas guardadas que se MUESTRAN como chip: se ocultan las redundantes con un
    /// filtro rápido ya disponible en el menú (favoritos / sin leer / una sola
    /// categoría), para no saturar la cabecera con chips equivalentes.
    private var visibleSavedSearches: [SavedSearch] {
        savedSearches.filter { !isRedundantQuickFilter($0) }
    }

    /// `true` si la búsqueda guardada reproduce EXACTAMENTE un filtro rápido (solo
    /// favoritos, solo sin leer, o solo una categoría existente; sin texto ni otros
    /// filtros), para no ofrecer un chip duplicado. Réplica de la regla del iPhone.
    private func isRedundantQuickFilter(_ s: SavedSearch) -> Bool {
        let noText = s.searchText.trimmingCharacters(in: .whitespaces).isEmpty
        guard noText else { return false }
        // Solo una categoría (= su filtro de categoría).
        if let catID = s.categoryID, !s.onlyFavorites, s.smartFilter == nil,
           s.platform == nil, s.contentType == nil,
           categories.contains(where: { $0.id == catID }) {
            return true
        }
        // Solo favoritos / solo sin leer (= sus filtros integrados).
        guard s.platform == nil, s.contentType == nil, s.categoryID == nil else { return false }
        let onlyFav = s.onlyFavorites && s.smartFilter == nil
        let onlyUnread = !s.onlyFavorites && s.smartFilter == SmartFilter.unread.rawValue
        return onlyFav || onlyUnread
    }

    /// `true` si hay algo que merezca guardarse como búsqueda (texto y/o filtros).
    private var canSaveSearch: Bool { !trimmedQuery.isEmpty || hasActiveFilters }

    /// Guarda la búsqueda actual (texto + filtros) como un nuevo preset. Evita guardar
    /// duplicados por nombre o presets redundantes con un filtro rápido.
    private func saveCurrentSearch() {
        let search = SavedSearch(
            name: autoSearchName(), searchText: searchText,
            smartFilter: smartFilter?.rawValue, platform: selectedPlatform?.rawValue,
            contentType: selectedType?.rawValue, categoryID: selectedCategoryID,
            onlyFavorites: false, sort: sort.rawValue)
        guard !isRedundantQuickFilter(search) else { return }
        var list = savedSearches
        guard !list.contains(where: { $0.name == search.name }) else { return }
        list.append(search)
        savedSearchesJSON = SavedSearchStore.encode(list)
    }

    /// Reaplica una búsqueda guardada: restaura texto y todos los filtros de la barra.
    /// `onlyFavorites` se mapea al filtro inteligente equivalente porque esta vista no
    /// tiene un `onlyFavorites` propio (vive en `LinkFilter`/sección).
    /// Aplica la búsqueda guardada inicial (Smart Folder) una sola vez al abrir la sección.
    private func applyInitialSearchIfNeeded() {
        guard let search = initialSavedSearch, !appliedInitialSearch else { return }
        appliedInitialSearch = true
        applySavedSearch(search)
    }

    private func applySavedSearch(_ search: SavedSearch) {
        withAnimation(.snappy) {
            searchText = search.searchText
            smartFilter = search.smartFilter.flatMap(SmartFilter.init(rawValue:))
            selectedPlatform = search.platform.flatMap(Platform.init(rawValue:))
            selectedType = search.contentType.flatMap(ContentType.init(rawValue:))
            selectedCategoryID = search.categoryID
            sortRaw = (LinkSort(rawValue: search.sort) ?? .recent).rawValue
        }
    }

    /// Elimina una búsqueda guardada (desde su menú contextual en el chip).
    private func deleteSavedSearch(_ search: SavedSearch) {
        savedSearchesJSON = SavedSearchStore.encode(savedSearches.filter { $0.id != search.id })
    }

    /// Nombre legible a partir de los filtros activos (paridad con el iPhone).
    private func autoSearchName() -> String {
        var parts: [String] = []
        let q = trimmedQuery
        if !q.isEmpty { parts.append("«\(q)»") }
        if let f = smartFilter { parts.append(f.title) }
        if let p = selectedPlatform { parts.append(p.displayName) }
        if let id = selectedCategoryID, let c = categories.first(where: { $0.id == id }) {
            parts.append(c.name)
        }
        if let t = selectedType { parts.append(t.displayName) }
        return parts.isEmpty ? "Búsqueda" : parts.joined(separator: " · ")
    }

    /// `true` si hay algún filtro de la barra activo (sin contar el filtro base).
    private var hasActiveFilters: Bool { activeFilterCount > 0 }

    var body: some View {
        content
            // La cabecera vive en el safe-area del propio scroll: la primera fila nace
            // debajo, pero durante el desplazamiento continúa detrás de la lente y el
            // sistema puede refractarla con el borde suave superior.
            .safeAreaInset(edge: .top, spacing: 0) {
                libraryHeaderInset
            }
        // Publica la selección por Environment para que la preview de hover se OMITA en el/los
        // enlace(s) seleccionados (ya visibles completos en el panel de detalle). Lo leen tanto
        // las filas (Lista) como las baldosas (Cuadrícula/Moodboard) sin pasarlo en cada llamada.
        .environment(\.selectedLinkIDs, selection)
        // Barra flotante de acciones en lote: aparece cuando hay 2+ seleccionados.
        // En `safeAreaInset(.bottom)` para que no tape la última fila de la lista.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selection.count >= 2 { bulkActionBar }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86),
                   value: selection.count >= 2)
        .confirmationDialog("¿Mover los seleccionados a la papelera?",
                            isPresented: $showBulkDeleteConfirm, titleVisibility: .visible) {
            Button("Mover a la papelera (\(selection.count))", role: .destructive) { bulkTrash() }
            Button("Cancelar", role: .cancel) {}
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
        // Hojas buscables de lote: se abren desde la entrada «Buscar…» de los menús
        // «Mover a colección» / «Etiquetar». La selección se captura al abrir la hoja.
        .sheet(isPresented: $showCollectionPicker) {
            BulkCollectionPickerSheet(collections: categories, count: selection.count) { category in
                bulkMove(to: category)
            }
            .themedSheet(palette)
        }
        .sheet(isPresented: $showFilterCollectionPicker) {
            BulkCollectionPickerSheet(
                collections: categories,
                title: "Filtrar por colección",
                noneLabel: "Todas las colecciones"
            ) { category in
                selectedCategoryID = category?.id
            }
            .themedSheet(palette)
        }
        .sheet(isPresented: $showTagPicker) {
            BulkTagPickerSheet(tags: tags, count: selection.count) { tag in
                bulkTag(tag)
            }
            .themedSheet(palette)
        }
        // Selectores BUSCABLES para UN enlace (desde el menú contextual). Reutilizan las mismas
        // hojas que el lote (List perezosa) en vez de listar miles de etiquetas inline en el menú,
        // lo que construía el menú eager con faults de SwiftData y CONGELABA la app. Extraído a un
        // modifier para no inflar el type-check de este cuerpo (ya grande).
        .modifier(ContextLinkPickers())
        // Título VACÍO a propósito: la cabecera propia de la colección (`collectionHeader`, la del
        // DESIGN.md) ya muestra el nombre y el contador. Antes `navigationTitle(title)` pintaba el
        // MISMO título en la barra de la ventana → se veía DUPLICADO («Todos / Todos»). Las vistas
        // de herramienta (Sesiones, Reglas…) sí conservan su `navigationTitle` (es su único título).
        .navigationTitle("")
        // Vista rápida con la BARRA ESPACIADORA (estilo Finder): con un enlace
        // seleccionado, espacio lo previsualiza. `onKeyPress` respeta el foco, así que NO
        // interfiere con el campo de búsqueda (el TextField consume el espacio al escribir).
        .onKeyPress(.space) {
            guard selection.count == 1 else { return .ignored }
            NotificationCenter.default.post(name: .stacklumeQuickLookSelected, object: nil)
            return .handled
        }
        // RETURN abre el enlace seleccionado en el navegador (lo natural; espacio lo
        // previsualiza). `onKeyPress` respeta el foco → no interfiere con la búsqueda (donde
        // Return envía la consulta). Solo con UN enlace seleccionado, para no abrir muchas
        // pestañas sin querer; en lote está la acción «Abrir» de la barra.
        .onKeyPress(.return) {
            guard selection.count == 1, let link = selectedLinks.first,
                  let url = StacklumeAutomationPolicy.openableStoredURL(link.url)
            else { return .ignored }
            openURL(url)
            return .handled
        }
        // ⌘A selecciona TODO (los modos List ya lo hacen nativo; esto cubre Cuadrícula/
        // Moodboard). Respeta el foco → no pisa el ⌘A de seleccionar texto en la búsqueda.
        .onKeyPress(keys: ["a"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            selection = Set(filtered.map(\.id))
            return .handled
        }
        // Flechas ↑/↓ mueven la selección (lo que daba el `List` nativo) y desplazan hasta ella
        // en la lista perezosa. `onKeyPress` respeta el foco → en la búsqueda mueven el cursor.
        .onKeyPress(.upArrow) { moveSelection(by: -1) }
        .onKeyPress(.downArrow) { moveSelection(by: 1) }
        .searchable(text: $searchText, placement: .toolbar,
                    prompt: semanticMode ? "Buscar por palabras, significado o color…" : "Buscar enlaces")
        // Si el modo semántico ya estaba activo (persistido), precalienta los vectores
        // al aparecer y al cambiar el texto, para que el re-ranking sea instantáneo.
        .task(id: semanticRequestKey) { warmSemanticCache() }
        .onDisappear { multimodalTask?.cancel(); warmGeneration &+= 1 }
        .toolbar {
            ToolbarItem {
                Button { showSearchFilePicker = true } label: {
                    Label("Buscar con un archivo", systemImage: "doc.viewfinder")
                }
                .themedHelp("Encuentra contenido parecido usando una imagen, PDF, audio o vídeo")
            }
        }
        .fileImporter(isPresented: $showSearchFilePicker, allowedContentTypes: [.image, .pdf, .audio, .movie, .plainText]) { result in
            if case .success(let url) = result { searchText = ""; searchFile = url }
        }
        // Un guardado real invalida los derivados. Selección, hover, resize y animaciones
        // no cambian la revisión y reutilizan las cachés existentes en el camino caliente.
        .onReceive(NotificationCenter.default.publisher(for: .stacklumeModelDidSave)) { _ in
            libraryRevision &+= 1
        }
        // Menú «Visualización» (⌃⌘1–4) o la IA: aplican el modo a ESTA sección (su
        // preferencia por colección), no solo a la clave global por defecto.
        .onReceive(NotificationCenter.default.publisher(for: .stacklumeSetViewMode)) { note in
            if let raw = note.object as? String, let m = LibraryViewMode(rawValue: raw) {
                updatePref { $0.mode = m.rawValue }
            }
        }
        // Enriquecido periódico de metadatos de red en segundo plano (sin IA), igual
        // que el iPhone: enriquece los enlaces que aún no tienen metadatos. Coordinado
        // para no lanzarse por duplicado al navegar entre listas.
        .task {
            applyInitialSearchIfNeeded()
            await EnrichCoordinator.runIfNeeded(in: context)
        }
        .toolbar {
            if allowsCreate {
                ToolbarItem(placement: .primaryAction) {
                    Button("Nuevo enlace", systemImage: "plus") { actions.newLink() }
                        .themedHelp("Nuevo enlace (⌘N)")
                }
            }
        }
    }

    /// Contenido scrollable (debajo de la cabecera fija): el modo de vista elegido.
    /// Al alternar de modo, el contenido entra/sale con una transición suave de
    /// opacidad + escala muy sutil (Reduce Motion: solo opacidad). El `id(mode)`
    /// hace que SwiftUI trate cada modo como una vista distinta y aplique la
    /// transición; `animation(value: mode)` la dispara con curva premium corta.
    @ViewBuilder
    private var content: some View {
        Group {
            if filtered.isEmpty {
                emptyState
            } else {
                switch mode {
                case .list: listView
                case .grid:
                    if grouping == .none {
                        BentoGridView(links: filtered, selection: $selection, coverScale: coverScale)
                    } else {
                        groupedGridView
                    }
                case .moodboard: moodboardView
                case .headlines: headlinesView
                }
            }
        }
        // El `switch mode` del @ViewBuilder ya intercambia la vista al cambiar de modo
        // (identidad estructural). NO se usa `.id(mode)` NI se anima el cambio: forzar
        // identidad o animar el swap del contenido dejaba tarjetas FANTASMA del modo
        // anterior flotando sobre el nuevo (Cuadrícula encima del Moodboard). Swap
        // directo e instantáneo = sin ghosts ni solapamientos.
    }

    // MARK: - Cabecera de colección (DESIGN.md §4)

    /// Conjunto flotante de cabecera. Los márgenes desacoplan la lente de los divisores
    /// del `NavigationSplitView`, evitando el aspecto de panel rectangular a sangre.
    private var libraryHeaderInset: some View {
        VStack(spacing: 6) {
            collectionHeader
            if let file = searchFile {
                HStack {
                    Label(file.lastPathComponent, systemImage: "doc.viewfinder").stacklumeLineLimit(1)
                    Spacer()
                    Button("Quitar") { searchFile = nil; multimodalMatches = []; semanticReadyToken &+= 1 }
                }
                .stacklumeFont(.caption).foregroundStyle(palette.textPrimary)
                .padding(DesignSystem.Spacing.xs)
            }

            // La lente conserva su espacio al escribir y al recibir resultados:
            // el estado cambia dentro de ella sin desplazar el contenido.
            if semanticAvailable {
                let semanticShape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                SemanticSearchToggle(
                    isOn: $semanticMode,
                    warming: warmingSemantic,
                    statusMessage: searchError,
                    onActivate: warmSemanticCache
                )
                .background {
                    StacklumeGlassBackdrop(
                        shape: semanticShape,
                        tint: palette.accent,
                        tintOpacity: 0.02,
                        surfaceOpacity: 0.15,
                        borderOpacity: 0.11
                    )
                }
                .clipShape(semanticShape)
                .shadow(color: .black.opacity(0.20), radius: 10, y: 4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, DesignSystem.Spacing.xs)
        .padding(.bottom, 6)
        .zIndex(2)
    }

    /// Cabecera flotante de la columna central: portada editorial opcional + lente
    /// funcional Liquid Glass con identidad, contexto, vista, orden y filtros.
    private var collectionHeader: some View {
        let panelShape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            // Una portada manual conserva su valor editorial. Sin ella, la identidad
            // vive íntegramente en la banda de cristal: nunca se inventa un banner.
            if let coverImageData, let image = PlatformImage(data: coverImageData) {
                coverBanner(image)
            }
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                titleRow
                metadataRow
                savedSearchesRow
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.top, coverImageData == nil ? 14 : DesignSystem.Spacing.sm)
            .padding(.bottom, DesignSystem.Spacing.sm)
        }
        .background {
            StacklumeGlassBackdrop(
                shape: panelShape,
                tint: headerIdentityTint,
                tintOpacity: 0.035,
                surfaceOpacity: 0.14,
                borderOpacity: 0.14
            )
        }
        .clipShape(panelShape)
        .shadow(color: .black.opacity(0.30), radius: 18, y: 8)
    }

    // MARK: - Búsquedas guardadas (chips de cabecera)

    /// Subfila de búsquedas guardadas: chips de los presets guardados (clic = aplicar;
    /// clic derecho = eliminar) y, a la derecha, el botón «Guardar búsqueda» cuando hay
    /// algo que guardar (texto y/o filtros). Solo se muestra si hay chips o algo que
    /// guardar, para no ocupar espacio cuando no aplica. Chips sutiles (DESIGN.md): nada
    /// de cristal en la fila; el chip es una cápsula translúcida discreta.
    @ViewBuilder
    private var savedSearchesRow: some View {
        if !visibleSavedSearches.isEmpty {
            HStack(spacing: DesignSystem.Spacing.xs) {
                if !visibleSavedSearches.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(visibleSavedSearches) { search in
                                LibrarySearchChip(label: search.name, systemImage: "bookmark.fill") {
                                    applySavedSearch(search)
                                }
                                .contextMenu {
                                    Button("Eliminar búsqueda", systemImage: "trash", role: .destructive) {
                                        deleteSavedSearch(search)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
                Spacer(minLength: 0)
                if canSaveSearch {
                    Button("Guardar búsqueda", systemImage: "bookmark") { saveCurrentSearch() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(palette.textPrimary)
                        .themedHelp("Guardar la búsqueda y los filtros actuales")
                        .fixedSize()
                }
            }
        }
    }

    /// Banner de portada: franja editorial corta con velo neutro para mantener la
    /// legibilidad y dar paso a la banda funcional de cristal situada debajo.
    /// Patrón caja fija + imagen overlay: la imagen nunca puede ensanchar el banner
    /// con portadas de relación de aspecto inesperada.
    private func coverBanner(_ image: PlatformImage) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 108)
            .overlay {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
            }
            .clipped()
            // Velo oscuro neutro (no tintado de marca) para legibilidad del título,
            // que respeta la imagen y mantiene la estética premium con cualquier color.
            .overlay {
                LinearGradient(
                    colors: [.clear, palette.background.opacity(0.55), palette.background.opacity(0.92)],
                    startPoint: .top, endPoint: .bottom)
            }
    }

    private var headerIdentityTint: Color {
        headerTintHex.map(Color.init(hex:)) ?? palette.accent
    }

    /// Dominios ÚNICOS (host) de los enlaces de la sección, para el banner resumen.
    private var headerDomains: [String] {
        var seen = Set<String>(); var out: [String] = []
        for link in filtered {
            let host = link.url.urlHost
            if !host.isEmpty, seen.insert(host).inserted { out.append(host) }
            // Ocho se renderizan; el decimotercero solo permite comunicar «12+»
            // sin recorrer una biblioteca enorme en cada recomposición.
            if out.count >= 13 { break }
        }
        return out
    }

    private var headerSiteSummary: String {
        if headerDomains.count > 12 { return "12+ sitios" }
        return "\(headerDomains.count) sitio\(headerDomains.count == 1 ? "" : "s")"
    }

    /// Grupo principal de identidad y controles. En columnas estrechas el `Layout`
    /// baja los controles a una segunda fila; nunca comprime títulos o botones en
    /// columnas de caracteres.
    private var titleRow: some View {
        CollectionHeaderAdaptiveLayout(spacing: DesignSystem.Spacing.xs) {
            headerIdentity
            headerPrimaryControls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Placa de categoría, título y resumen textual indivisible. El resumen se compone
    /// en un solo `Text` para que el sistema lo trunque como línea, no palabra a palabra.
    private var headerIdentity: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            let badgeShape = RoundedRectangle(cornerRadius: 11, style: .continuous)
            Image(systemName: icon)
                .scaledFont(17, weight: .semibold, scalesWithText: false)
                .foregroundStyle(headerIdentityTint)
                .frame(width: 38, height: 38)
                .background(palette.surface.opacity(0.72), in: badgeShape)
                .overlay {
                    badgeShape.strokeBorder(headerIdentityTint.opacity(0.38), lineWidth: 0.75)
                }
                .shadow(color: .black.opacity(0.20), radius: 5, y: 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .stacklumeFont(.title2.weight(.bold))
                    .foregroundStyle(palette.textPrimary)
                    .stacklumeLineLimit(1)
                    .truncationMode(.tail)

                Text(headerSummary)
                    .stacklumeFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(palette.textSecondary)
                    .stacklumeLineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .layoutPriority(1)
        }
    }

    private var headerSummary: String {
        var parts = ["\(filtered.count) enlace\(filtered.count == 1 ? "" : "s")"]
        if !headerDomains.isEmpty { parts.append(headerSiteSummary) }
        if let headerSubtitle {
            let subtitle = headerSubtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !subtitle.isEmpty { parts.append(subtitle) }
        }
        return parts.joined(separator: " · ")
    }

    /// Acción contextual y selector de vista. `ViewThatFits` conserva la etiqueta
    /// completa siempre que quepa y cae a icono accesible únicamente en el mínimo
    /// extremo de la columna.
    private var headerPrimaryControls: some View {
        ViewThatFits(in: .horizontal) {
            headerPrimaryControls(showActionTitle: true)
                .fixedSize(horizontal: true, vertical: false)
            headerPrimaryControls(showActionTitle: false)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func headerPrimaryControls(showActionTitle: Bool) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            if let headerAction {
                Button(action: headerAction.action) {
                    if showActionTitle {
                        Label(headerAction.title, systemImage: headerAction.systemImage)
                            .fixedSize(horizontal: true, vertical: false)
                    } else {
                        Image(systemName: headerAction.systemImage)
                            .frame(width: 18, height: 16)
                    }
                }
                    .stacklumeButton(compact: true)
                    .controlSize(.small)
                    .themedHelp(headerAction.title)
                    .accessibilityLabel(headerAction.title)
            }
            viewModeSelector
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Selector de vista premium: 4 iconos en un control de cristal; el modo activo
    /// resaltado en `palette.accent`. Persiste en `viewModeRaw`. El realce dorado es
    /// un único «pill» que se desliza entre iconos vía `matchedGeometryEffect` (con
    /// Reduce Motion no se anima el desplazamiento, solo aparece/desaparece).
    private var viewModeSelector: some View {
        HStack(spacing: 6) {
            ForEach(LibraryViewMode.allCases) { m in
                Button {
                    selectViewMode(m)
                } label: {
                    Image(systemName: m.icon)
                        .scaledFont(13, weight: .semibold, scalesWithText: false)
                        .frame(width: 30, height: 26)
                        .foregroundStyle(mode == m ? palette.accent : palette.textSecondary)
                        .background {
                            // Realce sutil y separado: un solo «pill» compartido que se
                            // desliza entre iconos (matchedGeometryEffect). Opacidad baja
                            // para que sea discreto, no un bloque dorado.
                            if mode == m {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(palette.accent.opacity(0.12))
                                    .matchedGeometryEffect(id: "viewModePill", in: viewModeGlass,
                                                           isSource: !reduceMotion)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.pressable)
                .themedHelp(m.label)
                .accessibilityLabel(m.label)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(palette.background.opacity(0.24), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.textPrimary.opacity(0.10), lineWidth: 0.5)
        }
    }

    /// Cambia el modo de vista de forma INSTANTÁNEA (sin `withAnimation`): animar el
    /// cambio de `mode` animaba también el swap del contenido y dejaba tarjetas
    /// fantasma del modo anterior flotando sobre el nuevo. El cambio directo es limpio.
    private func selectViewMode(_ m: LibraryViewMode) {
        guard mode != m else { return }
        updatePref { $0.mode = m.rawValue }
    }

    /// Enlace del deslizador de tamaño de portada al borrador en vivo.
    private var coverScaleBinding: Binding<Double> {
        Binding(get: { coverScaleDraft ?? currentPref.coverScale },
                set: { coverScaleDraft = $0 })
    }

    /// Control de tamaño de portada (el «amplificador» de Raindrop): solo en los modos
    /// con portada (Cuadrícula/Moodboard). Abre un popover con un deslizador que
    /// redimensiona en vivo y persiste al soltar.
    @ViewBuilder
    private var coverSizeControl: some View {
        if mode == .grid || mode == .moodboard {
            Button {
                showingCoverSize = true
            } label: {
                Label("Tamaño de portada", systemImage: "rectangle.expand.vertical")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .foregroundStyle(palette.textSecondary)
            .themedHelp("Tamaño de las portadas")
            .accessibilityLabel("Tamaño de las portadas")
            .popover(isPresented: $showingCoverSize, arrowEdge: .bottom) {
                coverSizePopover
            }
        }
    }

    /// Contenido del popover de tamaño de portada.
    private var coverSizePopover: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Tamaño de portada")
                .stacklumeFont(.subheadline.weight(.semibold))
                .foregroundStyle(palette.textPrimary)
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "photo").font(.caption2).foregroundStyle(palette.textSecondary)
                Slider(value: coverScaleBinding, in: 0.7...1.6, step: 0.05) { editing in
                    if !editing, let v = coverScaleDraft {
                        updatePref { $0.coverScale = v }
                        coverScaleDraft = nil
                    }
                }
                .frame(width: 160)
                Image(systemName: "photo").font(.title3).foregroundStyle(palette.textSecondary)
            }
            Button("Restablecer") {
                coverScaleDraft = nil
                updatePref { $0.coverScale = 1.0 }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(palette.textPrimary)
        }
        .padding(DesignSystem.Spacing.md)
        .frame(width: 240)
    }

    /// Segunda banda de la cabecera: muestra una muestra compacta de los sitios a la
    /// izquierda y agrupa las herramientas de visualización a la derecha. Los favicons
    /// son contexto visual subordinado; el resumen textual ya vive junto al título.
    private var metadataRow: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            if !headerDomains.isEmpty {
                HStack(spacing: -5) {
                    ForEach(headerDomains.prefix(3), id: \.self) { domain in
                        SecureRemoteImage(
                            candidates: PreviewImage.favicon(
                                for: "https://\(domain)",
                                size: 64
                            ).map { Optional($0) }
                        ) {
                            Image(systemName: "globe")
                                .font(.caption2)
                                .foregroundStyle(palette.textSecondary)
                        }
                        .frame(width: 23, height: 23)
                        .background(palette.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(palette.background.opacity(0.9), lineWidth: 1.5)
                        }
                        .shadow(color: .black.opacity(0.20), radius: 2, y: 1)
                    }
                }
                .padding(.leading, 2)
                .accessibilityHidden(true)

                Text(headerDomains.prefix(3).joined(separator: " · "))
                    .stacklumeFont(.caption2)
                    .foregroundStyle(palette.textSecondary.opacity(0.82))
                    .stacklumeLineLimit(1)
            }

            Spacer(minLength: DesignSystem.Spacing.sm)

            HStack(spacing: DesignSystem.Spacing.xs) {
                coverSizeControl
                sortMenu
                if groupingApplies { groupMenu }
                filterMenu
                actionsMenu
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                palette.background.opacity(0.24),
                in: Capsule(style: .continuous)
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(palette.textPrimary.opacity(0.09), lineWidth: 0.5)
            }
        }
        .frame(minHeight: 30)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(filtered.count) enlace\(filtered.count == 1 ? "" : "s") en \(headerSiteSummary)"
        )
    }

    /// Menú «Agrupar por» (paridad con Raindrop). Solo en Lista/Titulares. El icono se
    /// rellena cuando hay una agrupación activa (pista visual de estado, como el filtro).
    private var groupMenu: some View {
        Menu {
            Picker("Agrupar por", selection: groupingBinding) {
                ForEach(LibraryGrouping.allCases) { g in
                    Label(g.label, systemImage: g.icon).tag(g)
                }
            }
        } label: {
            Label("Agrupar", systemImage: grouping == .none ? "square.stack.3d.up" : "square.stack.3d.up.fill")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(grouping == .none ? palette.textSecondary : palette.accent)
        .themedHelp("Agrupar los enlaces por colección, dominio, tipo o fecha")
        .accessibilityLabel("Agrupar enlaces")
    }

    /// Menú de acciones sobre la lista actual: seleccionar todo, abrir todos, copiar.
    private var actionsMenu: some View {
        Menu {
            Button("Seleccionar todo", systemImage: "checkmark.circle") {
                selection = Set(filtered.map(\.id))
            }
            Button("Invertir selección", systemImage: "circle.lefthalf.filled") {
                selection = Set(filtered.map(\.id)).subtracting(selection)
            }
            if !selection.isEmpty {
                Button("Deseleccionar", systemImage: "xmark.circle") { selection.removeAll() }
            }
            Divider()
            Button("Abrir todos los enlaces", systemImage: "safari") { openAllFiltered() }
            Button("Copiar enlaces", systemImage: "doc.on.doc") { copyAllFiltered() }
            Divider()
            Button("Guardar búsqueda", systemImage: "bookmark") { saveCurrentSearch() }
                .disabled(!canSaveSearch)
        } label: {
            Label("Acciones", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(palette.textSecondary)
        .themedHelp("Acciones de la lista")
        .accessibilityLabel("Acciones de la lista")
        .disabled(filtered.isEmpty)
    }

    /// Abre en el navegador todos los enlaces de la vista actual (confirma si son >10).
    private func openAllFiltered() {
        let urls = filtered.compactMap { StacklumeAutomationPolicy.openableStoredURL($0.url) }
        guard !urls.isEmpty else { return }
        if urls.count <= 10 {
            urls.forEach { openURL($0) }
        } else {
            openAllRequest = OpenAllRequest(name: title, urls: urls)
        }
    }

    /// Copia al portapapeles las URLs de la vista actual (una por línea).
    private func copyAllFiltered() {
        let urls = filtered.map(\.url)
        guard !urls.isEmpty else { return }
        NSPasteboard.copyString(urls.joined(separator: "\n"))
    }

    /// Abre en el navegador los enlaces SELECCIONADOS (confirma si son >10).
    private func bulkOpen() {
        let urls = selectedLinks.compactMap { StacklumeAutomationPolicy.openableStoredURL($0.url) }
        guard !urls.isEmpty else { return }
        if urls.count <= 10 {
            urls.forEach { openURL($0) }
        } else {
            openAllRequest = OpenAllRequest(name: "\(urls.count) seleccionados", urls: urls)
        }
    }

    /// Copia al portapapeles las URLs SELECCIONADAS (una por línea).
    private func bulkCopy() {
        let urls = selectedLinks.map(\.url)
        guard !urls.isEmpty else { return }
        NSPasteboard.copyString(urls.joined(separator: "\n"))
    }

    /// Exporta los enlaces SELECCIONADOS a HTML de marcadores (panel del sistema).
    private func bulkExport() {
        let links = selectedLinks
        guard !links.isEmpty else { return }
        CollectionExporter.exportHTML(links, suggestedName: "\(links.count) enlaces")
    }

    /// Mejora con la IA local los enlaces SELECCIONADOS (título, descripción, colección y
    /// etiquetas), uno a uno y con progreso visible. Enriquecido por IA local dirigido a
    /// una selección concreta: algo que Raindrop no ofrece.
    private func bulkEnrichAI() {
        guard aiEnrichProgress == nil else { return }
        let targets = selectedLinks
        guard !targets.isEmpty else { return }
        let lang = language
        aiEnrichProgress = (0, targets.count)
        Task { @MainActor in
            var done = 0
            for link in targets {
                if Task.isCancelled { break }
                if link.modelContext != nil {
                    _ = await AIBatchEnricher.enrichOne(
                        link, in: context, provider: "liquid", language: lang, force: true)
                    // Rellena la portada que falte (og:image / `<img>` hero / captura del
                    // hero renderizado). Punto único ([[CoverEnsurer]]); no usa el LLM, así
                    // que funciona incluso sin modelo. Seleccionar todo + «Mejorar IA»
                    // rellena de una vez todas las imágenes que faltan en la biblioteca.
                    await CoverEnsurer.ensure(for: link, in: context)
                }
                done += 1
                aiEnrichProgress = (done, targets.count)
            }
            aiEnrichProgress = nil
        }
    }

    /// Menú de orden (movido aquí desde la toolbar del sistema).
    private var sortMenu: some View {
        Menu {
            Picker("Ordenar", selection: sortBinding) {
                ForEach(LinkSort.allCases) { s in
                    Label(s.displayName, systemImage: s.sfSymbol).tag(s)
                }
            }
        } label: {
            Label("Ordenar", systemImage: "arrow.up.arrow.down")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(palette.textSecondary)
        .themedHelp("Ordenar enlaces")
        .accessibilityLabel("Ordenar enlaces")
    }

    // MARK: - Estado vacío

    /// Estado vacío contextual: distingue entre biblioteca vacía, sin resultados de
    /// búsqueda y sin coincidencias de filtro (paridad con el iPhone). Cuando hay
    /// filtros activos, el icono del menú de filtros queda resaltado para deshacerlos.
    @ViewBuilder
    private var emptyState: some View {
        let hasSearch = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        if warmingSemantic {
            VStack(spacing: DesignSystem.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Buscando en tu biblioteca…").foregroundStyle(palette.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if hasSearch {
            EmptyStateView(icon: "magnifyingglass", title: title,
                           message: "Sin resultados para «\(searchText)».")
        } else if hasActiveFilters {
            EmptyStateView(icon: "line.3.horizontal.decrease.circle", title: title,
                           message: "No hay enlaces que coincidan con el filtro.")
        } else {
            EmptyStateView(
                icon: icon, title: title, message: emptyMessage,
                actionTitle: allowsCreate ? "Añadir enlace" : nil,
                action: allowsCreate ? { actions.newLink() } : nil
            )
            // Primer uso: tarjeta de importación de navegadores anclada abajo (el estado
            // vacío llena todo el alto; un overlay evita que se empuje fuera de vista).
            .overlay(alignment: .bottom) {
                if allowsCreate, libraryIsEmpty {
                    BrowserImportOnboarding()
                        .padding(.bottom, DesignSystem.Spacing.xl)
                }
            }
        }
    }

    /// `true` si la biblioteca no tiene ningún enlace activo (primer uso). Distinto de
    /// «esta sección está vacía»: solo es cierto si NO hay enlaces en toda la app.
    private var libraryIsEmpty: Bool {
        links.isEmpty
    }

    // MARK: - Menú de filtros

    /// Menú de filtros (paridad con el iPhone): Tipo, Plataforma, Categoría y
    /// filtros inteligentes. El icono se resalta y muestra un contador cuando hay
    /// filtros activos (detalle premium). Los filtros se COMPONEN sobre el filtro
    /// base de la sección y la búsqueda; nunca lo reemplazan.
    @ViewBuilder
    private var filterMenu: some View {
        Menu {
            Menu("Tipo") {
                Button("Todos") { selectedType = nil }
                Divider()
                ForEach(ContentType.allCases) { type in
                    Button {
                        selectedType = (selectedType == type) ? nil : type
                    } label: {
                        Label(type.displayName, systemImage: selectedType == type ? "checkmark" : "")
                    }
                }
            }
            if !availablePlatforms.isEmpty {
                Menu("Plataforma") {
                    Button("Todas") { selectedPlatform = nil }
                    Divider()
                    ForEach(availablePlatforms) { platform in
                        Button {
                            selectedPlatform = (selectedPlatform == platform) ? nil : platform
                        } label: {
                            Label(platform.displayName,
                                  systemImage: selectedPlatform == platform ? "checkmark" : platform.sfSymbol)
                        }
                    }
                }
            }
            if !categories.isEmpty {
                Menu("Categoría") {
                    Button("Todas") { selectedCategoryID = nil }
                    Divider()
                    Button("Buscar colección…", systemImage: "magnifyingglass") {
                        showFilterCollectionPicker = true
                    }
                }
            }
            Menu("Inteligentes") {
                Button("Ninguno") { smartFilter = nil }
                Divider()
                ForEach(SmartFilter.allCases) { option in
                    Button {
                        smartFilter = (smartFilter == option) ? nil : option
                    } label: {
                        Label(option.title, systemImage: smartFilter == option ? "checkmark" : option.icon)
                    }
                }
            }
            if hasActiveFilters {
                Divider()
                Button("Quitar filtros (\(activeFilterCount))", systemImage: "xmark.circle") {
                    clearFilters()
                }
            }
        } label: {
            Label("Filtrar", systemImage: hasActiveFilters
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // Resalta el control cuando hay filtros activos (detalle premium).
        .foregroundStyle(hasActiveFilters ? palette.accent : palette.textSecondary)
        .themedHelp(hasActiveFilters ? "Filtros activos: \(activeFilterCount)" : "Filtrar enlaces")
        .accessibilityLabel(hasActiveFilters ? "Filtros activos: \(activeFilterCount)" : "Filtrar enlaces")
    }

    /// Limpia todos los filtros de la barra (no toca el filtro base ni la búsqueda).
    private func clearFilters() {
        selectedType = nil
        selectedPlatform = nil
        selectedCategoryID = nil
        smartFilter = nil
    }

    /// Vista «Lista»: la `List` nativa con selección de macOS. El resaltado nativo se
    /// suprime y se sustituye por una pastilla teñida con el acento del tema (igual
    /// que el sidebar), para que la selección siga al tema y no al accent del sistema.
    // MARK: - Agrupación (Group by, paridad con Raindrop)

    /// Un grupo de la lista agrupada: título de cabecera + sus enlaces (en el orden de
    /// `sort` ya aplicado). El `id` es estable por criterio para que SwiftUI conserve la
    /// identidad de las secciones entre re-render.
    private struct LinkGroup: Identifiable {
        let id: String
        let title: String
        let links: [Bookmark]
    }

    /// Reparte los enlaces (ya filtrados y ordenados) en grupos según `grouping`,
    /// preservando el orden dentro de cada grupo. Un único grupo sin título si no hay
    /// agrupación.
    private func groupedLinks(_ links: [Bookmark]) -> [LinkGroup] {
        // Reusa la clave YA calculada de `filterCache` (sin nuevo O(n)) + el modo de agrupado.
        // Evita reagrupar en cada render cuando ni el conjunto ni el criterio han cambiado.
        let key = "\(filterCache.key)|\(grouping)"
        if groupCache.key == key { return groupCache.result }
        let result = computeGroups(links)
        groupCache.key = key
        groupCache.result = result
        return result
    }

    private func computeGroups(_ links: [Bookmark]) -> [LinkGroup] {
        switch grouping {
        case .none:
            return [LinkGroup(id: "all", title: "", links: links)]
        case .collection:
            let sinKey = "\u{0000}sin"
            var buckets: [String: [Bookmark]] = [:]
            for l in links { buckets[l.category?.name ?? sinKey, default: []].append(l) }
            var groups = buckets.keys.filter { $0 != sinKey }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .map { LinkGroup(id: "col-\($0)", title: $0, links: buckets[$0] ?? []) }
            if let u = buckets[sinKey] { groups.append(LinkGroup(id: "col-sin", title: "Sin clasificar", links: u)) }
            return groups
        case .domain:
            var buckets: [String: [Bookmark]] = [:]
            for l in links { buckets[l.url.urlHost, default: []].append(l) }
            return buckets.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .map { LinkGroup(id: "dom-\($0)", title: $0, links: buckets[$0] ?? []) }
        case .type:
            var buckets: [String: [Bookmark]] = [:]
            for l in links { buckets[l.contentType.displayName, default: []].append(l) }
            return buckets.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .map { LinkGroup(id: "type-\($0)", title: $0, links: buckets[$0] ?? []) }
        case .dateAdded:
            return dateGroups(links)
        }
    }

    /// Grupos por fecha de guardado en cubos relativos (Hoy, Ayer, Últimos 7 días, Este
    /// mes, Más antiguo), en orden temporal descendente. Solo aparecen los no vacíos.
    private func dateGroups(_ links: [Bookmark]) -> [LinkGroup] {
        let cal = Calendar.current
        let now = Date()
        var hoy: [Bookmark] = [], ayer: [Bookmark] = [], sem: [Bookmark] = [], mes: [Bookmark] = [], old: [Bookmark] = []
        for l in links {
            let d = l.createdAt
            if cal.isDateInToday(d) { hoy.append(l) }
            else if cal.isDateInYesterday(d) { ayer.append(l) }
            else if let days = cal.dateComponents([.day], from: d, to: now).day, days < 7 { sem.append(l) }
            else if cal.isDate(d, equalTo: now, toGranularity: .month) { mes.append(l) }
            else { old.append(l) }
        }
        var groups: [LinkGroup] = []
        func add(_ id: String, _ title: String, _ items: [Bookmark]) {
            if !items.isEmpty { groups.append(LinkGroup(id: id, title: title, links: items)) }
        }
        add("d-hoy", "Hoy", hoy); add("d-ayer", "Ayer", ayer); add("d-sem", "Últimos 7 días", sem)
        add("d-mes", "Este mes", mes); add("d-old", "Más antiguo", old)
        return groups
    }

    /// Cabecera de un grupo (Group by): título + contador, discreta y en navy.
    private func groupHeader(_ group: LinkGroup) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Text(group.title)
                .stacklumeFont(.caption.weight(.semibold))
                .foregroundStyle(palette.textSecondary)
            Text("\(group.links.count)")
                .stacklumeFont(.caption2)
                .monospacedDigit()
                .foregroundStyle(palette.textSecondary.opacity(0.6))
            Spacer()
        }
        .textCase(nil)
    }

    /// Cuadrícula AGRUPADA (Group by): por cada grupo, su cabecera + la rejilla de sus
    /// tarjetas. El nº de columnas se calcula UNA vez con el total (consistente entre
    /// secciones) reutilizando `BentoGridView.gridColumns`; las tarjetas y su interacción
    /// son las mismas que la cuadrícula plana (`LinkCoverCard` + `CardInteraction`).
    private var groupedGridView: some View {
        GeometryReader { geo in
            let cols = BentoGridView.gridColumns(width: Double(geo.size.width),
                                                 coverScale: coverScale, linkCount: filtered.count)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    ForEach(groupedLinks(filtered)) { group in
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                            groupHeader(group)
                            LazyVGrid(columns: cols, spacing: DesignSystem.Spacing.lg) {
                                ForEach(group.links) { link in
                                    LinkCoverCard(link: link)
                                        .modifier(CardInteraction(link: link, selection: $selection,
                                                                  collections: categories, tags: tags, projects: menuProjects))
                                        .conditionalLinkDrag(link, enabled: sort != .manual)
                                }
                            }
                        }
                    }
                }
                .padding(DesignSystem.Spacing.lg)
                .modifier(ScrollObservationModifier(session: ScrollDiagnostics.observation, surface: .library))
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .background(WindowBackground())
        }
    }

    @ViewBuilder
    private var listView: some View {
        // `List` NATIVO para el SWIPE de DOS DEDOS del trackpad (`.swipeActions`): el gesto nativo
        // de macOS, sin clic, igual que Mail/Reminders. El crash anterior NO era de `.swipeActions`
        // sino del gesto de REORDER (ya descartado) + su `.offset`, que peleaban con la animación del
        // swipe. El scroll va fluido (LinkRowView snapshot + `.equatable()` + pausa del enriquecido en
        // segundo plano). La hover preview se oculta al deslizar (el swipe de dos dedos ES un evento de
        // scroll → `UserActivityMonitor` postea `.stacklumeUserScrolled` y la capa de preview se esconde).
        ScrollViewReader { proxy in
            List(selection: $selection) {
                // Fila invisible que monta el supresor del resaltado nativo (selección teñida con el tema).
                Color.clear.frame(height: 0)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .suppressNativeListSelectionHighlight()
                    .modifier(ScrollObservationModifier(session: ScrollDiagnostics.observation, surface: .library))
                if grouping == .none {
                    ForEach(rowItems) { listRow($0) }
                } else {
                    ForEach(groupedLinks(filtered)) { group in
                        Section {
                            ForEach(group.links.map(RowItem.init(link:))) { listRow($0) }
                        } header: {
                            groupHeader(group)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .background(WindowBackground())
            // Navegación con flechas ↑/↓: desplaza hasta el enlace recién seleccionado.
            .onChange(of: scrollToID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    /// Fila de la lista (`List`): `LinkRowView` (snapshot + `.equatable()` → scroll fluido), selección
    /// nativa (⌘/⇧-clic gratis vía `.tag`), hover preview, menú contextual y SWIPE NATIVO de dos dedos:
    /// deslizar a la DERECHA (borde izquierdo) revela Favorito/Leído; a la IZQUIERDA (borde derecho),
    /// Papelera/Archivar. `allowsFullSwipe` dispara la primera acción al deslizar a fondo.
    private func listRow(_ item: RowItem) -> some View {
        let link = item.link
        return LinkRowView(link: link, data: rowData(for: item), showHoverPreview: true)
            .equatable()
            .tag(item.id)
            .listRowInsets(EdgeInsets(
                top: 0, leading: DesignSystem.Spacing.sm, bottom: 0, trailing: DesignSystem.Spacing.sm))
            .listRowSeparator(.hidden)
            .listRowBackground(ThemedSelectionBackground(
                isSelected: selection.contains(item.id), accent: palette.accent))
            .contextMenu { rowMenu(link) }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    BookmarkActions.toggleFavorite(link, in: context)
                } label: {
                    Label(link.isFavorite ? "Quitar favorito" : "Favorito",
                          systemImage: link.isFavorite ? "star.slash.fill" : "star.fill")
                }
                .tint(palette.accent)
                Button {
                    BookmarkActions.toggleRead(link, in: context)
                } label: {
                    Label(link.isRead ? "Marcar pendiente" : "Marcar leído",
                          systemImage: link.isRead ? "circle" : "checkmark.circle.fill")
                }
                .tint(.blue)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    BookmarkActions.moveToTrash(link, in: context)
                } label: {
                    Label("Papelera", systemImage: "trash.fill")
                }
                Button {
                    BookmarkActions.toggleArchive(link, in: context)
                } label: {
                    Label(link.isArchived ? "Desarchivar" : "Archivar", systemImage: "archivebox.fill")
                }
                .tint(Color(hex: "#E8833A"))
            }
    }

    /// Vista «Moodboard»: muro masonry tipo Pinterest/Raindrop por COLUMNAS. Las tarjetas
    /// se reparten en N columnas que se apilan VERTICALMENTE (sin huecos negros entre
    /// ellas, a diferencia de un grid por filas) y se ESTIRAN para llenar el ancho (sin
    /// separación a los lados). El nº de columnas sale de un ancho objetivo (que mueve el
    /// deslizador) acotado al nº de enlaces para no dejar columnas vacías. Las alturas
    /// varían con la proporción real de cada portada. Tap selecciona; ⌘-clic alterna.
    private var moodboardView: some View {
        GeometryReader { geo in
            let avail = Double(geo.size.width) - Double(DesignSystem.Spacing.md) * 2
            let target = max(140.0, 210.0 * coverScale)
            let n = max(1, min(8, min(Int((avail / target).rounded()), max(1, filtered.count))))
            let buckets = MoodboardLayout.distribute(filtered, into: n)
            ScrollView {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                    ForEach(0..<buckets.count, id: \.self) { col in
                        LazyVStack(spacing: DesignSystem.Spacing.sm) {
                            ForEach(buckets[col]) { link in
                                MoodboardCard(link: link)
                                    .overlay(alignment: .topLeading) { selectionBadge(for: link.id) }
                                    .contentShape(Rectangle())
                                    .onTapGesture { tapSelect(link.id) }
                                    .contextMenu { rowMenu(link) }
                                    .conditionalLinkDrag(link, enabled: sort != .manual)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                .padding(DesignSystem.Spacing.md)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .background(WindowBackground())
        }
    }

    /// Selección por tap en las vistas sin `List` (Cuadrícula/Moodboard): con ⌘
    /// pulsado alterna la pertenencia al conjunto (añade/quita); sin modificador
    /// reemplaza la selección por solo este enlace. `NSEvent.modifierFlags` da el
    /// estado del teclado en el momento del clic (`.onTapGesture` no pasa modificadores).
    private func tapSelect(_ id: Bookmark.ID) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            // ⌘-clic: alterna ESTE enlace, conservando el resto de la selección.
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            selectionAnchor = id
        } else if flags.contains(.shift), let anchor = selectionAnchor,
                  let a = filtered.firstIndex(where: { $0.id == anchor }),
                  let b = filtered.firstIndex(where: { $0.id == id }) {
            // ⇧-clic: selecciona el RANGO entre el ancla y este enlace (lo que daba el `List`).
            let range = a <= b ? a...b : b...a
            selection.formUnion(filtered[range].map(\.id))
        } else {
            // Clic normal: selección única; fija el ancla para un futuro ⇧-clic.
            selection = [id]
            selectionAnchor = id
        }
    }

    /// Mueve la selección ±1 en el orden visible y marca el objetivo de scroll (flechas ↑/↓).
    private func moveSelection(by delta: Int) -> KeyPress.Result {
        // En orden «Manual» (List nativo) deja que el propio List gestione las flechas.
        guard !(sort == .manual && grouping == .none) else { return .ignored }
        let ids = filtered.map(\.id)
        guard !ids.isEmpty else { return .ignored }
        let newIndex: Int
        if selection.count == 1, let first = selection.first, let cur = ids.firstIndex(of: first) {
            newIndex = max(0, min(ids.count - 1, cur + delta))
        } else {
            newIndex = delta > 0 ? 0 : ids.count - 1
        }
        let id = ids[newIndex]
        selection = [id]
        selectionAnchor = id
        scrollToID = id
        return .handled
    }

    /// Distintivo de selección (círculo dorado con check) sobre las tarjetas de
    /// Cuadrícula/Moodboard cuando hay 2+ seleccionadas, para que la multiselección sea
    /// visible también fuera de la `List`. Con una sola selección no se muestra (no
    /// estorba la lectura de una tarjeta concreta).
    @ViewBuilder
    private func selectionBadge(for id: Bookmark.ID) -> some View {
        if selection.count >= 2, selection.contains(id) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(palette.accent)
                .background(Circle().fill(palette.surface).padding(2))
                .padding(DesignSystem.Spacing.xs)
        }
    }

    /// Fila reutilizable de Titulares (densa solo-texto), en modo plano y agrupado.
    @ViewBuilder
    private func headlineRow(_ link: Bookmark) -> some View {
        HeadlineRow(link: link)
            .tag(link.id)
            .listRowBackground(ThemedSelectionBackground(
                isSelected: selection.contains(link.id), accent: palette.accent))
            .contextMenu { rowMenu(link) }
    }

    /// Vista «Titulares»: lista densa solo-texto (punto de color + título + host).
    private var headlinesView: some View {
        List(selection: $selection) {
            Color.clear.frame(height: 0)
                .listRowBackground(Color.clear)
                .suppressNativeListSelectionHighlight()
            if grouping == .none {
                ForEach(filtered) { link in headlineRow(link) }
            } else {
                ForEach(groupedLinks(filtered)) { group in
                    Section {
                        ForEach(group.links) { link in headlineRow(link) }
                    } header: {
                        groupHeader(group)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(WindowBackground())
    }

    /// Menú contextual de una fila/tarjeta. Si el clic derecho ocurre sobre un enlace
    /// que YA forma parte de una multiselección (2+), ofrece las acciones EN LOTE sobre
    /// todo el conjunto; en cualquier otro caso, las acciones individuales de siempre.
    @ViewBuilder
    private func rowMenu(_ link: Bookmark) -> some View {
        if selection.count >= 2, selection.contains(link.id) {
            bulkContextMenu
        } else {
            individualRowMenu(link)
        }
    }

    /// Menú contextual individual (acciones sobre un único enlace).
    @ViewBuilder
    private func individualRowMenu(_ link: Bookmark) -> some View {
        // Menú rico compartido; se le INYECTA la taxonomía (consultada una vez en esta vista),
        // para que construirlo por fila no dispare un @Query por fila (era el coste del scroll).
        LinkContextMenu(link: link, collections: categories, tags: tags, projects: menuProjects)
    }

    /// Acciones en lote dentro del menú contextual (cuando se hace clic derecho sobre
    /// un elemento ya seleccionado dentro de una multiselección). Reutiliza la misma
    /// lógica que la barra de lote.
    @ViewBuilder
    private var bulkContextMenu: some View {
        Button("Favorito (\(selection.count))", systemImage: "star") { bulkFavorite() }
        Button("Leído / no leído (\(selection.count))", systemImage: "checkmark.circle") { bulkRead() }
        Button("Archivar (\(selection.count))", systemImage: "archivebox") { bulkArchive() }
        Button("Abrir \(selection.count) en el navegador", systemImage: "safari") { bulkOpen() }
        Button("Copiar enlaces (\(selection.count))", systemImage: "doc.on.doc") { bulkCopy() }
        Button("Exportar a HTML (\(selection.count))", systemImage: "square.and.arrow.up") { bulkExport() }
        Button("Mejorar con IA (\(selection.count))", systemImage: "wand.and.stars") { bulkEnrichAI() }
            .disabled(aiEnrichProgress != nil)
        Menu("Mover a colección", systemImage: "folder") {
            Button("Buscar colección…", systemImage: "magnifyingglass") { showCollectionPicker = true }
            Divider()
            Button("Sin clasificar") { bulkMove(to: nil) }
        }
        if !tags.isEmpty {
            Menu("Etiquetar", systemImage: "tag") {
                // Buscador (List perezosa), NO un ForEach de miles de etiquetas (construir el menú
                // eager con tantos botones laggeaba al abrirlo).
                Button("Buscar etiqueta…", systemImage: "magnifyingglass") { showTagPicker = true }
            }
        }
        if !selectionTags.isEmpty {
            Menu("Quitar etiqueta", systemImage: "tag.slash") {
                ForEach(selectionTags) { tag in
                    Button(tag.name) { bulkUntag(tag) }
                }
            }
        }
        Divider()
        Button("Mover a la papelera (\(selection.count))", systemImage: "trash", role: .destructive) {
            requestBulkTrash()
        }
        Divider()
        Button("Deseleccionar", systemImage: "xmark.circle") { selection.removeAll() }
    }

    // MARK: - Barra de acciones en lote (multiselección)

    /// Enlaces seleccionados resueltos por id, en el orden actual de la lista (para que
    /// los recorridos de las acciones sean estables).
    private var selectedLinks: [Bookmark] { filtered.filter { selection.contains($0.id) } }

    /// Barra flotante premium de acciones en lote (DESIGN.md §1/§8: Liquid Glass con
    /// mesura). Aparece centrada abajo cuando hay 2+ seleccionados. Recorre los enlaces
    /// seleccionados y delega en `BookmarkActions`; guarda una sola vez por acción.
    private var bulkActionBar: some View {
        // Adapta la barra al ANCHO disponible (la columna se estrecha con el panel de detalle
        // abierto): `ViewThatFits` elige la 1.ª variante que cabe → con etiquetas si hay sitio,
        // solo iconos (con tooltips) si no, y como último recurso un scroll horizontal. Así NUNCA
        // se corta. `safeAreaInset(.bottom)` la centra y le propone el ancho de la columna.
        ViewThatFits(in: .horizontal) {
            bulkBarContent(compact: false)
            bulkBarContent(compact: true)
            ScrollView(.horizontal) { bulkBarContent(compact: true) }
                .scrollIndicators(.hidden)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(
            palette.background.opacity(0.38),
            in: RoundedRectangle(
                cornerRadius: DesignSystem.cornerRadius,
                style: .continuous
            )
        )
        .stacklumeGlass(
            in: RoundedRectangle(
                cornerRadius: DesignSystem.cornerRadius,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
                .strokeBorder(palette.border.opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.bottom, DesignSystem.Spacing.md)
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
    }

    /// Contenido de la barra de lote. `compact`: oculta los textos (solo iconos + tooltips) y
    /// reduce anchos/espaciado, para que `ViewThatFits` pueda encajarla en columnas estrechas.
    @ViewBuilder
    private func bulkBarContent(compact: Bool) -> some View {
        HStack(spacing: compact ? DesignSystem.Spacing.xs : DesignSystem.Spacing.sm) {
            if compact {
                Text("\(selection.count)")
                    .stacklumeFont(.subheadline.weight(.bold)).monospacedDigit()
                    .foregroundStyle(palette.textPrimary)
                    .fixedSize()
                    .accessibilityLabel("\(selection.count) seleccionados")
            } else {
                Text("\(selection.count) seleccionados")
                    .stacklumeFont(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(palette.textPrimary)
                    .fixedSize()
                    .padding(.trailing, DesignSystem.Spacing.xs)
            }

            bulkBarButton("Favorito", systemImage: "star", compact: compact) { bulkFavorite() }
            if baseFilter.readingStatus == .inbox {
                bulkBarButton("A lectura", systemImage: "book", compact: compact) { bulkQueueForReading() }
            }
            bulkBarButton("Leído", systemImage: "checkmark.circle", compact: compact) { bulkRead() }
            bulkBarButton("Archivar", systemImage: "archivebox", compact: compact) { bulkArchive() }
            bulkBarButton("Abrir", systemImage: "safari", compact: compact) { bulkOpen() }
            bulkBarButton("Copiar", systemImage: "doc.on.doc", compact: compact) { bulkCopy() }
            bulkBarButton("Exportar", systemImage: "square.and.arrow.up", compact: compact) { bulkExport() }
            if let p = aiEnrichProgress {
                VStack(spacing: 2) {
                    ProgressView().controlSize(.small)
                    if !compact {
                        Text("\(p.done)/\(p.total)")
                            .stacklumeFont(.caption2.monospacedDigit())
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                .frame(minWidth: compact ? 30 : 44)
            } else {
                bulkBarButton("Mejorar IA", systemImage: "wand.and.stars", compact: compact) { bulkEnrichAI() }
            }

            Menu {
                Button("Buscar colección…", systemImage: "magnifyingglass") { showCollectionPicker = true }
                Divider()
                Button("Sin clasificar") { bulkMove(to: nil) }
            } label: {
                bulkBarLabel("Mover", systemImage: "folder", compact: compact)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .themedHelp("Mover a colección")
            .accessibilityLabel("Mover a colección")

            Menu {
                if tags.isEmpty {
                    Text("No hay etiquetas")
                } else {
                    // Buscador (List perezosa), NO un ForEach de miles de etiquetas inline.
                    Button("Buscar etiqueta…", systemImage: "magnifyingglass") { showTagPicker = true }
                }
            } label: {
                bulkBarLabel("Etiquetar", systemImage: "tag", compact: compact)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(tags.isEmpty)
            .themedHelp("Añadir etiqueta")
            .accessibilityLabel("Añadir etiqueta")

            bulkBarButton("Papelera", systemImage: "trash", role: .destructive, compact: compact) {
                requestBulkTrash()
            }

            Divider().frame(height: 20).overlay(palette.border.opacity(0.5))

            bulkBarButton("Deseleccionar", systemImage: "xmark", compact: compact) { selection.removeAll() }
        }
        .fixedSize(horizontal: true, vertical: false)   // ancho intrínseco: ViewThatFits compara contra él
    }

    /// Botón de la barra de lote (icono + título compacto). `compact`: solo icono (+ tooltip).
    private func bulkBarButton(_ title: String, systemImage: String,
                               role: ButtonRole? = nil, compact: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) { bulkBarLabel(title, systemImage: systemImage, compact: compact) }
            .buttonStyle(.pressable)
            .themedHelp(title)
    }

    /// Etiqueta común de los controles de la barra de lote: icono arriba, texto debajo (oculto en
    /// `compact`, donde el `help`/tooltip da el nombre).
    private func bulkBarLabel(_ title: String, systemImage: String, compact: Bool = false) -> some View {
        VStack(spacing: 2) {
            Image(systemName: systemImage).scaledFont(14, weight: .semibold, scalesWithText: false)
            if !compact {
                Text(title).stacklumeFont(.caption2).stacklumeLineLimit(1)
            }
        }
        .frame(minWidth: compact ? 28 : 52)
        .foregroundStyle(palette.textSecondary)
        .contentShape(Rectangle())
    }

    // MARK: - Operaciones en lote (reutilizan `BookmarkActions`)

    private func bulkFavorite() { BookmarkActions.bulkSetFavorite(selectedLinks, in: context) }
    private func bulkQueueForReading() {
        BookmarkActions.bulkSetReadingStatus(.reading, for: selectedLinks, in: context)
        selection.removeAll()
    }
    private func bulkRead() { BookmarkActions.bulkSetRead(selectedLinks, in: context) }
    private func bulkArchive() { BookmarkActions.bulkSetArchive(selectedLinks, in: context) }

    private func bulkMove(to category: BookmarkCategory?) {
        BookmarkActions.bulkSetCategory(category, for: selectedLinks, in: context)
        selection.removeAll()
    }

    private func bulkTag(_ tag: Tag) {
        BookmarkActions.bulkAddTag(tag, to: selectedLinks, in: context)
    }

    /// Etiquetas PRESENTES en la selección (para el menú «Quitar etiqueta»: solo tiene
    /// sentido ofrecer las que algún enlace seleccionado realmente tiene).
    private var selectionTags: [Tag] {
        var seen = Set<UUID>()
        var result: [Tag] = []
        for link in selectedLinks {
            for tag in link.tags where seen.insert(tag.id).inserted { result.append(tag) }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func bulkUntag(_ tag: Tag) {
        BookmarkActions.bulkRemoveTag(tag, from: selectedLinks, in: context)
    }

    /// Pide confirmación si el ajuste lo exige; si no, borra directamente.
    private func requestBulkTrash() {
        if confirmBeforeDelete { showBulkDeleteConfirm = true } else { bulkTrash() }
    }

    private func bulkTrash() {
        BookmarkActions.bulkMoveToTrash(selectedLinks, in: context)
        selection.removeAll()
    }
}

private extension View {
    /// Hace la fila arrastrable (a colección/Finder) SOLO cuando `enabled`. En orden
    /// manual se desactiva para que `.onMove` pueda reordenar (no coexisten en macOS).
    @ViewBuilder
    func conditionalLinkDrag(_ link: Bookmark, enabled: Bool) -> some View {
        if enabled {
            self.draggable(BookmarkTransfer(from: link))
        } else {
            self
        }
    }
}

/// Hojas BUSCABLES de etiqueta/colección para UN enlace, abiertas desde el menú contextual
/// (`LibraryActions.pickTags(for:)` / `pickCollection(for:)`). Reutilizan las mismas hojas que el
/// lote (List perezosa). Extraído a un `ViewModifier` para no inflar el type-check del cuerpo de
/// `LibraryListView`. CLAVE de rendimiento: el menú contextual ya NO lista miles de etiquetas
/// inline (eso lo construía eager con faults de SwiftData y congelaba la app); abre estas hojas.
private struct ContextLinkPickers: ViewModifier {
    @Environment(LibraryActions.self) private var actions
    @Environment(\.modelContext) private var context
    @Environment(\.themePalette) private var palette
    // Las consultas viven dentro del modifier para que el cuerpo de la biblioteca no
    // materialice ambas colecciones en cada recomposición. Sus getters solo se evalúan
    // cuando se presenta realmente la hoja correspondiente.
    @Query(filter: #Predicate<Tag> { $0.deletedAt == nil }, sort: \Tag.order)
    private var tags: [Tag]
    @Query(filter: #Predicate<BookmarkCategory> { $0.deletedAt == nil },
           sort: \BookmarkCategory.order)
    private var categories: [BookmarkCategory]

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { actions.tagPickerLink },
                                 set: { actions.tagPickerLink = $0 })) { link in
                BulkTagPickerSheet(tags: tags, count: 1) { tag in
                    BookmarkActions.bulkAddTag(tag, to: [link], in: context)
                }
                .themedSheet(palette)
            }
            .sheet(item: Binding(get: { actions.collectionPickerLink },
                                 set: { actions.collectionPickerLink = $0 })) { link in
                BulkCollectionPickerSheet(collections: categories, count: 1) { category in
                    BookmarkActions.bulkSetCategory(category, for: [link], in: context)
                }
                .themedSheet(palette)
            }
    }
}
