import Foundation

/// Pestaña abierta obtenida mediante la automatización local de un navegador. No contiene
/// el HTML ni el historial: solo el título y la URL que ya muestra la barra de pestañas.
struct OpenBrowserTab: Identifiable, Hashable, Sendable {
    let browserID: String
    let browserName: String
    let browserIcon: String
    let title: String
    let url: String
    let windowIndex: Int
    let tabIndex: Int
    let isActive: Bool

    var id: String {
        "\(browserID):\(windowIndex):\(tabIndex):\(CanonicalURL.key(url))"
    }

    var host: String {
        URL(string: url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? url
    }
}

/// Decodifica y normaliza la salida JSON de `osascript`. Está separado del cargador AppKit
/// para poder probar entradas corruptas, esquemas inválidos y deduplicación sin lanzar la app.
enum OpenBrowserTabParserError: Error, Equatable {
    case oversizedPayload
    case tooManyTabs
}

enum OpenBrowserTabParser {
    static let maximumPayloadBytes = 24 * 1_024 * 1_024
    static let maximumTabCount = 2_000
    static let maximumTitleLength = 1_024
    static let maximumURLLength = 8_192

    private struct Payload: Decodable {
        let title: String?
        let url: String?
        let windowIndex: Int
        let tabIndex: Int
        let isActive: Bool?
    }

    static func decode(
        _ data: Data,
        browserID: String,
        browserName: String,
        browserIcon: String
    ) throws -> [OpenBrowserTab] {
        guard data.count <= maximumPayloadBytes else {
            throw OpenBrowserTabParserError.oversizedPayload
        }
        let payloads = try JSONDecoder().decode([Payload].self, from: data)
        guard payloads.count <= maximumTabCount else {
            throw OpenBrowserTabParserError.tooManyTabs
        }
        var seen = Set<String>()
        var tabs: [OpenBrowserTab] = []

        for payload in payloads {
            guard let rawURL = payload.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                  rawURL.utf8.count <= maximumURLLength,
                  let validatedURL = StacklumeAutomationPolicy.openableStoredURL(rawURL)
            else { continue }

            let normalizedURL = validatedURL.absoluteString
            let key = CanonicalURL.key(normalizedURL)
            guard seen.insert(key).inserted else { continue }
            let rawTitle = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let cleanTitle = String(rawTitle.prefix(maximumTitleLength))
            let fallback = validatedURL.host()?.replacingOccurrences(of: "www.", with: "")
                ?? normalizedURL
            tabs.append(OpenBrowserTab(
                browserID: browserID,
                browserName: browserName,
                browserIcon: browserIcon,
                title: cleanTitle.isEmpty ? fallback : cleanTitle,
                url: normalizedURL,
                windowIndex: payload.windowIndex,
                tabIndex: payload.tabIndex,
                isActive: payload.isActive ?? false
            ))
        }

        return tabs.sorted {
            ($0.windowIndex, $0.tabIndex, $0.title.localizedLowercase)
                < ($1.windowIndex, $1.tabIndex, $1.title.localizedLowercase)
        }
    }

    /// Deduplica una mezcla de navegadores conservando la primera aparición. Una URL abierta
    /// en Brave y Safari solo debe ofrecerse una vez en el lote de importación.
    static func deduplicated(_ tabs: [OpenBrowserTab]) -> [OpenBrowserTab] {
        var seen = Set<String>()
        return tabs.filter { seen.insert(CanonicalURL.key($0.url)).inserted }
    }
}
