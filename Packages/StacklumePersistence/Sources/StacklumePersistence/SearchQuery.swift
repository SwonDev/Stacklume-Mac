import Foundation
import StacklumeCore

/// Consulta de búsqueda con operadores estilo Raindrop, parseada del texto:
/// - `"frase exacta"` → debe contener esa frase.
/// - `-término` → excluye ese término.
/// - `tag:nombre` → debe tener esa etiqueta (admite comillas: `tag:"dev tools"`).
/// - `type:video|article|image|document|music|code|…` → ese tipo de contenido.
/// - `site:` / `link:dominio` → la URL contiene ese dominio.
/// - El resto de palabras → todas deben aparecer (AND) en título/url/notas/etc.
public struct SearchQuery: Sendable {
    public var terms: [String] = []        // palabras sueltas (AND)
    public var phrases: [String] = []      // "..." (AND)
    public var excluded: [String] = []     // -palabra
    public var tagNames: [String] = []
    public var types: [ContentType] = []
    public var sites: [String] = []

    public var isEmpty: Bool {
        terms.isEmpty && phrases.isEmpty && excluded.isEmpty
            && tagNames.isEmpty && types.isEmpty && sites.isEmpty
    }

    public init(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        for token in SearchQuery.tokenize(text) {
            var t = token
            var negate = false
            if t.hasPrefix("-"), t.count > 1 { negate = true; t.removeFirst() }
            // Frase entre comillas.
            if t.hasPrefix("\"") && t.hasSuffix("\"") && t.count > 1 {
                let phrase = String(t.dropFirst().dropLast()).lowercased()
                if !phrase.isEmpty { (negate ? appendExcluded(phrase) : phrases.append(phrase)) }
                continue
            }
            // Operadores campo:valor.
            if let colon = t.firstIndex(of: ":"), colon != t.startIndex {
                let field = t[t.startIndex..<colon].lowercased()
                var value = String(t[t.index(after: colon)...])
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count > 1 {
                    value = String(value.dropFirst().dropLast())
                }
                value = value.lowercased()
                if !value.isEmpty {
                    switch field {
                    case "tag", "#": tagNames.append(value)
                    case "type": if let ct = SearchQuery.contentType(for: value) { types.append(ct) }
                    case "site", "link", "domain": sites.append(value)
                    default: negate ? appendExcluded(t.lowercased()) : terms.append(t.lowercased())
                    }
                    continue
                }
            }
            let word = t.lowercased()
            if !word.isEmpty { negate ? excluded.append(word) : terms.append(word) }
        }
    }

    private mutating func appendExcluded(_ s: String) { excluded.append(s) }

    /// Mapea un valor de `type:` al `ContentType` (admite ES/EN comunes).
    static func contentType(for value: String) -> ContentType? {
        switch value {
        case "video", "vídeo", "videos": .video
        case "article", "artículo", "articulo", "post": .article
        case "image", "imagen", "img": .design
        case "music", "música", "musica", "audio": .music
        case "document", "documento", "doc", "pdf": .document
        case "code", "código", "codigo", "repo": .code
        case "game", "juego": .game
        case "social": .social
        case "design", "diseño", "diseno": .design
        case "commerce", "comercio", "shop": .commerce
        case "web", "website", "sitio": .website
        default: nil
        }
    }

    /// Divide respetando las comillas (mantiene `"a b"` y `tag:"a b"` como un token).
    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in s {
            if ch == "\"" { inQuotes.toggle(); current.append(ch) }
            else if ch == " " && !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else { current.append(ch) }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Comprueba si un enlace cumple la consulta.
    @MainActor
    public func matches(_ link: Bookmark) -> Bool {
        if !types.isEmpty && !types.contains(link.contentType) { return false }
        if !tagNames.isEmpty {
            let names = link.tags.map { $0.name.lowercased() }
            for needed in tagNames where !names.contains(where: { $0.contains(needed) }) { return false }
        }
        if !sites.isEmpty {
            let host = link.url.lowercased()
            for site in sites where !host.contains(site) { return false }
        }
        let meta = [link.title, link.url, link.details ?? "", link.notes ?? "",
                    link.siteName ?? "", link.command ?? "", link.summary ?? "",
                    link.semanticTags.joined(separator: " ")].joined(separator: " ").lowercased()
        // Un excluido presente en los metadatos descarta ya.
        for ex in excluded where meta.contains(ex) { return false }
        let positivesInMeta = phrases.allSatisfy { meta.contains($0) } && terms.allSatisfy { meta.contains($0) }
        // Camino rápido SIN tocar el contenido offline (carga diferida): solo válido si NO
        // hay exclusiones que verificar fuera de los metadatos y los positivos ya están.
        if excluded.isEmpty && positivesInMeta { return true }
        // A partir de aquí necesitamos el texto offline para decidir bien.
        guard let offline = link.offlineText, !offline.isEmpty else {
            // Sin contenido offline: los excluidos ya se comprobaron en metadatos, así que
            // basta con que los positivos estén en los metadatos.
            return positivesInMeta
        }
        // Texto completo: revalida TODO (positivos + exclusiones) sobre metadatos + offline.
        let full = meta + " " + offline.lowercased()
        for ex in excluded where full.contains(ex) { return false }
        for phrase in phrases where !full.contains(phrase) { return false }
        for term in terms where !full.contains(term) { return false }
        return true
    }
}
