import Foundation

/// Extractores internos del paquete read-only, conservados en la frontera de red Mac.
enum MacMetadataURL {
    static func normalizedHost(of urlString: String) -> String {
        var value = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains("://") { value = "https://" + value }
        guard let host = URL(string: value)?.host()?.lowercased() else {
            return urlString.lowercased()
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func subreddit(from urlString: String) -> String? {
        let value = urlString.contains("://") ? urlString : "https://" + urlString
        guard let url = URL(string: value) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let idx = parts.firstIndex(where: { $0.lowercased() == "r" }), idx + 1 < parts.count else { return nil }
        return parts[idx + 1]
    }

    static func hackerNewsID(from urlString: String) -> String? {
        let value = urlString.contains("://") ? urlString : "https://" + urlString
        guard let items = URLComponents(string: value)?.queryItems,
              let id = items.first(where: { $0.name == "id" })?.value, Int(id) != nil else { return nil }
        return id
    }

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

    static func pypiPackage(from urlString: String) -> String? {
        let value = urlString.contains("://") ? urlString : "https://" + urlString
        guard let url = URL(string: value) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let idx = parts.firstIndex(of: "project"), idx + 1 < parts.count else { return nil }
        return parts[idx + 1]
    }

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

    static func twitterHandle(from urlString: String) -> String? {
        let value = urlString.contains("://") ? urlString : "https://" + urlString
        guard let url = URL(string: value) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let reserved: Set<String> = ["i", "home", "search", "explore", "notifications", "messages", "hashtag"]
        guard let first = parts.first, !reserved.contains(first.lowercased()) else { return nil }
        return first
    }

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

    static func gitHubSlug(from urlString: String) -> String? {
        let value = urlString.contains("://") ? urlString : "https://" + urlString
        guard let url = URL(string: value) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        let reserved: Set<String> = ["features", "about", "pricing", "marketplace", "topics", "sponsors", "settings"]
        guard !reserved.contains(parts[0].lowercased()) else { return nil }
        return "\(parts[0])/\(parts[1])"
    }
}
