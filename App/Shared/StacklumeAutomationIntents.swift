import AppIntents
import Foundation
import SwiftData
import StacklumeCore
import StacklumePersistence

// MARK: - Límites y acceso al almacén

/// Punto único de acceso SwiftData para App Intents. Nunca expone `Bookmark` fuera del
/// `MainActor`: las consultas devuelven snapshots `Sendable` (`AppEntity`) y las acciones
/// resuelven de nuevo los UUID justo antes de mutar. Así un resultado antiguo de Atajos no
/// conserva referencias vivas al modelo ni puede modificar un objeto ya enviado a Papelera.
@MainActor
private enum StacklumeAutomationStore {
    static func makeContext() -> ModelContext {
        ModelContext(PersistenceController.makeContainer())
    }

    static func activeBookmarks(in context: ModelContext, includingArchived: Bool = true) -> [Bookmark] {
        let links = (try? context.fetch(FetchDescriptor<Bookmark>(
            predicate: #Predicate { $0.deletedAt == nil }
        ))) ?? []
        return includingArchived ? links : links.filter { !$0.isArchived }
    }

    static func bookmarks(ids: [UUID], in context: ModelContext) -> [Bookmark] {
        let requested = Set(ids)
        guard !requested.isEmpty else { return [] }
        var byID: [UUID: Bookmark] = [:]
        for link in activeBookmarks(in: context) where requested.contains(link.id) {
            // Un backup antiguo o manipulado podría haber duplicado un UUID. Conservamos
            // la primera fila en vez de usar `Dictionary(uniqueKeysWithValues:)`, que haría trap.
            if byID[link.id] == nil { byID[link.id] = link }
        }
        // Conserva el orden producido por Atajos y elimina identificadores repetidos.
        var seen = Set<UUID>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return byID[id]
        }
    }

    static func activeCollections(in context: ModelContext) -> [BookmarkCategory] {
        ((try? context.fetch(FetchDescriptor<BookmarkCategory>())) ?? [])
            .filter { $0.deletedAt == nil }
    }

    static func activeTags(in context: ModelContext) -> [Tag] {
        ((try? context.fetch(FetchDescriptor<Tag>())) ?? [])
            .filter { $0.deletedAt == nil }
    }
}

// MARK: - Entidades de Atajos

/// Snapshot seguro de un enlace. Deliberadamente no publica notas, texto offline,
/// resaltados ni rutas de archivos locales: Atajos recibe solo metadatos necesarios para
/// encadenar acciones. Los documentos locales usan una ruta interna `stacklume://`.
struct StacklumeBookmarkEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Enlace de Stacklume",
        numericFormat: "\(placeholder: .int) enlaces de Stacklume"
    )
    static let defaultQuery = StacklumeBookmarkEntityQuery()

    let id: UUID

    @Property(title: "Título")
    var title: String

    @Property(title: "Enlace")
    var url: URL

    @Property(title: "Colección")
    var collectionName: String?

    @Property(title: "Etiquetas")
    var tagNames: [String]

    @Property(title: "Favorito")
    var isFavorite: Bool

    @Property(title: "Leído")
    var isRead: Bool

    @Property(title: "Archivado")
    var isArchived: Bool

    @Property(title: "Fecha de creación")
    var createdAt: Date

    var displayRepresentation: DisplayRepresentation {
        let subtitle = collectionName ?? url.host() ?? "Stacklume"
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(subtitle)",
            image: .init(systemName: isFavorite ? "star.fill" : "bookmark.fill")
        )
    }

    @MainActor
    init(_ link: Bookmark) {
        id = link.id
        title = link.title.isEmpty ? link.url : link.title
        // Lista cerrada: nunca entregamos `file://` ni un esquema ejecutable/arbitrario a
        // `OpenURLIntent`. El contenido no web se abre a través de la ruta interna exacta.
        if let candidate = URL(string: link.url),
           ["http", "https", "stacklume"].contains(candidate.scheme?.lowercased() ?? "") {
            url = candidate
        } else {
            url = URL(string: "stacklume://bookmark/\(link.id.uuidString)")!
        }
        collectionName = link.category?.name
        tagNames = link.tags.map(\.name).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        isFavorite = link.isFavorite
        isRead = link.isRead
        isArchived = link.isArchived
        createdAt = link.createdAt
    }
}

struct StacklumeCollectionEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Colección de Stacklume",
        numericFormat: "\(placeholder: .int) colecciones de Stacklume"
    )
    static let defaultQuery = StacklumeCollectionEntityQuery()

    let id: UUID

    @Property(title: "Nombre")
    var name: String

    @Property(title: "Colección superior")
    var parentName: String?

    @Property(title: "Número de enlaces")
    var linkCount: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: parentName.map { "Dentro de \($0)" } ?? "\(linkCount) enlaces",
            image: .init(systemName: "folder.fill")
        )
    }

    @MainActor
    init(_ category: BookmarkCategory) {
        id = category.id
        name = category.name
        parentName = category.parent?.name
        linkCount = category.activeLinkCount
    }
}

struct StacklumeTagEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Etiqueta de Stacklume",
        numericFormat: "\(placeholder: .int) etiquetas de Stacklume"
    )
    static let defaultQuery = StacklumeTagEntityQuery()

    let id: UUID

    @Property(title: "Nombre")
    var name: String

    @Property(title: "Número de enlaces")
    var linkCount: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(linkCount) enlaces",
            image: .init(systemName: "number")
        )
    }

    @MainActor
    init(_ tag: Tag) {
        id = tag.id
        name = tag.name
        linkCount = tag.activeLinkCount
    }
}

// MARK: - Consultas de entidades

struct StacklumeBookmarkEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [StacklumeBookmarkEntity] {
        guard StacklumeAutomationAccess.isAllowed(.read) else { return [] }
        let boundedIdentifiers = Array(
            identifiers.prefix(StacklumeAutomationPolicy.maximumMutationCount)
        )
        return await MainActor.run {
            let context = StacklumeAutomationStore.makeContext()
            return StacklumeAutomationStore.bookmarks(ids: boundedIdentifiers, in: context)
                .map(StacklumeBookmarkEntity.init)
        }
    }

    func suggestedEntities() async throws -> [StacklumeBookmarkEntity] {
        guard StacklumeAutomationAccess.isAllowed(.read) else { return [] }
        return await MainActor.run {
            let context = StacklumeAutomationStore.makeContext()
            return StacklumeAutomationStore.activeBookmarks(in: context, includingArchived: false)
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(StacklumeAutomationPolicy.suggestedEntityCount)
                .map(StacklumeBookmarkEntity.init)
        }
    }

    func entities(matching string: String) async throws -> [StacklumeBookmarkEntity] {
        guard StacklumeAutomationAccess.isAllowed(.read) else { return [] }
        let clean = StacklumeAutomationPolicy.sanitizedQuery(string)
        guard !clean.isEmpty else { return try await suggestedEntities() }
        return await MainActor.run {
            let context = StacklumeAutomationStore.makeContext()
            let query = SearchQuery.parse(clean)
            return StacklumeAutomationStore.activeBookmarks(in: context, includingArchived: false)
                .filter { query.lexicalMatches($0) }
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(StacklumeAutomationPolicy.maximumResultCount)
                .map(StacklumeBookmarkEntity.init)
        }
    }
}

struct StacklumeCollectionEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [StacklumeCollectionEntity] {
        guard StacklumeAutomationAccess.isAllowed(.read) else { return [] }
        let boundedIdentifiers = Array(
            identifiers.prefix(StacklumeAutomationPolicy.maximumResultCount)
        )
        let requested = Set(boundedIdentifiers)
        return await MainActor.run {
            let context = StacklumeAutomationStore.makeContext()
            var byID: [UUID: BookmarkCategory] = [:]
            for category in StacklumeAutomationStore.activeCollections(in: context)
            where requested.contains(category.id) {
                if byID[category.id] == nil { byID[category.id] = category }
            }
            var seen = Set<UUID>()
            return boundedIdentifiers
                .filter { seen.insert($0).inserted }
                .compactMap { byID[$0] }
                .map(StacklumeCollectionEntity.init)
        }
    }

    func suggestedEntities() async throws -> [StacklumeCollectionEntity] {
        guard StacklumeAutomationAccess.isAllowed(.read) else { return [] }
        return await MainActor.run {
            let context = StacklumeAutomationStore.makeContext()
            return StacklumeAutomationStore.activeCollections(in: context)
                .sorted {
                    $0.order != $1.order
                        ? $0.order < $1.order
                        : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                .prefix(StacklumeAutomationPolicy.suggestedEntityCount)
                .map(StacklumeCollectionEntity.init)
        }
    }

    func entities(matching string: String) async throws -> [StacklumeCollectionEntity] {
        guard StacklumeAutomationAccess.isAllowed(.read) else { return [] }
        let clean = StacklumeAutomationPolicy.sanitizedQuery(string)
        guard !clean.isEmpty else { return try await suggestedEntities() }
        return await MainActor.run {
            let context = StacklumeAutomationStore.makeContext()
            return StacklumeAutomationStore.activeCollections(in: context)
                .filter { $0.name.localizedCaseInsensitiveContains(clean) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .prefix(StacklumeAutomationPolicy.maximumResultCount)
                .map(StacklumeCollectionEntity.init)
        }
    }
}

struct StacklumeTagEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [StacklumeTagEntity] {
        guard StacklumeAutomationAccess.isAllowed(.read) else { return [] }
        let boundedIdentifiers = Array(
            identifiers.prefix(StacklumeAutomationPolicy.maximumResultCount)
        )
        let requested = Set(boundedIdentifiers)
        return await MainActor.run {
            let context = StacklumeAutomationStore.makeContext()
            var byID: [UUID: Tag] = [:]
            for tag in StacklumeAutomationStore.activeTags(in: context)
            where requested.contains(tag.id) {
                if byID[tag.id] == nil { byID[tag.id] = tag }
            }
            var seen = Set<UUID>()
            return boundedIdentifiers
                .filter { seen.insert($0).inserted }
                .compactMap { byID[$0] }
                .map(StacklumeTagEntity.init)
        }
    }

    func suggestedEntities() async throws -> [StacklumeTagEntity] {
        guard StacklumeAutomationAccess.isAllowed(.read) else { return [] }
        return await MainActor.run {
            let context = StacklumeAutomationStore.makeContext()
            return StacklumeAutomationStore.activeTags(in: context)
                .sorted {
                    $0.activeLinkCount != $1.activeLinkCount
                        ? $0.activeLinkCount > $1.activeLinkCount
                        : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                .prefix(StacklumeAutomationPolicy.suggestedEntityCount)
                .map(StacklumeTagEntity.init)
        }
    }

    func entities(matching string: String) async throws -> [StacklumeTagEntity] {
        guard StacklumeAutomationAccess.isAllowed(.read) else { return [] }
        let clean = StacklumeAutomationPolicy.sanitizedQuery(string)
        guard !clean.isEmpty else { return try await suggestedEntities() }
        return await MainActor.run {
            let context = StacklumeAutomationStore.makeContext()
            return StacklumeAutomationStore.activeTags(in: context)
                .filter { $0.name.localizedCaseInsensitiveContains(clean) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .prefix(StacklumeAutomationPolicy.maximumResultCount)
                .map(StacklumeTagEntity.init)
        }
    }
}

// MARK: - Obtener enlaces

enum StacklumeBookmarkFilter: String, AppEnum {
    case all
    case favorites
    case unread
    case readingQueue
    case archived
    case broken
    case dueForReview

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Filtro de enlaces"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .all: "Todos",
        .favorites: "Favoritos",
        .unread: "Sin leer",
        .readingQueue: "Cola de lectura",
        .archived: "Archivados",
        .broken: "Enlaces rotos",
        .dueForReview: "Pendientes de repaso",
    ]

    var policyKey: StacklumeAutomationFilterKey {
        StacklumeAutomationFilterKey(rawValue: rawValue) ?? .all
    }
}

/// Devuelve entidades ricas para que Atajos pueda leer título, URL, colección,
/// etiquetas y estados, y encadenarlas con las acciones de organización inferiores.
struct GetStacklumeBookmarksIntent: AppIntent {
    static let title: LocalizedStringResource = "Obtener enlaces de Stacklume"
    static let description = IntentDescription(
        "Busca en tu biblioteca local y devuelve enlaces con sus metadatos para usarlos en otros pasos de Atajos."
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Texto", description: "Opcional: título, URL, etiqueta, colección o descripción.")
    var query: String?

    @Parameter(title: "Filtro", default: .all)
    var filter: StacklumeBookmarkFilter

    @Parameter(title: "Máximo de resultados", default: 20)
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Obtener enlaces de Stacklume")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[StacklumeBookmarkEntity]> & ProvidesDialog {
        try CommercialLicenseAccessPolicy.requireAccess()
        guard StacklumeAutomationAccess.isAllowed(.read) else {
            StacklumeAutomationAuditLog.record(
                capability: .read, action: .getBookmarks, outcome: .blocked, itemCount: 0
            )
            return .result(
                value: [],
                dialog: "La consulta desde Atajos está desactivada. Actívala en Stacklume › Ajustes › Privacidad."
            )
        }
        let context = StacklumeAutomationStore.makeContext()
        let now = Date()
        let cleanQuery = StacklumeAutomationPolicy.sanitizedQuery(query)
        let parsed = cleanQuery.isEmpty ? nil : SearchQuery.parse(cleanQuery)
        let maximum = StacklumeAutomationPolicy.resultLimit(limit)

        let matches = StacklumeAutomationStore.activeBookmarks(in: context)
            .filter { link in
                let passesFilter = StacklumeAutomationPolicy.includes(
                    filter.policyKey,
                    isFavorite: link.isFavorite,
                    isRead: link.isRead,
                    isArchived: link.isArchived,
                    isReadingPending: link.readingStatus != .done,
                    isBroken: link.healthStatus == .broken || link.healthStatus == .timeout,
                    reviewAt: link.reviewAt,
                    now: now
                )
                return passesFilter && (parsed?.lexicalMatches(link) ?? true)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(maximum)
            .map(StacklumeBookmarkEntity.init)

        let dialog: IntentDialog = matches.isEmpty
            ? "No encontré enlaces con esos criterios."
            : "Encontré \(matches.count) enlace(s)."
        StacklumeAutomationAuditLog.record(
            capability: .read, action: .getBookmarks, outcome: .completed, itemCount: matches.count
        )
        return .result(value: matches, dialog: dialog)
    }
}

// MARK: - Mutaciones explícitas y no destructivas

enum StacklumeBookmarkAction: String, AppEnum {
    case favorite
    case unfavorite
    case markRead
    case markUnread
    case archive
    case unarchive
    case addToReadingQueue
    case startReading
    case completeReading

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Acción sobre enlaces"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .favorite: "Marcar como favorito",
        .unfavorite: "Quitar de favoritos",
        .markRead: "Marcar como leído",
        .markUnread: "Marcar como no leído",
        .archive: "Archivar",
        .unarchive: "Desarchivar",
        .addToReadingQueue: "Añadir a la cola de lectura",
        .startReading: "Marcar como leyendo",
        .completeReading: "Completar lectura",
    ]
}

struct ChangeStacklumeBookmarkStateIntent: AppIntent {
    static let title: LocalizedStringResource = "Cambiar estado de enlaces en Stacklume"
    static let description = IntentDescription(
        "Actualiza de forma explícita favoritos, lectura o archivado. Nunca elimina enlaces."
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Enlaces")
    var bookmarks: [StacklumeBookmarkEntity]

    @Parameter(title: "Acción")
    var action: StacklumeBookmarkAction

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action) en \(\.$bookmarks)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try CommercialLicenseAccessPolicy.requireAccess()
        guard StacklumeAutomationAccess.isAllowed(.organize) else {
            StacklumeAutomationAuditLog.record(
                capability: .organize, action: .changeState, outcome: .blocked,
                itemCount: bookmarks.count
            )
            return .result(
                dialog: "La organización desde Atajos está desactivada. Actívala en Stacklume › Ajustes › Privacidad."
            )
        }
        guard !bookmarks.isEmpty else { return .result(dialog: "No recibí ningún enlace.") }
        guard StacklumeAutomationPolicy.allowsMutationCount(bookmarks.count) else {
            return .result(dialog: "La acción admite entre 1 y \(StacklumeAutomationPolicy.maximumMutationCount) enlaces.")
        }

        let context = StacklumeAutomationStore.makeContext()
        let links = StacklumeAutomationStore.bookmarks(ids: bookmarks.map(\.id), in: context)
        guard !links.isEmpty else {
            return .result(dialog: "Esos enlaces ya no están disponibles en la biblioteca.")
        }
        let now = Date()
        for link in links {
            switch action {
            case .favorite: link.isFavorite = true
            case .unfavorite: link.isFavorite = false
            case .markRead: link.isRead = true
            case .markUnread: link.isRead = false
            case .archive: link.isArchived = true
            case .unarchive: link.isArchived = false
            case .addToReadingQueue: link.readingStatus = .inbox
            case .startReading: link.readingStatus = .reading
            case .completeReading:
                link.readingStatus = .done
                link.isRead = true
            }
            link.updatedAt = now
        }
        context.saveLogging()
        WidgetReloader.reload()
        StacklumeAutomationAuditLog.record(
            capability: .organize, action: .changeState, outcome: .completed, itemCount: links.count
        )
        return .result(dialog: "Actualicé \(links.count) enlace(s) en Stacklume.")
    }
}

struct MoveStacklumeBookmarksIntent: AppIntent {
    static let title: LocalizedStringResource = "Mover enlaces a una colección de Stacklume"
    static let description = IntentDescription(
        "Mueve enlaces existentes a una colección concreta de tu biblioteca."
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Enlaces")
    var bookmarks: [StacklumeBookmarkEntity]

    @Parameter(title: "Colección")
    var collection: StacklumeCollectionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Mover \(\.$bookmarks) a \(\.$collection)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try CommercialLicenseAccessPolicy.requireAccess()
        guard StacklumeAutomationAccess.isAllowed(.organize) else {
            StacklumeAutomationAuditLog.record(
                capability: .organize, action: .moveToCollection, outcome: .blocked,
                itemCount: bookmarks.count
            )
            return .result(
                dialog: "La organización desde Atajos está desactivada. Actívala en Stacklume › Ajustes › Privacidad."
            )
        }
        guard !bookmarks.isEmpty else { return .result(dialog: "No recibí ningún enlace.") }
        guard StacklumeAutomationPolicy.allowsMutationCount(bookmarks.count) else {
            return .result(dialog: "La acción admite entre 1 y \(StacklumeAutomationPolicy.maximumMutationCount) enlaces.")
        }

        let context = StacklumeAutomationStore.makeContext()
        guard let destination = StacklumeAutomationStore.activeCollections(in: context)
            .first(where: { $0.id == collection.id }) else {
            return .result(dialog: "La colección elegida ya no está disponible.")
        }
        let links = StacklumeAutomationStore.bookmarks(ids: bookmarks.map(\.id), in: context)
        guard !links.isEmpty else {
            return .result(dialog: "Esos enlaces ya no están disponibles en la biblioteca.")
        }
        let now = Date()
        for link in links {
            link.category = destination
            link.updatedAt = now
        }
        context.saveLogging()
        for link in links { SpotlightIndexer.index(link) }
        WidgetReloader.reload()
        StacklumeAutomationAuditLog.record(
            capability: .organize, action: .moveToCollection, outcome: .completed, itemCount: links.count
        )
        return .result(dialog: "Moví \(links.count) enlace(s) a «\(destination.name)».")
    }
}

enum StacklumeTagAction: String, AppEnum {
    case add
    case remove

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Acción de etiquetas"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .add: "Añadir etiquetas",
        .remove: "Quitar etiquetas",
    ]
}

struct EditStacklumeBookmarkTagsIntent: AppIntent {
    static let title: LocalizedStringResource = "Editar etiquetas de enlaces en Stacklume"
    static let description = IntentDescription(
        "Añade o quita etiquetas existentes sin crear duplicados."
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Enlaces")
    var bookmarks: [StacklumeBookmarkEntity]

    @Parameter(title: "Acción")
    var action: StacklumeTagAction

    @Parameter(title: "Etiquetas")
    var tags: [StacklumeTagEntity]

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action) en \(\.$bookmarks)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try CommercialLicenseAccessPolicy.requireAccess()
        guard StacklumeAutomationAccess.isAllowed(.organize) else {
            StacklumeAutomationAuditLog.record(
                capability: .organize, action: .editTags, outcome: .blocked,
                itemCount: bookmarks.count
            )
            return .result(
                dialog: "La organización desde Atajos está desactivada. Actívala en Stacklume › Ajustes › Privacidad."
            )
        }
        guard !bookmarks.isEmpty, !tags.isEmpty else {
            return .result(dialog: "Elige al menos un enlace y una etiqueta.")
        }
        guard StacklumeAutomationPolicy.allowsMutationCount(bookmarks.count) else {
            return .result(dialog: "La acción admite entre 1 y \(StacklumeAutomationPolicy.maximumMutationCount) enlaces.")
        }
        guard StacklumeAutomationPolicy.allowsTagCount(tags.count) else {
            return .result(dialog: "La acción admite entre 1 y \(StacklumeAutomationPolicy.maximumTagCountPerAction) etiquetas.")
        }

        let context = StacklumeAutomationStore.makeContext()
        let links = StacklumeAutomationStore.bookmarks(ids: bookmarks.map(\.id), in: context)
        let requestedTagIDs = Set(tags.map(\.id))
        let resolvedTags = StacklumeAutomationStore.activeTags(in: context)
            .filter { requestedTagIDs.contains($0.id) }
        guard !links.isEmpty, !resolvedTags.isEmpty else {
            return .result(dialog: "Los enlaces o etiquetas elegidos ya no están disponibles.")
        }

        let now = Date()
        for link in links {
            switch action {
            case .add:
                let current = Set(link.tags.map(\.id))
                link.tags.append(contentsOf: resolvedTags.filter { !current.contains($0.id) })
            case .remove:
                link.tags.removeAll { requestedTagIDs.contains($0.id) }
            }
            link.updatedAt = now
        }
        context.saveLogging()
        for link in links { SpotlightIndexer.index(link) }
        StacklumeAutomationAuditLog.record(
            capability: .organize, action: .editTags, outcome: .completed, itemCount: links.count
        )
        return .result(dialog: "Actualicé las etiquetas de \(links.count) enlace(s).")
    }
}

/// Abre una entidad obtenida por cualquier acción anterior. Los enlaces web salen al
/// navegador; los documentos locales usan su deep link interno sin revelar rutas de disco.
struct OpenStacklumeBookmarkIntent: AppIntent {
    static let title: LocalizedStringResource = "Abrir un enlace de Stacklume"
    static let description = IntentDescription("Abre un enlace concreto obtenido desde Stacklume.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Enlace")
    var bookmark: StacklumeBookmarkEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Abrir \(\.$bookmark)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent & ProvidesDialog {
        try CommercialLicenseAccessPolicy.requireAccess()
        guard StacklumeAutomationAccess.isAllowed(.read) else {
            StacklumeAutomationAuditLog.record(
                capability: .read, action: .openBookmark, outcome: .blocked, itemCount: 1
            )
            return .result(
                opensIntent: OpenStacklumeIntent(),
                dialog: "La consulta desde Atajos está desactivada. Actívala en Stacklume › Ajustes › Privacidad."
            )
        }
        let context = StacklumeAutomationStore.makeContext()
        guard let current = StacklumeAutomationStore.bookmarks(ids: [bookmark.id], in: context).first else {
            StacklumeAutomationAuditLog.record(
                capability: .read, action: .openBookmark, outcome: .completed, itemCount: 0
            )
            return .result(
                opensIntent: OpenStacklumeIntent(),
                dialog: "Ese enlace ya no está disponible en la biblioteca."
            )
        }
        let safeEntity = StacklumeBookmarkEntity(current)
        StacklumeAutomationAuditLog.record(
            capability: .read, action: .openBookmark, outcome: .completed, itemCount: 1
        )
        return .result(
            opensIntent: OpenURLIntent(safeEntity.url),
            dialog: "Abriendo «\(safeEntity.title)»."
        )
    }
}
