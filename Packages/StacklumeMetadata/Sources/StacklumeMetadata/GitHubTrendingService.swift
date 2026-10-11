import Foundation

/// Un repositorio en tendencia de GitHub.
public struct TrendingRepo: Sendable, Identifiable, Equatable {
    public var id: String { fullName }
    public let fullName: String
    public let description: String
    public let url: String
    public let stars: Int
    public let language: String?
    public let avatarURL: String?

    public var starsText: String {
        if stars >= 1000 { return String(format: "%.1fk", Double(stars) / 1000) }
        return "\(stars)"
    }
}

/// Obtiene repos en tendencia vía la API de búsqueda OFICIAL de GitHub (sin auth):
/// repos creados en los últimos 7 días, ordenados por estrellas. Cachea el
/// resultado en memoria un rato para no agotar el límite de peticiones.
public actor GitHubTrendingService {
    public static let shared = GitHubTrendingService()

    private var cache: [TrendingRepo] = []
    private var lastFetch: Date?
    private let ttl: TimeInterval = 60 * 30   // 30 min

    public init() {}

    /// Devuelve la tendencia (cacheada si es reciente). `since` es la fecha umbral
    /// «creado después de» en formato yyyy-MM-dd (se calcula fuera para no usar
    /// Date() dentro del actor de forma implícita).
    public func trending(since: String, limit: Int = 12) async -> [TrendingRepo] {
        if let lastFetch, Date().timeIntervalSince(lastFetch) < ttl, !cache.isEmpty {
            return Array(cache.prefix(limit))
        }
        var components = URLComponents(string: "https://api.github.com/search/repositories")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "created:>\(since) stars:>50"),
            URLQueryItem(name: "sort", value: "stars"),
            URLQueryItem(name: "order", value: "desc"),
            // Descargamos un lote grande para que la vista ampliada tenga muchos
            // más repos que el vistazo compacto (una sola petición sirve a ambos).
            URLQueryItem(name: "per_page", value: "\(max(limit, 50))")
        ]
        guard let url = components.url else { return cache }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Stacklume", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try? JSONDecoder().decode(SearchResult.self, from: data) else {
            return cache   // ante un fallo, conserva lo último que tuviéramos
        }
        let repos = result.items.map {
            TrendingRepo(fullName: $0.full_name, description: $0.description ?? "",
                         url: $0.html_url, stars: $0.stargazers_count,
                         language: $0.language, avatarURL: $0.owner?.avatar_url)
        }
        cache = repos
        lastFetch = Date()
        return Array(repos.prefix(limit))
    }

    /// Página de repos para la vista ampliada (scroll infinito). `page` empieza en
    /// 1 (la API de GitHub es 1-based). `since` = fecha umbral yyyy-MM-dd.
    public func page(_ page: Int, since: String, pageSize: Int = 50) async -> [TrendingRepo] {
        var components = URLComponents(string: "https://api.github.com/search/repositories")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "created:>\(since) stars:>50"),
            URLQueryItem(name: "sort", value: "stars"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "per_page", value: "\(pageSize)"),
            URLQueryItem(name: "page", value: "\(max(page, 1))")
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Stacklume", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try? JSONDecoder().decode(SearchResult.self, from: data) else {
            return []
        }
        return result.items.map {
            TrendingRepo(fullName: $0.full_name, description: $0.description ?? "",
                         url: $0.html_url, stars: $0.stargazers_count,
                         language: $0.language, avatarURL: $0.owner?.avatar_url)
        }
    }
}

private struct SearchResult: Decodable {
    let items: [Item]
    struct Item: Decodable {
        let full_name: String
        let description: String?
        let html_url: String
        let stargazers_count: Int
        let language: String?
        let owner: Owner?
        struct Owner: Decodable { let avatar_url: String? }
    }
}
