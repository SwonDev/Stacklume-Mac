import SwiftUI
import StacklumeCore
import StacklumeDesignSystem

// MARK: - Modelo

/// Un elemento de un feed RSS/Atom genérico (artículo, lanzamiento, novedad…).
/// Sirve tanto para feeds integrados (p. ej. Product Hunt) como para los feeds que
/// el usuario añade a mano. La imagen de preview se obtiene con cascada: la imagen
/// del propio elemento (enclosure / media / `<img>` incrustado) y, como respaldo
/// fiable, el favicon del dominio.
struct RSSItem: Identifiable, Hashable {
    let title: String
    let link: String
    let summary: String
    let imageURL: String?
    let author: String

    var id: String { link.isEmpty ? title : link }

    /// Candidatos de imagen en orden de preferencia (nunca un único candidato, para
    /// que «se adquieran bien las imágenes»: ver [[PreviewImage]]).
    var imageCandidates: [String?] {
        var c: [String?] = []
        if let imageURL, !imageURL.isEmpty { c.append(imageURL) }
        c += PreviewImage.favicon(for: link, size: 64).map { Optional($0) }
        return c
    }
}

// MARK: - Servicio (RSS 2.0 + Atom, sin dependencias)

/// Descarga y parsea cualquier feed RSS/Atom con `XMLParser` de Foundation (sin
/// librerías externas). Caché por URL con TTL, al estilo de [[LobstersService]] y
/// del resto de servicios de descubrir. Es un `actor`: el parseo (síncrono y
/// bloqueante) corre fuera del hilo principal.
actor RSSService {
    static let shared = RSSService()

    private struct CachedFeed { var items: [RSSItem]; var fetchedAt: Date }
    private var cache: [String: CachedFeed] = [:]
    private let ttl: TimeInterval = 60 * 15   // 15 min

    /// Elementos del feed `urlString` (cacheados). Devuelve hasta `limit`.
    func items(for urlString: String, limit: Int = 40) async -> [RSSItem] {
        if let cached = cache[urlString],
           Date().timeIntervalSince(cached.fetchedAt) < ttl, !cached.items.isEmpty {
            return Array(cached.items.prefix(limit))
        }
        let fresh = await fetch(urlString)
        if !fresh.isEmpty { cache[urlString] = CachedFeed(items: fresh, fetchedAt: Date()) }
        let result = cache[urlString]?.items ?? fresh
        return Array(result.prefix(limit))
    }

    /// Página para la vista ampliada (scroll infinito). RSS/Atom no pagina, así que
    /// la página 1 devuelve todo y las siguientes vacío (señala «no hay más»).
    func page(_ page: Int, url: String) async -> [RSSItem] {
        guard page == 1 else { return [] }
        return await items(for: url, limit: 60)
    }

    private func fetch(_ urlString: String) async -> [RSSItem] {
        guard let url = StacklumeAutomationPolicy.openableStoredURL(urlString),
              StacklumeAutomationPolicy.allowsAutomaticNetworkURL(url) else { return [] }
        var request = URLRequest(url: url)
        request.setValue("application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9, */*;q=0.8",
                         forHTTPHeaderField: "Accept")
        // Algunos sitios sirven RSS solo a navegadores reales.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X) Stacklume/1.0",
                         forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 14
        guard let result = try? await ExternalHTTPClient.shared.data(
            for: request,
            maximumBytes: 4 * 1_024 * 1_024
        ), !result.data.isEmpty else { return [] }
        return await Self.parse(result.data)
    }

    /// Parsea el XML FUERA del actor (`Task.detached`): el parseo es SÍNCRONO y bloqueante,
    /// así que sacarlo del actor permite que varios feeds se parseen a la vez (antes el
    /// parse de un feed bloqueaba el actor y serializaba a los demás; las descargas ya se
    /// solapaban por reentrancia, ahora también el parseo). El delegado es local y no
    /// escapa de la tarea; `RSSItem` es Sendable (struct interno de campos Sendable).
    private static func parse(_ data: Data) async -> [RSSItem] {
        guard !XMLInputSafety.containsForbiddenDeclaration(data) else { return [] }
        return await Task.detached(priority: .utility) {
            let parser = XMLParser(data: data)
            let delegate = RSSParserDelegate()
            parser.delegate = delegate
            parser.parse()
            return delegate.items
        }.value
    }
}

// MARK: - Delegado de parseo

/// Acumula los elementos de un feed RSS 2.0 (`<item>`) o Atom (`<entry>`). Es una
/// clase local al `fetch` del actor: nunca cruza fronteras de concurrencia, así que
/// no necesita ser `Sendable`.
private final class RSSParserDelegate: NSObject, XMLParserDelegate {
    private static let maximumItems = 200
    private static let maximumFieldCharacters = 256 * 1_024

    private(set) var items: [RSSItem] = []

    private var inItem = false
    private var buffer = ""

    private var title = ""
    private var link = ""
    private var summary = ""
    private var author = ""
    private var image: String?

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attrs: [String: String]) {
        buffer = ""
        let name = el.lowercased()
        if name == "item" || name == "entry" {
            guard items.count < Self.maximumItems else {
                parser.abortParsing()
                return
            }
            inItem = true
            title = ""; link = ""; summary = ""; author = ""; image = nil
            return
        }
        guard inItem else { return }
        switch name {
        case "link":
            // Atom: el enlace está en el atributo `href` (rel=alternate); las
            // imágenes llegan como rel=enclosure. RSS: el enlace es el texto (en end).
            if let href = attrs["href"], !href.isEmpty {
                let rel = attrs["rel"] ?? "alternate"
                if rel == "enclosure" {
                    if image == nil, attrs["type"]?.hasPrefix("image") ?? false { image = href }
                } else if rel == "alternate" || link.isEmpty {
                    link = href
                }
            }
        case "enclosure":
            if let u = attrs["url"], image == nil, attrs["type"]?.hasPrefix("image") ?? true { image = u }
        case "media:content", "media:thumbnail":
            if let u = attrs["url"], image == nil { image = u }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inItem else { return }
        let remaining = Self.maximumFieldCharacters - buffer.count
        guard remaining > 0 else { return }
        buffer += String(string.prefix(remaining))
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard inItem, let s = String(data: CDATABlock, encoding: .utf8) else { return }
        let remaining = Self.maximumFieldCharacters - buffer.count
        guard remaining > 0 else { return }
        buffer += String(s.prefix(remaining))
    }

    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = el.lowercased()
        if name == "item" || name == "entry" {
            inItem = false
            let cleanTitle = RSSText.decode(title).trimmingCharacters(in: .whitespacesAndNewlines)
            if image == nil { image = RSSText.firstImageURL(in: summary) }
            guard !cleanTitle.isEmpty else { return }
            items.append(RSSItem(
                title: cleanTitle,
                link: link.trimmingCharacters(in: .whitespacesAndNewlines),
                summary: RSSText.strip(summary),
                imageURL: image,
                author: RSSText.decode(author).trimmingCharacters(in: .whitespacesAndNewlines)))
            return
        }
        guard inItem else { return }
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "title": if title.isEmpty { title = value }
        case "link": if link.isEmpty, !value.isEmpty { link = value }   // enlace de texto (RSS)
        case "description", "summary", "content", "content:encoded":
            if summary.isEmpty { summary = buffer }      // se guarda crudo para extraer imagen
        case "dc:creator", "name":
            if author.isEmpty, !value.isEmpty { author = value }
        case "author":
            // RSS clásico: `<author>` lleva texto; Atom: lo lleva el `<name>` hijo.
            if author.isEmpty, !value.isEmpty { author = value }
        default:
            break
        }
        buffer = ""
    }
}

// MARK: - Utilidades de texto

/// Limpieza mínima de HTML/entidades en los campos del feed (sin `NSAttributedString`,
/// que exigiría el hilo principal).
enum RSSText {
    /// Quita etiquetas HTML y normaliza espacios; decodifica entidades y elimina el
    /// ruido de enlaces que algunos feeds añaden al final (p. ej. Product Hunt cierra
    /// cada resumen con «… Discussion | Link»).
    static func strip(_ html: String) -> String {
        let noTags = html.replacingOccurrences(
            of: "<[^>]+>", with: " ", options: .regularExpression)
        let collapsed = decode(noTags)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Quita una serie final de textos de enlace típicos («Discussion | Link», etc.).
        let cleaned = collapsed.replacingOccurrences(
            of: "(\\s*\\|?\\s*(Discussion|Comments|Link|Read more|Continue reading))+\\s*$",
            with: "", options: [.regularExpression, .caseInsensitive])
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decodifica las entidades HTML más comunes (incluye numéricas decimales y hex).
    static func decode(_ text: String) -> String {
        var s = text
        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&apos;": "'", "&#39;": "'", "&nbsp;": " ", "&hellip;": "…",
            "&mdash;": "—", "&ndash;": "–", "&rsquo;": "’", "&lsquo;": "‘",
            "&ldquo;": "“", "&rdquo;": "”"
        ]
        for (k, v) in named { s = s.replacingOccurrences(of: k, with: v) }
        s = decodeNumeric(s)
        return s
    }

    /// Resuelve `&#NNN;` y `&#xHH;` a su carácter.
    private static func decodeNumeric(_ text: String) -> String {
        guard text.contains("&#") else { return text }
        var result = ""
        var rest = Substring(text)
        while let range = rest.range(of: "&#") {
            result += rest[..<range.lowerBound]
            let afterAmp = rest[range.upperBound...]
            guard let semi = afterAmp.firstIndex(of: ";") else {
                result += rest[range.lowerBound...]; rest = ""; break
            }
            let code = afterAmp[..<semi]
            let scalar: Unicode.Scalar?
            if code.first == "x" || code.first == "X" {
                scalar = UInt32(code.dropFirst(), radix: 16).flatMap(Unicode.Scalar.init)
            } else {
                scalar = UInt32(code).flatMap(Unicode.Scalar.init)
            }
            if let scalar { result.append(Character(scalar)) } else { result += "&#\(code);" }
            rest = afterAmp[afterAmp.index(after: semi)...]
        }
        result += rest
        return result
    }

    /// Primer `<img src="…">` incrustado en el HTML del resumen (último respaldo).
    static func firstImageURL(in html: String) -> String? {
        guard let match = html.range(
            of: "<img[^>]+src=[\"']([^\"']+)[\"']",
            options: .regularExpression) else { return nil }
        let fragment = String(html[match])
        guard let srcRange = fragment.range(
            of: "src=[\"']([^\"']+)[\"']", options: .regularExpression) else { return nil }
        let src = fragment[srcRange]
            .replacingOccurrences(of: "src=", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let decoded = decode(src)
        guard let url = URL(string: decoded),
              StacklumeAutomationPolicy.allowsAutomaticNetworkURL(url) else {
            return nil
        }
        return url.absoluteString
    }
}

// MARK: - Fila

/// Fila de un elemento de feed RSS/Atom: imagen (preview del elemento o favicon),
/// título, resumen y autor/origen. Clic abre el enlace; clic derecho guarda/copia.
struct RSSItemRow: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.openURL) private var openURL
    let item: RSSItem
    /// Color de acento del feed (p. ej. naranja de Product Hunt). Por defecto, dorado.
    var tint: Color? = nil
    var expanded = false

    private var accent: Color { tint ?? palette.accent }

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            SecureRemoteImage(candidates: item.imageCandidates) {
                FeedFallbackImage(title: item.title, tint: tint)
            }
            .frame(width: expanded ? 64 : 38, height: expanded ? 44 : 30)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .stacklumeFont(.caption.weight(.semibold))
                    .foregroundStyle(palette.textPrimary)
                    .stacklumeLineLimit(expanded ? 3 : 2)
                if !item.summary.isEmpty {
                    Text(item.summary)
                        .stacklumeFont(.caption2)
                        .foregroundStyle(palette.textSecondary)
                        .stacklumeLineLimit(expanded ? 4 : 2)
                }
                if expanded, !item.author.isEmpty {
                    Text(item.author)
                        .stacklumeFont(.caption2)
                        .foregroundStyle(accent)
                        .stacklumeLineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .discoverRow(url: item.link, title: item.title, imageURL: item.imageURL) {
            if let url = StacklumeAutomationPolicy.openableStoredURL(item.link) { openURL(url) }
        }
    }
}

// MARK: - Widget compacto

/// Widget compacto de un feed RSS/Atom (integrado o del usuario). Carga por URL.
struct RSSFeedWidgetContent: View {
    let url: String
    var tint: Color? = nil
    var size: WidgetSize = .extraLarge

    @State private var items: [RSSItem] = []
    @State private var loading = true

    private var limit: Int {
        switch size {
        case .extraLarge: 7
        case .large: 5
        case .medium, .wide: 3
        default: 3
        }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                DiscoverPlaceholder(loading: loading)
            } else {
                DiscoverList(items: items, limit: limit) { RSSItemRow(item: $0, tint: tint) }
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        loading = true
        let result = await RSSService.shared.items(for: url, limit: 40)
        await MainActor.run { items = result; loading = false }
    }
}
