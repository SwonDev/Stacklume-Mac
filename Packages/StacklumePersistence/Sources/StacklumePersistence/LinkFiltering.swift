import Foundation
import StacklumeCore
#if DEBUG
import OSLog
private let perfLog = Logger(subsystem: "com.swondev.stacklume", category: "Perf")
#endif

/// Criterios de búsqueda y filtrado de enlaces (Biblioteca).
public struct LinkFilter: Sendable {
    public var searchText: String = ""
    public var categoryID: UUID?
    public var tagID: UUID?
    public var onlyFavorites: Bool = false
    public var readingStatus: ReadingStatus?
    public var platform: Platform?
    public var contentType: ContentType?
    // Filtros inteligentes (estilo Raindrop).
    public var onlyBroken: Bool = false
    public var onlyUntagged: Bool = false
    public var onlyUncategorized: Bool = false
    public var onlyWithReminder: Bool = false
    public var onlyUnread: Bool = false
    /// Si es `true`, muestra SOLO archivados; si es `false`, los OCULTA (por defecto).
    public var onlyArchived: Bool = false

    public init() {}

    public var isActive: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
            || categoryID != nil
            || tagID != nil
            || onlyFavorites
            || readingStatus != nil
            || platform != nil
            || contentType != nil
            || onlyBroken
            || onlyUntagged
            || onlyUncategorized
            || onlyWithReminder
            || onlyUnread
            || onlyArchived
    }
}

/// Orden de la lista de enlaces.
public enum LinkSort: String, CaseIterable, Sendable, Identifiable {
    case recent, oldest, title, favorite, stars, manual

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .recent: "Más recientes"
        case .oldest: "Más antiguos"
        case .title: "Título (A–Z)"
        case .favorite: "Favoritos primero"
        case .stars: "Estrellas (GitHub)"
        case .manual: "Orden manual"
        }
    }

    public var sfSymbol: String {
        switch self {
        case .recent: "clock.arrow.circlepath"
        case .oldest: "clock"
        case .title: "textformat.abc"
        case .favorite: "star"
        case .stars: "star.circle"
        case .manual: "line.3.horizontal"
        }
    }
}

/// Filtra y ordena enlaces en memoria. Robusto y suficiente para el volumen de
/// una biblioteca personal; en fases posteriores se puede optimizar con
/// `#Predicate`/índices o FTS5.
@MainActor
public func filteredLinks(_ links: [Bookmark], using filter: LinkFilter, sort: LinkSort) -> [Bookmark] {
    #if DEBUG
    let _perfStart = Date()
    defer {
        let ms = Date().timeIntervalSince(_perfStart) * 1000
        if ms > 5 { perfLog.log("filteredLinks: \(links.count) enlaces en \(ms, format: .fixed(precision: 1)) ms") }
    }
    #endif
    // Búsqueda con operadores estilo Raindrop ("frase", -excluir, tag:, type:, site:).
    let query = SearchQuery(filter.searchText)

    let result = links.filter { link in
        guard link.deletedAt == nil else { return false }
        // Los archivados se ocultan por defecto; solo aparecen con onlyArchived.
        if filter.onlyArchived { if !link.isArchived { return false } }
        else if link.isArchived { return false }

        if filter.onlyFavorites && !link.isFavorite { return false }
        if let status = filter.readingStatus, link.readingStatus != status { return false }
        if let platform = filter.platform, link.platform != platform { return false }
        if let type = filter.contentType, link.contentType != type { return false }
        if filter.onlyBroken && !(link.healthStatus == .broken || link.healthStatus == .timeout) { return false }
        if filter.onlyUntagged && !link.tags.isEmpty { return false }
        if filter.onlyUncategorized && link.category != nil { return false }
        if filter.onlyWithReminder && link.reminderAt == nil { return false }
        if filter.onlyUnread && link.isRead { return false }
        if let categoryID = filter.categoryID, link.category?.id != categoryID { return false }
        if let tagID = filter.tagID, !link.tags.contains(where: { $0.id == tagID }) { return false }

        if !query.isEmpty, !query.matches(link) { return false }
        return true
    }

    return result.sorted { lhs, rhs in
        switch sort {
        case .recent: lhs.createdAt > rhs.createdAt
        case .oldest: lhs.createdAt < rhs.createdAt
        case .title: lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        case .favorite:
            lhs.isFavorite == rhs.isFavorite
                ? lhs.createdAt > rhs.createdAt
                : (lhs.isFavorite && !rhs.isFavorite)
        case .stars:
            (lhs.repoInfo?.stars ?? -1) > (rhs.repoInfo?.stars ?? -1)
        case .manual:
            lhs.order < rhs.order
        }
    }
}
