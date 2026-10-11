import Foundation
import StacklumeCore
import StacklumeMetadata

/// Enriquecedores específicos para fuentes que no exponen Open Graph útil sin
/// autenticación (App Store, Twitter/X). Cada uno usa una API pública oficial y
/// degrada con elegancia si falla.
enum MacSpecialEnrichers {

    /// Si la URL corresponde a una fuente especial, devuelve metadatos enriquecidos.
    static func enrich(_ metadata: inout LinkMetadata, url: String) async {
        switch metadata.platform {
        case .appStore:   await enrichAppStore(&metadata, url: url)
        case .twitter:    await enrichTwitter(&metadata, url: url)
        case .youtube:    await enrichYouTube(&metadata, url: url)
        case .reddit:     enrichReddit(&metadata, url: url)
        case .hackerNews: await enrichHackerNews(&metadata, url: url)
        case .npm:        await enrichNpm(&metadata, url: url)
        case .pypi:       await enrichPyPI(&metadata, url: url)
        default:
            // Registros de paquetes sin plataforma propia (cargo/gem), resueltos
            // normalmente desde un comando `cargo add` / `gem install`.
            let host = (URL(string: url)?.host() ?? "").lowercased()
            if host.contains("crates.io") { await enrichCargo(&metadata, url: url) }
            else if host.contains("rubygems.org") { await enrichGem(&metadata, url: url) }
        }
    }

    // MARK: - crates.io (Rust)

    private static func enrichCargo(_ metadata: inout LinkMetadata, url: String) async {
        guard let name = lastPathComponent(of: url, after: "crates"),
              let endpoint = URL(string: "https://crates.io/api/v1/crates/\(name)"),
              let json = await fetchJSON(endpoint),
              let crate = json["crate"] as? [String: Any] else { return }
        if let n = crate["name"] as? String, !n.isEmpty { metadata.title = n }
        if let desc = crate["description"] as? String, !desc.isEmpty { metadata.details = desc }
        if let keywords = crate["keywords"] as? [String] { metadata.keywords = keywords }
        if let version = crate["max_stable_version"] as? String ?? crate["max_version"] as? String {
            metadata.siteName = "crates.io · v\(version)"
        } else {
            metadata.siteName = "crates.io"
        }
    }

    // MARK: - RubyGems

    private static func enrichGem(_ metadata: inout LinkMetadata, url: String) async {
        guard let name = lastPathComponent(of: url, after: "gems"),
              let endpoint = URL(string: "https://rubygems.org/api/v1/gems/\(name).json"),
              let json = await fetchJSON(endpoint) else { return }
        if let n = json["name"] as? String, !n.isEmpty { metadata.title = n }
        if let info = json["info"] as? String, !info.isEmpty { metadata.details = info }
        if let version = json["version"] as? String {
            metadata.siteName = "RubyGems · v\(version)"
        } else {
            metadata.siteName = "RubyGems"
        }
    }

    /// Último componente del path tras un segmento dado (p. ej. .../crates/<name>).
    private static func lastPathComponent(of urlString: String, after segment: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let idx = parts.firstIndex(of: segment), idx + 1 < parts.count else { return nil }
        return parts[idx + 1]
    }

    // MARK: - YouTube (oEmbed oficial — sin API key)

    private static func enrichYouTube(_ metadata: inout LinkMetadata, url: String) async {
        var components = URLComponents(string: "https://www.youtube.com/oembed")!
        components.queryItems = [URLQueryItem(name: "url", value: url),
                                 URLQueryItem(name: "format", value: "json")]
        guard let endpoint = components.url, let json = await fetchJSON(endpoint) else { return }
        if let title = json["title"] as? String, !title.isEmpty,
           metadata.title?.isEmpty != false { metadata.title = title }
        if let author = json["author_name"] as? String, !author.isEmpty { metadata.author = author }
        if let thumb = json["thumbnail_url"] as? String, !thumb.isEmpty,
           metadata.imageURL?.isEmpty != false { metadata.imageURL = thumb }
        metadata.siteName = "YouTube"
    }

    // MARK: - Reddit (subreddit a partir de la URL — sin red)

    private static func enrichReddit(_ metadata: inout LinkMetadata, url: String) {
        metadata.siteName = "Reddit"
        if let sub = MacMetadataURL.subreddit(from: url) { metadata.author = "r/\(sub)" }
    }

    // MARK: - Hacker News (Firebase API pública)

    private static func enrichHackerNews(_ metadata: inout LinkMetadata, url: String) async {
        guard let id = MacMetadataURL.hackerNewsID(from: url),
              let endpoint = URL(string: "https://hacker-news.firebaseio.com/v0/item/\(id).json"),
              let json = await fetchJSON(endpoint) else { return }
        metadata.siteName = "Hacker News"
        if let title = json["title"] as? String, !title.isEmpty { metadata.title = title }
        if let by = json["by"] as? String, !by.isEmpty { metadata.author = by }
        let score = json["score"] as? Int ?? 0
        let comments = json["descendants"] as? Int ?? 0
        metadata.details = "\(score) puntos · \(comments) comentarios"
    }

    // MARK: - npm (registro público)

    private static func enrichNpm(_ metadata: inout LinkMetadata, url: String) async {
        guard let pkg = MacMetadataURL.npmPackage(from: url),
              let encoded = pkg.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let endpoint = URL(string: "https://registry.npmjs.org/\(encoded)"),
              let json = await fetchJSON(endpoint) else { return }
        metadata.title = pkg
        if let desc = json["description"] as? String, !desc.isEmpty { metadata.details = desc }
        if let keywords = json["keywords"] as? [String] { metadata.keywords = keywords }
        if let distTags = json["dist-tags"] as? [String: Any], let latest = distTags["latest"] as? String {
            metadata.siteName = "npm · v\(latest)"
        } else {
            metadata.siteName = "npm"
        }
    }

    // MARK: - PyPI (JSON API pública)

    private static func enrichPyPI(_ metadata: inout LinkMetadata, url: String) async {
        guard let pkg = MacMetadataURL.pypiPackage(from: url),
              let encoded = pkg.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let endpoint = URL(string: "https://pypi.org/pypi/\(encoded)/json"),
              let json = await fetchJSON(endpoint),
              let info = json["info"] as? [String: Any] else { return }
        if let name = info["name"] as? String, !name.isEmpty { metadata.title = name }
        if let summary = info["summary"] as? String, !summary.isEmpty { metadata.details = summary }
        if let keywords = info["keywords"] as? String {
            let words = keywords.split(whereSeparator: { $0 == "," || $0 == " " })
            metadata.keywords = words.map { String($0) }
        }
        if let version = info["version"] as? String {
            metadata.siteName = "PyPI · v\(version)"
        } else {
            metadata.siteName = "PyPI"
        }
    }

    // MARK: - App Store (iTunes Lookup API)

    private static func enrichAppStore(_ metadata: inout LinkMetadata, url: String) async {
        guard let id = MacMetadataURL.appStoreID(from: url) else { return }
        // Respeta la región del store si está en la URL (/es/, /us/…).
        let country = storeCountry(from: url)
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "entity", value: "software")
        ]
        guard let endpoint = components.url,
              let json = await fetchJSON(endpoint),
              let results = json["results"] as? [[String: Any]],
              let app = results.first else { return }

        if let name = app["trackName"] as? String, !name.isEmpty { metadata.title = name }
        if let seller = (app["artistName"] as? String) ?? (app["sellerName"] as? String) {
            metadata.author = seller
        }
        if let desc = app["description"] as? String, !desc.isEmpty {
            metadata.details = desc
        }
        // Icono de alta resolución como imagen de portada.
        let artwork = (app["artworkUrl512"] as? String)
            ?? (app["artworkUrl100"] as? String)
            ?? (app["artworkUrl60"] as? String)
        if let artwork { metadata.imageURL = artwork; metadata.faviconURL = artwork }
        metadata.siteName = "App Store"
    }

    private static func storeCountry(from url: String) -> String {
        let value = url.contains("://") ? url : "https://" + url
        guard let parts = URL(string: value)?.pathComponents else { return "us" }
        // El primer componente tras "/" suele ser el código de país (2 letras).
        if let code = parts.first(where: { $0.count == 2 && $0.allSatisfy(\.isLetter) }) {
            return code.lowercased()
        }
        return "us"
    }

    // MARK: - Twitter / X (oEmbed oficial)

    private static func enrichTwitter(_ metadata: inout LinkMetadata, url: String) async {
        let handle = MacMetadataURL.twitterHandle(from: url)
        metadata.siteName = "X"
        if let handle { metadata.author = "@\(handle)" }

        // Solo los tweets concretos tienen oEmbed; los perfiles se quedan con el handle.
        guard MacMetadataURL.tweetID(from: url) != nil else {
            if let handle { metadata.title = "@\(handle) en X" }
            return
        }

        var components = URLComponents(string: "https://publish.twitter.com/oembed")!
        components.queryItems = [
            URLQueryItem(name: "url", value: url),
            URLQueryItem(name: "omit_script", value: "1"),
            URLQueryItem(name: "dnt", value: "true")
        ]
        guard let endpoint = components.url, let json = await fetchJSON(endpoint) else {
            if let handle { metadata.title = "@\(handle) en X" }
            return
        }

        if let author = json["author_name"] as? String, !author.isEmpty {
            metadata.author = handle.map { "\(author) (@\($0))" } ?? author
        }
        if let html = json["html"] as? String {
            let text = tweetText(fromOEmbedHTML: html)
            if !text.isEmpty {
                metadata.title = text.count > 140 ? String(text.prefix(140)) + "…" : text
                metadata.details = text
            }
        }
        if metadata.title == nil || metadata.title?.isEmpty == true, let handle {
            metadata.title = "@\(handle) en X"
        }
    }

    /// Extrae el texto del tweet del HTML del blockquote de oEmbed.
    private static func tweetText(fromOEmbedHTML html: String) -> String {
        // El texto vive en el primer <p …>…</p> del blockquote.
        guard let pStart = html.range(of: "<p"),
              let gt = html.range(of: ">", range: pStart.upperBound..<html.endIndex),
              let pEnd = html.range(of: "</p>", range: gt.upperBound..<html.endIndex) else {
            return ""
        }
        let inner = String(html[gt.upperBound..<pEnd.lowerBound])
        return decodeHTML(stripTags(inner)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTags(_ s: String) -> String {
        var result = ""
        var inside = false
        for ch in s {
            if ch == "<" { inside = true }
            else if ch == ">" { inside = false }
            else if !inside { result.append(ch) }
        }
        // <br> se convierte en salto de línea.
        return result
    }

    private static func decodeHTML(_ s: String) -> String {
        var r = s
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                   "&#39;": "'", "&#x27;": "'", "&nbsp;": " ", "&hellip;": "…"]
        for (k, v) in map { r = r.replacingOccurrences(of: k, with: v) }
        return r
    }

    // MARK: - Red

    private static func fetchJSON(_ url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let result = try? await ExternalHTTPClient.shared.data(
            for: request, maximumBytes: 2 * 1_024 * 1_024
        ), let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any] else {
            return nil
        }
        return object
    }
}
