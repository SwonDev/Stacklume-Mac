import Foundation

struct AssistantWebResult: Equatable, Hashable, Sendable {
    let title: String
    let url: String
    let snippet: String
}

struct AssistantWebPage: Equatable, Sendable {
    let title: String
    let url: String
    let text: String
}

enum AssistantWebAccess {
    static let enabledKey = "stacklume.aiWebSearchEnabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else { return true }
        return defaults.bool(forKey: enabledKey)
    }
}

enum AssistantWebError: LocalizedError {
    case disabled
    case invalidQuery
    case invalidURL
    case unsafeURL
    case badResponse
    case tooLarge
    case unsupportedContent
    case noResults

    var errorDescription: String? {
        switch self {
        case .disabled: "La búsqueda web está desactivada en Ajustes › IA."
        case .invalidQuery: "La consulta web está vacía o no es válida."
        case .invalidURL: "La URL no es válida."
        case .unsafeURL: "La URL apunta a un destino local, privado o no permitido."
        case .badResponse: "El sitio no devolvió una respuesta válida."
        case .tooLarge: "La respuesta supera el límite seguro de lectura."
        case .unsupportedContent: "Ese tipo de contenido no puede leerse como una página web."
        case .noResults: "No se encontraron resultados verificables."
        }
    }
}

/// Cliente web deliberadamente pequeño: no usa cookies, caché, credenciales ni cabeceras de
/// referencia. Solo la consulta sale del Mac; las páginas recuperadas se procesan localmente.
actor AssistantWebClient {
    static let shared = AssistantWebClient()

    private static let maximumSearchBytes = 2 * 1_024 * 1_024
    private static let maximumPageBytes = 3 * 1_024 * 1_024
    private static let maximumPageCharacters = 14_000

    func search(_ rawQuery: String, limit: Int = 6) async throws -> [AssistantWebResult] {
        guard AssistantWebAccess.isEnabled() else { throw AssistantWebError.disabled }
        let query = AssistantWebParser.sanitizedQuery(rawQuery)
        guard !query.isEmpty else { throw AssistantWebError.invalidQuery }

        let endpoints = [
            "https://html.duckduckgo.com/html/",
            "https://lite.duckduckgo.com/lite/",
        ]
        var lastError: Error = AssistantWebError.noResults
        for endpoint in endpoints {
            do {
                guard let url = AssistantWebParser.searchURL(endpoint: endpoint, query: query) else {
                    throw AssistantWebError.invalidQuery
                }
                let html = try await requestText(url: url, maximumBytes: Self.maximumSearchBytes)
                let results = AssistantWebParser.parseDuckResults(html.text, limit: limit)
                if !results.isEmpty { return results }
                lastError = AssistantWebError.noResults
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func readPage(_ rawURL: String) async throws -> AssistantWebPage {
        guard AssistantWebAccess.isEnabled() else { throw AssistantWebError.disabled }
        guard var url = URL(string: rawURL) else { throw AssistantWebError.invalidURL }
        guard StacklumeAutomationPolicy.allowsExternalCaptureURL(url) else { throw AssistantWebError.unsafeURL }
        // La lectura del asistente nunca envía contenido ni credenciales por HTTP plano.
        if url.scheme?.lowercased() == "http", var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = "https"
            guard let secureURL = components.url else { throw AssistantWebError.invalidURL }
            url = secureURL
        }
        var visited = Set<String>()
        for _ in 0..<4 {
            try Task.checkCancellation()
            guard visited.insert(url.absoluteString).inserted else { throw AssistantWebError.badResponse }
            let response = try await requestText(url: url, maximumBytes: Self.maximumPageBytes)
            if let redirected = AssistantWebParser.htmlRedirectURL(response.text, sourceURL: response.url) {
                url = redirected
                continue
            }
            let page = AssistantWebParser.extractPage(response.text, sourceURL: response.url.absoluteString,
                                                      maximumCharacters: Self.maximumPageCharacters)
            guard !page.text.isEmpty else { throw AssistantWebError.unsupportedContent }
            return page
        }
        throw AssistantWebError.badResponse
    }

    private func requestText(url: URL, maximumBytes: Int) async throws -> (text: String, url: URL) {
        guard StacklumeAutomationPolicy.allowsAutomaticNetworkURL(url) else {
            throw AssistantWebError.unsafeURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(
            "Mozilla/5.0 (Macintosh; Apple Silicon Mac OS X 26_0) AppleWebKit/605.1.15 Version/26.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,text/plain;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue("es,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let result: ExternalHTTPResponse
        do {
            result = try await ExternalHTTPClient.shared.data(
                for: request,
                maximumBytes: maximumBytes
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch ExternalHTTPError.unsafeURL {
            throw AssistantWebError.unsafeURL
        } catch ExternalHTTPError.tooLarge {
            throw AssistantWebError.tooLarge
        } catch {
            throw AssistantWebError.badResponse
        }
        let mime = (result.response.mimeType ?? "text/html").lowercased()
        guard mime.hasPrefix("text/html") || mime.hasPrefix("text/plain")
                || mime.contains("xhtml") else {
            throw AssistantWebError.unsupportedContent
        }

        guard let text = String(data: result.data, encoding: .utf8)
                ?? String(data: result.data, encoding: .isoLatin1) else {
            throw AssistantWebError.badResponse
        }
        return (text, result.response.url ?? url)
    }
}

/// Parser y normalizador Foundation puro, cubierto por tests. Tolera tanto DuckDuckGo HTML
/// como Lite, deduplica URLs y descarta esquemas/destinos no públicos antes de alimentar el LLM.
enum AssistantWebParser {
    static let maximumQueryCharacters = AssistantActionPolicy.maximumWebQueryCharacters

    static func sanitizedQuery(_ raw: String) -> String {
        String(AssistantActionPolicy.sanitizedUserInput(raw).prefix(maximumQueryCharacters))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func searchURL(endpoint: String, query: String) -> URL? {
        guard var components = URLComponents(string: endpoint) else { return nil }
        components.queryItems = [URLQueryItem(name: "q", value: sanitizedQuery(query))]
        return components.url
    }

    static func parseDuckResults(_ html: String, limit: Int) -> [AssistantWebResult] {
        let safeLimit = min(max(limit, 1), 10)
        let anchorPatterns = [
            #"class=[\"']result__a[\"'][^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>"#,
            #"href=[\"']([^\"']+)[\"'][^>]*class=[\"']result-link[\"'][^>]*>(.*?)</a>"#,
            #"class=[\"']result-link[\"'][^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>"#,
        ]
        let snippetPatterns = [
            #"class=[\"']result__snippet[\"'][^>]*>(.*?)</(?:a|div|td)>"#,
            #"class=[\"']result-snippet[\"'][^>]*>(.*?)</td>"#,
        ]
        let anchors = anchorPatterns.lazy.map { matches(in: html, pattern: $0) }
            .first(where: { !$0.isEmpty }) ?? []
        let snippets = snippetPatterns.lazy.map { matches(in: html, pattern: $0) }
            .first(where: { !$0.isEmpty }) ?? []

        var output: [AssistantWebResult] = []
        var seen = Set<String>()
        for (index, anchor) in anchors.enumerated() where output.count < safeLimit {
            guard anchor.count >= 3 else { continue }
            let decodedURL = decodeDuckHref(anchor[1])
            guard let url = URL(string: decodedURL),
                  StacklumeAutomationPolicy.allowsExternalCaptureURL(url) else { continue }
            let canonical = canonicalResultKey(url)
            guard seen.insert(canonical).inserted else { continue }
            let title = String(cleanHTML(anchor[2]).prefix(220))
            guard !title.isEmpty else { continue }
            let snippet = index < snippets.count && snippets[index].count >= 2
                ? String(cleanHTML(snippets[index][1]).prefix(500))
                : ""
            output.append(.init(title: title, url: url.absoluteString, snippet: snippet))
        }
        return output
    }

    static func htmlRedirectURL(_ html: String, sourceURL: URL) -> URL? {
        for match in matches(in: html, pattern: #"<meta\b[^>]{0,4096}>"#).prefix(32) {
            guard let tag = match.first else { continue }
            func attribute(_ name: String) -> String? {
                for pattern in [#"\b"# + name + #"\s*=\s*\"([^\"]*)\""#,
                                #"\b"# + name + #"\s*=\s*'([^']*)'"#,
                                #"\b"# + name + #"\s*=\s*([^\s>]+)"#] {
                    if let value = firstMatch(in: tag, pattern: pattern) { return decodeHTML(value) }
                }
                return nil
            }
            guard attribute("http-equiv")?.lowercased() == "refresh",
                  let content = attribute("content"),
                  let separator = content.firstIndex(of: ";"),
                  let delay = Double(content[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)),
                  (0...5).contains(delay),
                  let target = firstMatch(in: String(content[content.index(after: separator)...]),
                                          pattern: #"^\s*url\s*=\s*(.*?)\s*$"#),
                  let url = URL(string: target.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")),
                                relativeTo: sourceURL)?.absoluteURL,
                  StacklumeAutomationPolicy.allowsAutomaticNetworkURL(url) else { continue }
            return url
        }
        return nil
    }

    static func extractPage(_ html: String, sourceURL: String, maximumCharacters: Int) -> AssistantWebPage {
        let title = firstMatch(in: html, pattern: #"<title[^>]*>(.*?)</title>"#)
            .map(cleanHTML) ?? URL(string: sourceURL)?.host() ?? "Página web"
        var body = firstMatch(in: html, pattern: #"<body[^>]*>(.*?)</body>"#) ?? html
        let blockedPatterns = [
            #"<!--.*?-->"#, #"<script\b[^>]*>.*?</script>"#, #"<style\b[^>]*>.*?</style>"#,
            #"<noscript\b[^>]*>.*?</noscript>"#, #"<svg\b[^>]*>.*?</svg>"#,
            #"<form\b[^>]*>.*?</form>"#, #"<nav\b[^>]*>.*?</nav>"#,
        ]
        for pattern in blockedPatterns {
            body = body.replacingOccurrences(of: pattern, with: " ",
                                              options: [.regularExpression, .caseInsensitive])
        }
        body = body.replacingOccurrences(
            of: #"</?(?:p|div|section|article|main|h[1-6]|li|br|tr|blockquote)\b[^>]*>"#,
            with: "\n", options: [.regularExpression, .caseInsensitive]
        )
        var text = decodeHTML(body.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression))
        text = AssistantActionPolicy.sanitizedUserInput(text)
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n\s*\n\s*\n+"#, with: "\n\n", options: .regularExpression)
        text = String(text.prefix(min(max(maximumCharacters, 1_000), 20_000)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(title: String(title.prefix(220)), url: sourceURL, text: text)
    }

    private static func canonicalResultKey(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return (components?.string ?? url.absoluteString)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    private static func decodeDuckHref(_ raw: String) -> String {
        let href = cleanHTML(raw)
        if let components = URLComponents(string: href.hasPrefix("//") ? "https:" + href : href),
           let encoded = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return encoded.removingPercentEncoding ?? encoded
        }
        return href.hasPrefix("//") ? "https:" + href : href
    }

    private static func cleanHTML(_ raw: String) -> String {
        let text = decodeHTML(raw.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression))
        return AssistantActionPolicy.sanitizedUserInput(text)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTML(_ raw: String) -> String {
        var text = raw
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#x27;": "'", "&#39;": "'", "&nbsp;": " ", "&hellip;": "…",
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        return text
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        matches(in: text, pattern: pattern).first.flatMap { $0.count > 1 ? $0[1] : nil }
    }

    /// Devuelve [coincidencia completa, grupo 1, grupo 2, …].
    private static func matches(in text: String, pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else { return [] }
        let string = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: string.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : string.substring(with: range)
            }
        }
    }
}
