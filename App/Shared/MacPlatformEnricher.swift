import Foundation
import StacklumeCore
import StacklumeMetadata

/// Enriquecimiento específico por plataforma: datos en vivo de repositorios de
/// GitHub (estrellas, forks, lenguaje) vía la API pública, y contenido de tweets
/// de X/Twitter vía oEmbed. Ambos sin autenticación (aptos para App Store).
@MainActor
enum MacPlatformEnricher {

    /// Aplica el enriquecimiento adecuado según la plataforma del enlace.
    static func enrich(_ bookmark: Bookmark) async {
        switch bookmark.platform {
        case .github: await enrichGitHub(bookmark)
        case .twitter: await enrichTweet(bookmark)
        default: break
        }
    }

    // MARK: - GitHub

    static func enrichGitHub(_ bookmark: Bookmark) async {
        guard let slug = MacMetadataURL.gitHubSlug(from: bookmark.url),
              let url = URL(string: "https://api.github.com/repos/\(slug)") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Stacklume", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12
        guard let result = try? await ExternalHTTPClient.shared.data(
            for: request, maximumBytes: 2 * 1_024 * 1_024, acceptedStatusCodes: 200...200
        ), bookmark.modelContext != nil,
              let repo = try? githubDecoder.decode(MacMetadataGitHubRepo.self, from: result.data) else { return }

        bookmark.repoInfo = RepoInfo(
            stars: repo.stargazers_count, forks: repo.forks_count,
            language: repo.language, ownerAvatarURL: repo.owner?.avatar_url,
            lastPush: repo.pushed_at)
        if bookmark.author?.isEmpty != false { bookmark.author = repo.owner?.login }
        if let description = repo.description, !description.isEmpty {
            if bookmark.details?.isEmpty != false { bookmark.details = description }
            if bookmark.summary?.isEmpty != false { bookmark.summary = description }
        }
        bookmark.updatedAt = Date()
    }

    // MARK: - Tweet / X

    static func enrichTweet(_ bookmark: Bookmark) async {
        // Handle a partir de la URL (siempre disponible aunque oEmbed falle).
        if bookmark.author?.isEmpty != false,
           let handle = MacMetadataURL.twitterHandle(from: bookmark.url) {
            bookmark.author = "@\(handle)"
        }
        guard let encoded = bookmark.url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://publish.twitter.com/oembed?omit_script=1&dnt=true&url=\(encoded)") else { return }
        var request = URLRequest(url: url)
        request.setValue("Stacklume", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        guard let result = try? await ExternalHTTPClient.shared.data(
            for: request, maximumBytes: 2 * 1_024 * 1_024, acceptedStatusCodes: 200...200
        ), bookmark.modelContext != nil,
              let oembed = try? JSONDecoder().decode(MacMetadataTweetOEmbed.self, from: result.data) else { return }

        let text = strippedTweetText(from: oembed.html)
        if !text.isEmpty {
            if bookmark.details?.isEmpty != false { bookmark.details = text }
            if bookmark.summary?.isEmpty != false { bookmark.summary = text }
            // Un buen título es el inicio del tweet si no había título real.
            let host = normalizedHost(bookmark.url)
            if bookmark.title.isEmpty || bookmark.title.lowercased() == host {
                bookmark.title = String(text.prefix(80))
            }
        }
        bookmark.updatedAt = Date()
    }

    // MARK: - Utilidades

    private static func strippedTweetText(from html: String?) -> String {
        guard let html else { return "" }
        // El texto del tweet vive en el primer <p>…</p> del blockquote.
        var body = html
        if let pStart = html.range(of: "<p"), let pEnd = html.range(of: "</p>") {
            body = String(html[pStart.lowerBound..<pEnd.lowerBound])
        }
        // <br> → salto de línea; quita el resto de etiquetas.
        body = body.replacingOccurrences(of: "<br>", with: "\n")
                   .replacingOccurrences(of: "<br/>", with: "\n")
                   .replacingOccurrences(of: "<br />", with: "\n")
        body = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Entidades HTML comunes.
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">",
                        "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&nbsp;": " "]
        for (entity, value) in entities { body = body.replacingOccurrences(of: entity, with: value) }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedHost(_ urlString: String) -> String {
        let value = urlString.contains("://") ? urlString : "https://" + urlString
        let host = URL(string: value)?.host()?.lowercased() ?? urlString.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static var githubDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - DTOs

private struct MacMetadataGitHubRepo: Decodable {
    let stargazers_count: Int
    let forks_count: Int
    let language: String?
    let description: String?
    let pushed_at: Date?
    let owner: Owner?
    struct Owner: Decodable { let login: String?; let avatar_url: String? }
}

private struct MacMetadataTweetOEmbed: Decodable {
    let author_name: String?
    let author_url: String?
    let html: String?
}
