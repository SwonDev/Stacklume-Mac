import Foundation

// MARK: - Ofertas de Steam (CheapShark)

/// Cómo ordenar las ofertas de Steam. El valor crudo es el `sortBy` que entiende
/// la API de CheapShark.
public enum SteamDealSort: String, Codable, CaseIterable, Sendable, Identifiable {
    case savings = "Savings"
    case price = "Price"
    case reviews = "Reviews"
    case metacritic = "Metacritic"
    case recent = "Recent"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .savings: "Mayor descuento"
        case .price: "Precio más bajo"
        case .reviews: "Mejor valorados"
        case .metacritic: "Mejor Metacritic"
        case .recent: "Más recientes"
        }
    }

    public var sfSymbol: String {
        switch self {
        case .savings: "tag.fill"
        case .price: "eurosign.circle.fill"
        case .reviews: "hand.thumbsup.fill"
        case .metacritic: "star.leadinghalf.filled"
        case .recent: "clock.fill"
        }
    }
}

/// Una oferta de un juego en Steam.
public struct SteamDeal: Sendable, Identifiable, Equatable {
    public var id: String { dealID }
    public let dealID: String
    public let title: String
    public let salePrice: Double
    public let normalPrice: Double
    public let savingsPercent: Int
    public let steamRatingPercent: Int?
    public let metacriticScore: Int?
    public let steamAppID: String?
    public let thumb: String?

    /// URL para abrir: si hay appID se abre la ficha de Steam (la app la enriquece
    /// como enlace de Steam); si no, el redirect oficial de CheapShark.
    public var storeURL: String {
        if let steamAppID, !steamAppID.isEmpty {
            return "https://store.steampowered.com/app/\(steamAppID)"
        }
        return "https://www.cheapshark.com/redirect?dealID=\(dealID)"
    }

    public var salePriceText: String { String(format: "%.2f$", salePrice) }
    public var normalPriceText: String { String(format: "%.2f$", normalPrice) }
}

/// Obtiene ofertas de juegos de Steam vía la API abierta de CheapShark (sin auth).
public actor SteamDealsService {
    public static let shared = SteamDealsService()

    private var cache: [String: [SteamDeal]] = [:]   // clave = sort+onSale
    private var lastFetch: [String: Date] = [:]
    private let ttl: TimeInterval = 60 * 20   // 20 min

    public init() {}

    public func deals(sort: SteamDealSort, onSaleOnly: Bool, limit: Int = 12) async -> [SteamDeal] {
        let key = "\(sort.rawValue)-\(onSaleOnly)"
        if let last = lastFetch[key], Date().timeIntervalSince(last) < ttl,
           let cached = cache[key], !cached.isEmpty {
            return Array(cached.prefix(limit))
        }
        var components = URLComponents(string: "https://www.cheapshark.com/api/1.0/deals")!
        var query = [
            URLQueryItem(name: "storeID", value: "1"),   // 1 = Steam
            URLQueryItem(name: "sortBy", value: sort.rawValue),
            URLQueryItem(name: "pageSize", value: "\(max(limit, 60))")
        ]
        if onSaleOnly { query.append(URLQueryItem(name: "onSale", value: "1")) }
        components.queryItems = query
        guard let url = components.url else { return cache[key] ?? [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let items = try? JSONDecoder().decode([CheapSharkDeal].self, from: data) else {
            return cache[key] ?? []
        }
        let deals = items.map { item -> SteamDeal in
            SteamDeal(
                dealID: item.dealID,
                title: item.title,
                salePrice: Double(item.salePrice) ?? 0,
                normalPrice: Double(item.normalPrice) ?? 0,
                savingsPercent: Int((Double(item.savings) ?? 0).rounded()),
                steamRatingPercent: item.steamRatingPercent.flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil },
                metacriticScore: item.metacriticScore.flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil },
                steamAppID: item.steamAppID,
                thumb: item.thumb
            )
        }
        cache[key] = deals
        lastFetch[key] = Date()
        return Array(deals.prefix(limit))
    }

    /// Página de ofertas para la vista ampliada (scroll infinito). `page` empieza
    /// en 1; CheapShark usa `pageNumber` 0-based. Devuelve [] cuando no hay más.
    public func page(_ page: Int, sort: SteamDealSort, onSaleOnly: Bool, pageSize: Int = 60) async -> [SteamDeal] {
        var components = URLComponents(string: "https://www.cheapshark.com/api/1.0/deals")!
        var query = [
            URLQueryItem(name: "storeID", value: "1"),
            URLQueryItem(name: "sortBy", value: sort.rawValue),
            URLQueryItem(name: "pageSize", value: "\(pageSize)"),
            URLQueryItem(name: "pageNumber", value: "\(max(page - 1, 0))")
        ]
        if onSaleOnly { query.append(URLQueryItem(name: "onSale", value: "1")) }
        components.queryItems = query
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let items = try? JSONDecoder().decode([CheapSharkDeal].self, from: data) else {
            return []
        }
        return items.map { item in
            SteamDeal(
                dealID: item.dealID, title: item.title,
                salePrice: Double(item.salePrice) ?? 0,
                normalPrice: Double(item.normalPrice) ?? 0,
                savingsPercent: Int((Double(item.savings) ?? 0).rounded()),
                steamRatingPercent: item.steamRatingPercent.flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil },
                metacriticScore: item.metacriticScore.flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil },
                steamAppID: item.steamAppID, thumb: item.thumb)
        }
    }
}

private struct CheapSharkDeal: Decodable {
    let dealID: String
    let title: String
    let salePrice: String
    let normalPrice: String
    let savings: String
    let steamRatingPercent: String?
    let metacriticScore: String?
    let steamAppID: String?
    let thumb: String?
}

// MARK: - Hacker News (API oficial de Firebase)

/// Una historia de Hacker News.
public struct HNStory: Sendable, Identifiable, Equatable {
    public let id: Int
    public let title: String
    public let url: String?
    public let score: Int
    public let comments: Int
    public let author: String

    /// Enlace a abrir: el artículo enlazado o, si es una "Ask HN" sin URL, el hilo.
    public var openURL: String { url ?? "https://news.ycombinator.com/item?id=\(id)" }
    public var commentsURL: String { "https://news.ycombinator.com/item?id=\(id)" }
}

/// Obtiene las historias top de Hacker News (API pública de Firebase, sin auth).
public actor HackerNewsService {
    public static let shared = HackerNewsService()

    private var cache: [HNStory] = []
    private var lastFetch: Date?
    private let ttl: TimeInterval = 60 * 15   // 15 min
    private var allIDs: [Int] = []   // lista completa de IDs para paginar

    public init() {}

    /// Página de historias para la vista ampliada. `page` empieza en 1. Cachea la
    /// lista completa de IDs (hasta 500 de la API) y descarga el lote pedido.
    public func page(_ page: Int, pageSize: Int = 30) async -> [HNStory] {
        if allIDs.isEmpty {
            if let url = URL(string: "https://hacker-news.firebaseio.com/v0/topstories.json"),
               let (data, _) = try? await URLSession.shared.data(from: url),
               let ids = try? JSONDecoder().decode([Int].self, from: data) {
                allIDs = ids
            } else {
                return []
            }
        }
        let start = (page - 1) * pageSize
        guard start < allIDs.count else { return [] }
        let slice = Array(allIDs[start..<min(start + pageSize, allIDs.count)])
        return await Self.fetchItems(slice)
    }

    private static func fetchItems(_ ids: [Int]) async -> [HNStory] {
        await withTaskGroup(of: (Int, HNStory?).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask { (index, await fetchItem(id)) }
            }
            var buffer: [(Int, HNStory)] = []
            for await (index, story) in group {
                if let story { buffer.append((index, story)) }
            }
            return buffer.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    public func topStories(limit: Int = 10) async -> [HNStory] {
        if let lastFetch, Date().timeIntervalSince(lastFetch) < ttl, !cache.isEmpty {
            return Array(cache.prefix(limit))
        }
        guard let idsURL = URL(string: "https://hacker-news.firebaseio.com/v0/topstories.json"),
              let (data, _) = try? await URLSession.shared.data(from: idsURL),
              let ids = try? JSONDecoder().decode([Int].self, from: data) else {
            return cache
        }
        let topIDs = Array(ids.prefix(max(limit, 30)))
        // Descarga los ítems en paralelo, preservando el orden.
        let stories: [HNStory] = await withTaskGroup(of: (Int, HNStory?).self) { group in
            for (index, id) in topIDs.enumerated() {
                group.addTask { (index, await Self.fetchItem(id)) }
            }
            var buffer: [(Int, HNStory)] = []
            for await (index, story) in group {
                if let story { buffer.append((index, story)) }
            }
            return buffer.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        if !stories.isEmpty {
            cache = stories
            lastFetch = Date()
        }
        return Array(stories.prefix(limit))
    }

    private static func fetchItem(_ id: Int) async -> HNStory? {
        guard let url = URL(string: "https://hacker-news.firebaseio.com/v0/item/\(id).json"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let item = try? JSONDecoder().decode(HNItem.self, from: data),
              let title = item.title else { return nil }
        return HNStory(id: item.id, title: title, url: item.url,
                       score: item.score ?? 0, comments: item.descendants ?? 0,
                       author: item.by ?? "")
    }
}

private struct HNItem: Decodable {
    let id: Int
    let title: String?
    let url: String?
    let score: Int?
    let descendants: Int?
    let by: String?
}

// MARK: - Juegos gratis (GamerPower)

/// Un juego que está gratis temporalmente (Steam, Epic, GOG, itch.io…).
public struct FreeGame: Sendable, Identifiable, Equatable {
    public let id: Int
    public let title: String
    public let worth: String?          // valor original ("$6.99") o nil si "N/A"
    public let thumbnail: String?
    public let platforms: String
    public let url: String
    public let endDate: String?        // fecha de fin legible o nil si "N/A"
}

/// Obtiene juegos gratis (giveaways) vía la API abierta de GamerPower.
public actor FreeGamesService {
    public static let shared = FreeGamesService()

    private var cache: [FreeGame] = []
    private var lastFetch: Date?
    private let ttl: TimeInterval = 60 * 60   // 1 h

    public init() {}

    public func giveaways(limit: Int = 12) async -> [FreeGame] {
        if let lastFetch, Date().timeIntervalSince(lastFetch) < ttl, !cache.isEmpty {
            return Array(cache.prefix(limit))
        }
        guard let url = URL(string: "https://www.gamerpower.com/api/giveaways?type=game&sort-by=popularity") else {
            return cache
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let items = try? JSONDecoder().decode([GamerPowerGiveaway].self, from: data) else {
            return cache
        }
        let games = items.map { item -> FreeGame in
            FreeGame(
                id: item.id,
                title: item.title,
                worth: (item.worth == "N/A" || item.worth == nil) ? nil : item.worth,
                thumbnail: item.thumbnail,
                platforms: item.platforms ?? "",
                url: item.open_giveaway_url,
                endDate: (item.end_date == "N/A" || item.end_date == nil) ? nil : item.end_date
            )
        }
        cache = games
        lastFetch = Date()
        return Array(games.prefix(limit))
    }

    /// La API de GamerPower no pagina: la página 1 trae toda la lista de juegos
    /// gratis disponibles; el resto de páginas no devuelve nada.
    public func page(_ page: Int) async -> [FreeGame] {
        page == 1 ? await giveaways(limit: 500) : []
    }
}

private struct GamerPowerGiveaway: Decodable {
    let id: Int
    let title: String
    let worth: String?
    let thumbnail: String?
    let platforms: String?
    let open_giveaway_url: String
    let end_date: String?
}

// MARK: - Steam: novedades y top ventas (featuredcategories)

/// Qué destacado de Steam mostrar.
public enum SteamSpotlightKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case topSellers = "top_sellers"
    case newReleases = "new_releases"
    case specials = "specials"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .topSellers: "Top ventas"
        case .newReleases: "Novedades"
        case .specials: "Ofertas destacadas"
        }
    }
}

/// Un juego destacado de la tienda de Steam.
public struct SteamSpotlightItem: Sendable, Identifiable, Equatable {
    public let id: Int                  // appID
    public let name: String
    public let discountPercent: Int
    public let finalPriceCents: Int
    public let originalPriceCents: Int
    public let currency: String
    public let image: String?

    public var url: String { "https://store.steampowered.com/app/\(id)" }
    public var isFree: Bool { finalPriceCents == 0 }
    public var priceText: String {
        guard !isFree else { return "Gratis" }
        return String(format: "%.2f %@", Double(finalPriceCents) / 100, currency)
    }
}

/// Obtiene los destacados de la tienda de Steam (API pública featuredcategories).
public actor SteamSpotlightService {
    public static let shared = SteamSpotlightService()

    private var cache: [SteamSpotlightItem] = []
    private var cachedKind: SteamSpotlightKind?
    private var lastFetch: Date?
    private let ttl: TimeInterval = 60 * 30   // 30 min

    public init() {}

    public func items(kind: SteamSpotlightKind, limit: Int = 12) async -> [SteamSpotlightItem] {
        if let lastFetch, cachedKind == kind, Date().timeIntervalSince(lastFetch) < ttl, !cache.isEmpty {
            return Array(cache.prefix(limit))
        }
        guard let url = URL(string: "https://store.steampowered.com/api/featuredcategories?cc=us&l=en") else {
            return cachedKind == kind ? cache : []
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONDecoder().decode(SteamFeatured.self, from: data) else {
            return cachedKind == kind ? cache : []
        }
        let category: SteamFeatured.Category?
        switch kind {
        case .topSellers: category = root.top_sellers
        case .newReleases: category = root.new_releases
        case .specials: category = root.specials
        }
        let items = (category?.items ?? []).map { item in
            SteamSpotlightItem(
                id: item.id, name: item.name,
                discountPercent: item.discount_percent ?? 0,
                finalPriceCents: item.final_price ?? 0,
                originalPriceCents: item.original_price ?? 0,
                currency: item.currency ?? "USD",
                image: item.large_capsule_image ?? item.header_image
            )
        }
        if !items.isEmpty {
            cache = items
            cachedKind = kind
            lastFetch = Date()
        }
        return Array(items.prefix(limit))
    }

    /// La API featuredcategories no pagina: la página 1 trae toda la categoría.
    public func page(_ page: Int, kind: SteamSpotlightKind) async -> [SteamSpotlightItem] {
        page == 1 ? await items(kind: kind, limit: 500) : []
    }
}

private struct SteamFeatured: Decodable {
    let specials: Category?
    let top_sellers: Category?
    let new_releases: Category?
    struct Category: Decodable { let items: [Item]? }
    struct Item: Decodable {
        let id: Int
        let name: String
        let discount_percent: Int?
        let original_price: Int?
        let final_price: Int?
        let currency: String?
        let large_capsule_image: String?
        let header_image: String?
    }
}

// MARK: - Artículos de desarrollo (dev.to)

/// Un artículo de la comunidad dev.to.
public struct DevArticle: Sendable, Identifiable, Equatable {
    public let id: Int
    public let title: String
    public let url: String
    public let coverImage: String?
    public let reactions: Int
    public let comments: Int
    public let readingMinutes: Int
    public let tags: [String]
    public let author: String
}

/// Obtiene artículos técnicos recientes y populares de dev.to (API abierta).
public actor DevArticlesService {
    public static let shared = DevArticlesService()

    private var cache: [DevArticle] = []
    private var lastFetch: Date?
    private let ttl: TimeInterval = 60 * 20   // 20 min

    public init() {}

    public func articles(limit: Int = 12) async -> [DevArticle] {
        if let lastFetch, Date().timeIntervalSince(lastFetch) < ttl, !cache.isEmpty {
            return Array(cache.prefix(limit))
        }
        var components = URLComponents(string: "https://dev.to/api/articles")!
        components.queryItems = [
            URLQueryItem(name: "per_page", value: "\(max(limit, 12))"),
            URLQueryItem(name: "top", value: "7")   // lo más popular de la última semana
        ]
        guard let url = components.url else { return cache }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let items = try? JSONDecoder().decode([DevToArticle].self, from: data) else {
            return cache
        }
        let articles = items.map { item in
            DevArticle(
                id: item.id, title: item.title, url: item.url,
                coverImage: item.cover_image ?? item.social_image,
                reactions: item.positive_reactions_count ?? 0,
                comments: item.comments_count ?? 0,
                readingMinutes: item.reading_time_minutes ?? 1,
                tags: item.tag_list ?? [],
                author: item.user?.name ?? ""
            )
        }
        cache = articles
        lastFetch = Date()
        return Array(articles.prefix(limit))
    }

    /// Página de artículos para la vista ampliada. `page` empieza en 1 (dev.to
    /// usa `page` 1-based). Devuelve [] cuando no hay más.
    public func page(_ page: Int, pageSize: Int = 30) async -> [DevArticle] {
        var components = URLComponents(string: "https://dev.to/api/articles")!
        components.queryItems = [
            URLQueryItem(name: "per_page", value: "\(pageSize)"),
            URLQueryItem(name: "page", value: "\(max(page, 1))"),
            URLQueryItem(name: "top", value: "30")
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let items = try? JSONDecoder().decode([DevToArticle].self, from: data) else {
            return []
        }
        return items.map { item in
            DevArticle(
                id: item.id, title: item.title, url: item.url,
                coverImage: item.cover_image ?? item.social_image,
                reactions: item.positive_reactions_count ?? 0,
                comments: item.comments_count ?? 0,
                readingMinutes: item.reading_time_minutes ?? 1,
                tags: item.tag_list ?? [], author: item.user?.name ?? "")
        }
    }
}

private struct DevToArticle: Decodable {
    let id: Int
    let title: String
    let url: String
    let cover_image: String?
    let social_image: String?
    let positive_reactions_count: Int?
    let comments_count: Int?
    let reading_time_minutes: Int?
    let tag_list: [String]?
    let user: User?
    struct User: Decodable { let name: String? }
}
