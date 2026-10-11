import Foundation

/// Una app/juego de la App Store con su precio actual (API oficial de Apple).
public struct AppStoreApp: Sendable, Identifiable, Equatable {
    public var id: Int { trackId }
    public let trackId: Int
    public let name: String
    public let artist: String
    public let genre: String
    public let isGame: Bool
    public let artworkURL: String?
    public let url: String
    public let price: Double
    public let currency: String
}

/// Consulta la API pública oficial de Apple (iTunes Search/Lookup + RSS de
/// Marketing Tools) para sembrar y refrescar precios de apps/juegos de pago.
/// No detecta ofertas por sí sola: solo da el precio actual; la detección de
/// bajadas la hace la capa de persistencia comparando con el historial guardado.
public actor iTunesPriceService {
    public static let shared = iTunesPriceService()
    public init() {}

    /// IDs de las apps de pago más populares (top-paid) para sembrar la lista de
    /// seguimiento. Mezcla apps y juegos. `country` es el código de tienda (us, es…).
    public func topPaidIDs(country: String, limit: Int = 100) async -> [Int] {
        let cc = country.lowercased()
        let clamped = min(max(limit, 10), 200)
        guard let url = URL(string: "https://rss.applemarketingtools.com/api/v2/\(cc)/apps/top-paid/\(clamped)/apps.json") else {
            return []
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let feed = try? JSONDecoder().decode(RSSFeed.self, from: data) else {
            return []
        }
        return feed.feed.results.compactMap { Int($0.id) }
    }

    /// IDs de los JUEGOS de pago más populares (RSS legacy de Apple, género 6014),
    /// para que el filtro «Juegos» tenga contenido (el top-paid general apenas trae).
    public func topPaidGameIDs(country: String, limit: Int = 100) async -> [Int] {
        let cc = country.lowercased()
        let clamped = min(max(limit, 10), 200)
        guard let url = URL(string: "https://itunes.apple.com/\(cc)/rss/toppaidapplications/limit=\(clamped)/genre=6014/json") else {
            return []
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let feed = try? JSONDecoder().decode(LegacyFeed.self, from: data) else {
            return []
        }
        return feed.feed.entry?.compactMap { Int($0.id.attributes.imID) } ?? []
    }

    /// Precio actual de un conjunto de apps por su trackId (iTunes Lookup, en
    /// lotes de 100). Solo devuelve resultados de software (apps).
    public func lookup(ids: [Int], country: String) async -> [AppStoreApp] {
        guard !ids.isEmpty else { return [] }
        let cc = country.lowercased()
        var out: [AppStoreApp] = []
        for chunk in stride(from: 0, to: ids.count, by: 100) {
            let slice = ids[chunk..<min(chunk + 100, ids.count)]
            let idList = slice.map(String.init).joined(separator: ",")
            var components = URLComponents(string: "https://itunes.apple.com/lookup")!
            components.queryItems = [
                URLQueryItem(name: "id", value: idList),
                URLQueryItem(name: "country", value: cc)
            ]
            guard let url = components.url else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let result = try? JSONDecoder().decode(LookupResult.self, from: data) else {
                continue
            }
            out.append(contentsOf: result.results.compactMap(Self.map))
        }
        return out
    }

    /// Busca apps/juegos por término para añadir manualmente al seguimiento.
    public func search(term: String, country: String, limit: Int = 25) async -> [AppStoreApp] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "country", value: country.lowercased()),
            URLQueryItem(name: "media", value: "software"),
            URLQueryItem(name: "limit", value: "\(min(max(limit, 1), 50))")
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try? JSONDecoder().decode(LookupResult.self, from: data) else {
            return []
        }
        return result.results.compactMap(Self.map)
    }

    private static func map(_ item: LookupItem) -> AppStoreApp? {
        guard item.wrapperType == "software" || item.kind == "software",
              let trackId = item.trackId, let name = item.trackName,
              let price = item.price, let url = item.trackViewUrl else { return nil }
        let isGame = item.primaryGenreId == 6014 || (item.primaryGenreName == "Games")
        // Artwork a mayor resolución si está disponible.
        let art = item.artworkUrl512 ?? item.artworkUrl100 ?? item.artworkUrl60
        return AppStoreApp(
            trackId: trackId, name: name, artist: item.artistName ?? "",
            genre: item.primaryGenreName ?? "", isGame: isGame,
            artworkURL: art, url: url, price: price,
            currency: item.currency ?? "USD"
        )
    }
}

// MARK: - Decodables

private struct RSSFeed: Decodable {
    let feed: Feed
    struct Feed: Decodable { let results: [Item] }
    struct Item: Decodable { let id: String }
}

/// Feed RSS legacy de Apple (toppaidapplications), usado para juegos por género.
private struct LegacyFeed: Decodable {
    let feed: Feed
    struct Feed: Decodable { let entry: [Entry]? }
    struct Entry: Decodable { let id: EntryID }
    struct EntryID: Decodable { let attributes: Attributes }
    struct Attributes: Decodable {
        let imID: String
        enum CodingKeys: String, CodingKey { case imID = "im:id" }
    }
}

private struct LookupResult: Decodable {
    let results: [LookupItem]
}

private struct LookupItem: Decodable {
    let wrapperType: String?
    let kind: String?
    let trackId: Int?
    let trackName: String?
    let artistName: String?
    let primaryGenreName: String?
    let primaryGenreId: Int?
    let price: Double?
    let currency: String?
    let trackViewUrl: String?
    let artworkUrl60: String?
    let artworkUrl100: String?
    let artworkUrl512: String?
}
