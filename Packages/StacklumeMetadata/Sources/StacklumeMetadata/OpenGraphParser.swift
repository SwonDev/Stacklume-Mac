import Foundation

/// Metadatos extraídos del HTML de una página.
public struct OpenGraphMetadata: Sendable, Equatable {
    public var title: String?
    public var description: String?
    public var imageURL: String?
    public var siteName: String?
    public var author: String?
    public var faviconURL: String?
}

/// Parser ligero y tolerante de Open Graph y metadatos HTML (sin dependencias).
public enum OpenGraphParser {

    public static func parse(html: String, baseURL: URL?) -> OpenGraphMetadata {
        var result = OpenGraphMetadata()

        let htmlTitle = firstGroup(in: html, pattern: "<title[^>]*>([\\s\\S]*?)</title>")
            .map { decodeEntities($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        var ogTitle: String?
        var twitterTitle: String?

        // Etiquetas <meta ...>
        for tag in matches(in: html, pattern: "<meta\\b[^>]*>") {
            let key = (attribute("property", in: tag) ?? attribute("name", in: tag) ?? attribute("itemprop", in: tag))?.lowercased()
            guard let key, let raw = attribute("content", in: tag), !raw.isEmpty else { continue }
            let value = decodeEntities(raw)
            switch key {
            case "og:title": ogTitle = value
            case "twitter:title": twitterTitle = value
            case "og:description", "twitter:description", "description":
                if result.description == nil { result.description = value }
            case "og:image", "og:image:url", "og:image:secure_url", "twitter:image", "twitter:image:src":
                if result.imageURL == nil { result.imageURL = value }
            case "og:site_name", "application-name":
                if result.siteName == nil { result.siteName = value }
            case "author", "article:author", "twitter:creator":
                if result.author == nil { result.author = value }
            default: break
            }
        }

        result.title = ogTitle ?? twitterTitle ?? htmlTitle

        // Favicon: recoge todos los <link rel*=icon> y elige el mejor.
        var icons: [(rel: String, size: Int, href: String)] = []
        for tag in matches(in: html, pattern: "<link\\b[^>]*>") {
            guard let rel = attribute("rel", in: tag)?.lowercased(), rel.contains("icon"),
                  let href = attribute("href", in: tag) else { continue }
            let size = attribute("sizes", in: tag).flatMap { Int($0.split(separator: "x").first ?? "") } ?? 0
            icons.append((rel, size, href))
        }
        if let best = bestIcon(icons) {
            result.faviconURL = absoluteURL(best, base: baseURL)
        }

        if let image = result.imageURL {
            result.imageURL = absoluteURL(image, base: baseURL)
        }
        return result
    }

    /// Prioriza apple-touch-icon, luego mayor tamaño, luego icon genérico.
    private static func bestIcon(_ icons: [(rel: String, size: Int, href: String)]) -> String? {
        if let apple = icons.first(where: { $0.rel.contains("apple-touch-icon") }) { return apple.href }
        if let sized = icons.filter({ $0.size > 0 }).max(by: { $0.size < $1.size }) { return sized.href }
        if let icon = icons.first(where: { $0.rel.contains("icon") }) { return icon.href }
        return icons.first?.href
    }

    // MARK: - Regex helpers

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func firstGroup(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)')"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(tag.startIndex..., in: tag)
        guard let match = regex.firstMatch(in: tag, range: range) else { return nil }
        for idx in [2, 3] where match.numberOfRanges > idx {
            if let r = Range(match.range(at: idx), in: tag) { return String(tag[r]) }
        }
        return nil
    }

    private static func absoluteURL(_ value: String, base: URL?) -> String {
        if value.hasPrefix("http://") || value.hasPrefix("https://") { return value }
        if value.hasPrefix("//") { return "https:" + value }
        if let base, let resolved = URL(string: value, relativeTo: base)?.absoluteString { return resolved }
        return value
    }

    private static func decodeEntities(_ text: String) -> String {
        var s = text
        let map = ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                   "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for (entity, char) in map { s = s.replacingOccurrences(of: entity, with: char) }
        return s
    }
}
