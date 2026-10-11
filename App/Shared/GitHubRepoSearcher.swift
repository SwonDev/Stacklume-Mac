import Foundation
import StacklumeDesignSystem
import SwiftUI

/// Un repositorio devuelto por la búsqueda de GitHub (API pública `search/repositories`,
/// SIN token — coherente con la filosofía «sin claves» de la app). Solo lectura de metadatos.
struct GitHubRepo: Identifiable, Sendable, Decodable {
    let id: Int
    /// «owner/repo».
    let fullName: String
    let htmlURL: String
    let description: String?
    let stars: Int
    let forks: Int
    let language: String?
    let ownerAvatarURL: String?
    let topics: [String]
    let updatedAt: Date?
    let openIssues: Int
    let licenseName: String?
    let isArchived: Bool

    enum CodingKeys: String, CodingKey {
        case id, description, forks, language, topics, owner, license
        case fullName = "full_name"
        case htmlURL = "html_url"
        case stars = "stargazers_count"
        case updatedAt = "updated_at"
        case openIssues = "open_issues_count"
        case isArchived = "archived"
    }
    private enum OwnerKeys: String, CodingKey { case avatarURL = "avatar_url" }
    private enum LicenseKeys: String, CodingKey { case name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        fullName = try c.decode(String.self, forKey: .fullName)
        htmlURL = try c.decode(String.self, forKey: .htmlURL)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        stars = try c.decodeIfPresent(Int.self, forKey: .stars) ?? 0
        forks = try c.decodeIfPresent(Int.self, forKey: .forks) ?? 0
        language = try c.decodeIfPresent(String.self, forKey: .language)
        topics = try c.decodeIfPresent([String].self, forKey: .topics) ?? []
        openIssues = try c.decodeIfPresent(Int.self, forKey: .openIssues) ?? 0
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
        // `owner` y `license` son objetos anidados (o `null`): se leen con tolerancia.
        if let owner = try? c.nestedContainer(keyedBy: OwnerKeys.self, forKey: .owner) {
            ownerAvatarURL = try owner.decodeIfPresent(String.self, forKey: .avatarURL)
        } else {
            ownerAvatarURL = nil
        }
        if let license = try? c.nestedContainer(keyedBy: LicenseKeys.self, forKey: .license) {
            licenseName = try license.decodeIfPresent(String.self, forKey: .name)
        } else {
            licenseName = nil
        }
    }
}

/// Cliente de la búsqueda de repositorios de GitHub. API pública, sin token: GitHub limita a
/// ~10 búsquedas/minuto sin autenticar, de sobra para una búsqueda puntual desde un tweet.
/// Mismo estilo de cabeceras y manejo de estados que [[ExternalImport]] (que ya consume la API).
enum GitHubRepoSearcher {
    enum SearchError: LocalizedError {
        case emptyQuery, rateLimited, network

        var errorDescription: String? {
            switch self {
            case .emptyQuery:  "Escribe algo que buscar en GitHub."
            case .rateLimited: "GitHub limitó las búsquedas; espera un momento e inténtalo de nuevo."
            case .network:     "No se pudo conectar con GitHub. Revisa tu conexión."
            }
        }
    }

    /// Busca repositorios que coincidan con `rawQuery`, ordenados por estrellas (descendente).
    static func search(_ rawQuery: String, limit: Int = 30) async throws -> [GitHubRepo] {
        let query = cleanQuery(rawQuery)
        guard !query.isEmpty else { throw SearchError.emptyQuery }
        let safeLimit = min(max(limit, 1), 100)

        // URLComponents codifica correctamente el valor de `q` (espacios, &, =, etc.).
        guard var comps = URLComponents(string: "https://api.github.com/search/repositories") else {
            throw SearchError.network
        }
        comps.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "sort", value: "stars"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "per_page", value: String(safeLimit)),
        ]
        guard let url = comps.url else { throw SearchError.network }

        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Stacklume/1.0 (macOS; bookmark manager)", forHTTPHeaderField: "User-Agent")

        let result: ExternalHTTPResponse
        do {
            result = try await ExternalHTTPClient.shared.data(
                for: req,
                maximumBytes: 8 * 1_024 * 1_024,
                acceptedStatusCodes: 200...499,
                allowedMIMEPrefixes: ["application/json"]
            )
        } catch {
            throw SearchError.network
        }
        switch result.response.statusCode {
        case 200..<300: break
        case 403, 429:  throw SearchError.rateLimited
        default:        throw SearchError.network
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let parsed = try? decoder.decode(SearchResponse.self, from: result.data) else {
            throw SearchError.network
        }
        return parsed.items
    }

    /// Convierte un texto seleccionado cualquiera (de un tweet) en una consulta útil: colapsa
    /// saltos/espacios, quita URLs y los símbolos `@`/`#` (conservando la palabra) y recorta a una
    /// longitud razonable. GitHub admite texto libre, así que no hace falta más.
    static func cleanQuery(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[@#]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 128 { s = String(s.prefix(128)).trimmingCharacters(in: .whitespaces) }
        return s
    }

    private struct SearchResponse: Decodable { let items: [GitHubRepo] }
}

/// Color representativo del lenguaje (aprox. al de GitHub) para el puntito junto al nombre.
enum GitHubLanguage {
    static func color(for name: String?) -> Color {
        switch (name ?? "").lowercased() {
        case "swift":                 Color(hex: "#F05138")
        case "javascript":            Color(hex: "#F1E05A")
        case "typescript":            Color(hex: "#3178C6")
        case "python":                Color(hex: "#3572A5")
        case "rust":                  Color(hex: "#DEA584")
        case "go":                    Color(hex: "#00ADD8")
        case "java":                  Color(hex: "#B07219")
        case "kotlin":                Color(hex: "#A97BFF")
        case "c", "c++":              Color(hex: "#555555")
        case "c#":                    Color(hex: "#178600")
        case "ruby":                  Color(hex: "#701516")
        case "php":                   Color(hex: "#4F5D95")
        case "shell":                 Color(hex: "#89E051")
        case "html":                  Color(hex: "#E34C26")
        case "css", "scss":           Color(hex: "#563D7C")
        case "dart":                  Color(hex: "#00B4AB")
        case "objective-c", "objective-c++": Color(hex: "#438EFF")
        default:                       Color(hex: "#8B949E")
        }
    }
}
