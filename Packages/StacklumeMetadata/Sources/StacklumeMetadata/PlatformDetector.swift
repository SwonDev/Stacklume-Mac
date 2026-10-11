import Foundation
import StacklumeCore

/// Resultado de la detección de plataforma de una URL.
public struct PlatformDetection: Sendable, Equatable {
    public var platform: Platform
    public var contentType: ContentType
    public var brandColorHex: String
    /// Miniatura directa cuando la plataforma la expone (p. ej. YouTube).
    public var directThumbnailURL: String?
}

/// Detecta la plataforma y el tipo de contenido a partir de la URL (equivalente
/// a `platform-detection.ts` del original).
public enum PlatformDetector {

    public static func detect(_ urlString: String) -> PlatformDetection {
        let host = normalizedHost(of: urlString)

        for rule in rules where rule.matches(host) {
            var thumb: String?
            switch rule.platform {
            case .youtube:
                if let id = youTubeID(from: urlString) {
                    thumb = "https://img.youtube.com/vi/\(id)/hqdefault.jpg"
                }
            case .github:
                if let slug = gitHubSlug(from: urlString) {
                    thumb = "https://opengraph.githubassets.com/1/\(slug)"
                }
            case .steam:
                if let appID = steamAppID(from: urlString) {
                    thumb = "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/header.jpg"
                }
            default:
                break
            }
            return PlatformDetection(
                platform: rule.platform,
                contentType: rule.contentType,
                brandColorHex: rule.platform.brandColorHex,
                directThumbnailURL: thumb
            )
        }

        return PlatformDetection(platform: .generic, contentType: .website,
                                 brandColorHex: Platform.generic.brandColorHex,
                                 directThumbnailURL: nil)
    }

    // MARK: - Reglas

    private struct Rule {
        let needles: [String]
        let platform: Platform
        let contentType: ContentType
        func matches(_ host: String) -> Bool {
            needles.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }

    private static let rules: [Rule] = [
        Rule(needles: ["youtube.com", "youtu.be"], platform: .youtube, contentType: .video),
        Rule(needles: ["vimeo.com"], platform: .vimeo, contentType: .video),
        Rule(needles: ["twitch.tv"], platform: .twitch, contentType: .video),
        Rule(needles: ["netflix.com"], platform: .netflix, contentType: .video),
        Rule(needles: ["store.steampowered.com", "steampowered.com", "steamcommunity.com"], platform: .steam, contentType: .game),
        Rule(needles: ["epicgames.com"], platform: .epic, contentType: .game),
        Rule(needles: ["gog.com"], platform: .gog, contentType: .game),
        Rule(needles: ["itch.io"], platform: .itch, contentType: .game),
        Rule(needles: ["open.spotify.com", "spotify.com"], platform: .spotify, contentType: .music),
        Rule(needles: ["soundcloud.com"], platform: .soundcloud, contentType: .music),
        Rule(needles: ["music.apple.com"], platform: .appleMusic, contentType: .music),
        Rule(needles: ["github.com"], platform: .github, contentType: .code),
        Rule(needles: ["gitlab.com"], platform: .gitlab, contentType: .code),
        Rule(needles: ["bitbucket.org"], platform: .bitbucket, contentType: .code),
        Rule(needles: ["codepen.io"], platform: .codepen, contentType: .code),
        Rule(needles: ["stackoverflow.com"], platform: .stackoverflow, contentType: .code),
        Rule(needles: ["news.ycombinator.com"], platform: .hackerNews, contentType: .article),
        Rule(needles: ["npmjs.com"], platform: .npm, contentType: .code),
        Rule(needles: ["pypi.org"], platform: .pypi, contentType: .code),
        Rule(needles: ["twitter.com", "x.com"], platform: .twitter, contentType: .social),
        Rule(needles: ["reddit.com"], platform: .reddit, contentType: .social),
        Rule(needles: ["instagram.com"], platform: .instagram, contentType: .social),
        Rule(needles: ["tiktok.com"], platform: .tiktok, contentType: .social),
        Rule(needles: ["linkedin.com"], platform: .linkedin, contentType: .social),
        Rule(needles: ["facebook.com"], platform: .facebook, contentType: .social),
        Rule(needles: ["pinterest.com"], platform: .pinterest, contentType: .design),
        Rule(needles: ["dribbble.com"], platform: .dribbble, contentType: .design),
        Rule(needles: ["behance.net"], platform: .behance, contentType: .design),
        Rule(needles: ["figma.com"], platform: .figma, contentType: .design),
        Rule(needles: ["notion.so", "notion.site"], platform: .notion, contentType: .document),
        Rule(needles: ["docs.google.com"], platform: .googleDocs, contentType: .document),
        Rule(needles: ["drive.google.com"], platform: .googleDrive, contentType: .document),
        Rule(needles: ["dropbox.com"], platform: .dropbox, contentType: .document),
        Rule(needles: ["amazon.com", "amazon.es"], platform: .amazon, contentType: .commerce),
        Rule(needles: ["ebay.com", "ebay.es"], platform: .ebay, contentType: .commerce),
        Rule(needles: ["etsy.com"], platform: .etsy, contentType: .commerce),
        Rule(needles: ["medium.com"], platform: .medium, contentType: .article),
        Rule(needles: ["dev.to"], platform: .devto, contentType: .article),
        Rule(needles: ["hashnode.com", "hashnode.dev"], platform: .hashnode, contentType: .article),
        Rule(needles: ["wikipedia.org"], platform: .wikipedia, contentType: .article),
        Rule(needles: ["apps.apple.com", "itunes.apple.com"], platform: .appStore, contentType: .website)
    ]

    /// ID numérico de una app de la App Store (apps.apple.com/.../id123456789).
    static func appStoreID(from urlString: String) -> String? {
        let value = urlString.contains("://") ? urlString : "https://" + urlString
        guard let url = URL(string: value) else { return nil }
        // El id viene como componente "id123456789" o como query ?id=...
        for part in url.pathComponents where part.lowercased().hasPrefix("id") {
            let digits = part.dropFirst(2)
            if !digits.isEmpty, digits.allSatisfy(\.isNumber) { return String(digits) }
        }
        if let items = URLComponents(string: value)?.queryItems,
           let id = items.first(where: { $0.name == "id" })?.value, Int(id) != nil {
            return id
        }
        return nil
    }

    /// ID de un tweet/post (twitter.com|x.com/<user>/status/<id>).
    static func tweetID(from urlString: String) -> String? {
        let value = urlString.contains("://") ? urlString : "https://" + urlString
        guard let url = URL(string: value) else { return nil }
        let parts = url.pathComponents
        if let idx = parts.firstIndex(where: { $0 == "status" || $0 == "statuses" }),
           idx + 1 < parts.count {
            let id = parts[idx + 1].prefix { $0.isNumber }
            if !id.isEmpty { return String(id) }
        }
        return nil
    }

    /// Handle (@usuario) de una URL de Twitter/X.
    static func twitterHandle(from urlString: String) -> String? {
        let value = urlString.contains("://") ? urlString : "https://" + urlString
        guard let url = URL(string: value) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let reserved: Set<String> = ["i", "home", "search", "explore", "notifications", "messages", "hashtag"]
        guard let first = parts.first, !reserved.contains(first.lowercased()) else { return nil }
        return first
    }

    // MARK: - Utilidades

    static func normalizedHost(of urlString: String) -> String {
        var value = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains("://") { value = "https://" + value }
        guard let host = URL(string: value)?.host()?.lowercased() else {
            return urlString.lowercased()
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// "owner/repo" de una URL de GitHub.
    static func gitHubSlug(from urlString: String) -> String? {
        let value = urlString.contains("://") ? urlString : "https://" + urlString
        guard let url = URL(string: value) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        let reserved: Set<String> = ["features", "about", "pricing", "marketplace", "topics", "sponsors", "settings"]
        guard !reserved.contains(parts[0].lowercased()) else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    /// App ID de una URL de Steam (store.steampowered.com/app/NNNN).
    static func steamAppID(from urlString: String) -> String? {
        let value = urlString.contains("://") ? urlString : "https://" + urlString
        guard let url = URL(string: value) else { return nil }
        let parts = url.pathComponents
        if let idx = parts.firstIndex(where: { $0 == "app" }), idx + 1 < parts.count,
           Int(parts[idx + 1]) != nil {
            return parts[idx + 1]
        }
        return nil
    }

    static func youTubeID(from urlString: String) -> String? {
        guard let url = URL(string: urlString.contains("://") ? urlString : "https://" + urlString) else {
            return nil
        }
        let host = (url.host() ?? "").lowercased()
        if host.contains("youtu.be") {
            let id = url.lastPathComponent
            return id.isEmpty ? nil : id
        }
        if host.contains("youtube.com") {
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let v = comps.queryItems?.first(where: { $0.name == "v" })?.value {
                return v
            }
            // formatos /shorts/ID o /embed/ID
            let parts = url.pathComponents
            if let idx = parts.firstIndex(where: { $0 == "shorts" || $0 == "embed" }),
               idx + 1 < parts.count {
                return parts[idx + 1]
            }
        }
        return nil
    }

    /// ID de un ítem de Hacker News (news.ycombinator.com/item?id=NNNN).
    static func hackerNewsID(from urlString: String) -> String? {
        let value = urlString.contains("://") ? urlString : "https://" + urlString
        guard let items = URLComponents(string: value)?.queryItems,
              let id = items.first(where: { $0.name == "id" })?.value, Int(id) != nil else { return nil }
        return id
    }

    /// Nombre del paquete npm (npmjs.com/package/<nombre>, admite scopes @org/pkg).
    static func npmPackage(from urlString: String) -> String? {
        let value = urlString.contains("://") ? urlString : "https://" + urlString
        guard let url = URL(string: value) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let idx = parts.firstIndex(of: "package"), idx + 1 < parts.count else { return nil }
        let rest = parts[(idx + 1)...]
        // Paquete con scope: @org/pkg ocupa dos componentes.
        if let first = rest.first, first.hasPrefix("@"), rest.count >= 2 {
            return "\(first)/\(rest[rest.index(after: rest.startIndex)])"
        }
        return rest.first
    }

    /// Nombre del paquete PyPI (pypi.org/project/<nombre>/).
    static func pypiPackage(from urlString: String) -> String? {
        let value = urlString.contains("://") ? urlString : "https://" + urlString
        guard let url = URL(string: value) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let idx = parts.firstIndex(of: "project"), idx + 1 < parts.count else { return nil }
        return parts[idx + 1]
    }

    /// Subreddit de una URL de Reddit (reddit.com/r/<sub>/…).
    static func subreddit(from urlString: String) -> String? {
        let value = urlString.contains("://") ? urlString : "https://" + urlString
        guard let url = URL(string: value) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let idx = parts.firstIndex(where: { $0.lowercased() == "r" }), idx + 1 < parts.count else { return nil }
        return parts[idx + 1]
    }
}
