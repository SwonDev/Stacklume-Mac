import Foundation

/// Un repositorio curado publicado en MAGI//ARCHIVE (tom-doerr/repo_posts).
public struct RepoPost: Sendable, Identifiable, Equatable {
    public var id: String { repoURL }
    public let name: String          // "owner/repo" o el título formateado
    public let description: String
    public let repoURL: String       // enlace al repositorio en GitHub
    public let thumbnail: String?
}

/// Obtiene los últimos repos publicados en MAGI//ARCHIVE leyendo su feed Atom
/// (https://tom-doerr.github.io/repo_posts/feed.xml). Es la "API abierta" del sitio.
public actor RepoPostsService {
    public static let shared = RepoPostsService()

    private var cache: [RepoPost] = []
    private var lastFetch: Date?
    private let ttl: TimeInterval = 60 * 30   // 30 min

    public init() {}

    public func latest(limit: Int = 12) async -> [RepoPost] {
        if let lastFetch, Date().timeIntervalSince(lastFetch) < ttl, !cache.isEmpty {
            return Array(cache.prefix(limit))
        }
        guard let url = URL(string: "https://tom-doerr.github.io/repo_posts/feed.xml") else { return cache }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return cache
        }
        let parser = AtomFeedParser()
        let posts = parser.parse(data)
        if !posts.isEmpty {
            cache = posts
            lastFetch = Date()
        }
        return Array(posts.prefix(limit))
    }

    /// El feed Atom no pagina: la página 1 trae todas las entradas del feed.
    public func page(_ page: Int) async -> [RepoPost] {
        page == 1 ? await latest(limit: 500) : []
    }
}

/// Parser de feed Atom específico para MAGI//ARCHIVE. Por cada `<entry>` toma el
/// `<title>`, el `<link rel="related">` (URL del repo en GitHub), el
/// `<media:thumbnail>` y extrae una descripción del `<content>` HTML.
private final class AtomFeedParser: NSObject, XMLParserDelegate {
    private var posts: [RepoPost] = []

    private var inEntry = false
    private var currentElement = ""
    private var title = ""
    private var repoURL = ""
    private var thumbnail: String?
    private var contentHTML = ""

    func parse(_ data: Data) -> [RepoPost] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return posts
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        currentElement = elementName
        switch elementName {
        case "entry":
            inEntry = true
            title = ""; repoURL = ""; thumbnail = nil; contentHTML = ""
        case "link" where inEntry:
            // El repo de GitHub viene en el <link rel="related">.
            if attributeDict["rel"] == "related", let href = attributeDict["href"] {
                repoURL = href
            }
        case "media:thumbnail" where inEntry:
            thumbnail = attributeDict["url"]
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inEntry else { return }
        switch currentElement {
        case "title": title += string
        case "content": contentHTML += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard inEntry, currentElement == "content" else { return }
        if let chunk = String(data: CDATABlock, encoding: .utf8) {
            contentHTML += chunk
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "entry" {
            inEntry = false
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            // Si el repo es del estilo github.com/owner/repo usamos "owner/repo"
            // como nombre (más informativo que el título formateado).
            let name = Self.ownerRepo(from: repoURL) ?? trimmedTitle
            let description = Self.description(fromHTML: contentHTML, name: name)
            if !repoURL.isEmpty, repoURL.contains("github.com") {
                posts.append(RepoPost(name: name, description: description,
                                      repoURL: repoURL, thumbnail: thumbnail))
            }
        }
        currentElement = ""
    }

    /// Extrae "owner/repo" de una URL https://github.com/owner/repo.
    private static func ownerRepo(from url: String) -> String? {
        guard let comps = URLComponents(string: url), comps.host?.contains("github.com") == true else { return nil }
        let parts = comps.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    /// Limpia el HTML del `<content>` a texto plano y devuelve la frase descriptiva
    /// (quita la imagen, el encabezado con el nombre del repo y los espacios).
    private static func description(fromHTML html: String, name: String) -> String {
        // Quita etiquetas HTML.
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ",
                                              options: .regularExpression)
        text = text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        // Colapsa espacios/saltos.
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Quita el "owner/repo" inicial si quedó como prefijo del texto.
        if text.hasPrefix(name) {
            text = String(text.dropFirst(name.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}
