import Foundation

/// Crea una "copia permanente" legible de una página para leer SIN CONEXIÓN:
/// descarga el HTML, extrae el texto del artículo (sin scripts/estilos) y lo
/// envuelve en un documento HTML autocontenido y con estilo. Aunque la página
/// original desaparezca, el texto guardado sigue disponible (estilo Raindrop Pro).
public enum OfflineCopyService {

    /// Descarga y genera el HTML legible offline. Devuelve `nil` si falla.
    public static func fetchReadable(url urlString: String) async -> String? {
        let normalized = urlString.contains("://") ? urlString : "https://" + urlString
        guard let url = URL(string: normalized) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0 (compatible; Stacklume/1.0)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        // Cap defensivo: la URL es arbitraria del usuario; no decodifiquemos respuestas
        // gigantes (un servidor hostil podría agotar la memoria). 1,5 MB cubre artículos.
        let html = String(decoding: data.prefix(1_500_000), as: UTF8.self)
        let title = extractTitle(html) ?? url.host() ?? "Artículo"
        let body = extractReadableBody(html)
        guard !body.isEmpty else { return nil }
        return wrap(title: title, body: body, source: normalized)
    }

    /// Texto plano del HTML offline, para BÚSQUEDA de texto completo: quita etiquetas,
    /// decodifica entidades, colapsa espacios y capa la longitud. Sirve tanto para
    /// poblar el índice al guardar una copia como para el backfill de copias antiguas.
    public static func plainText(from html: String) -> String {
        let stripped = stripTags(html)
        let decoded = decodeEntities(stripped)
        let collapsed = decoded
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(20_000))
    }

    // MARK: - Extracción

    private static func extractTitle(_ html: String) -> String? {
        guard let r = html.range(of: "<title[^>]*>(.*?)</title>",
                                 options: [.regularExpression, .caseInsensitive]) else { return nil }
        let raw = String(html[r])
        let inner = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let t = decodeEntities(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Extrae párrafos y encabezados legibles del `<body>`, en HTML simple.
    private static func extractReadableBody(_ html: String) -> String {
        var s = html
        // Quita scripts, estilos, head, nav, footer y comentarios.
        for pattern in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>",
                        "<head[\\s\\S]*?</head>", "<nav[\\s\\S]*?</nav>",
                        "<footer[\\s\\S]*?</footer>", "<!--[\\s\\S]*?-->",
                        "<svg[\\s\\S]*?</svg>"] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        // Captura el contenido de párrafos y encabezados.
        var blocks: [String] = []
        let tags = ["h1", "h2", "h3", "p", "li", "blockquote"]
        for tag in tags {
            let pattern = "<\(tag)[^>]*>([\\s\\S]*?)</\(tag)>"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let ns = s as NSString
            regex.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                let inner = ns.substring(with: match.range(at: 1))
                let text = decodeEntities(stripTags(inner)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.count > 1 else { return }
                let htmlTag = (tag == "li") ? "p" : tag
                blocks.append("<\(htmlTag)>\(escape(text))</\(htmlTag)>")
            }
        }
        // Limita por seguridad (artículos enormes) manteniendo lo esencial.
        return blocks.prefix(400).joined(separator: "\n")
    }

    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    private static func decodeEntities(_ s: String) -> String {
        var r = s
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
                   "&#x27;": "'", "&nbsp;": " ", "&hellip;": "…", "&mdash;": "—", "&ndash;": "–",
                   "&rsquo;": "'", "&lsquo;": "'", "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}"]
        for (k, v) in map { r = r.replacingOccurrences(of: k, with: v) }
        return r
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Envuelve el texto en un documento HTML con estilo de lectura (oscuro).
    private static func wrap(title: String, body: String, source: String) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>
        :root { color-scheme: dark light; }
        body { font: -apple-system-body, system-ui; line-height: 1.6; margin: 0;
               padding: 20px; max-width: 720px; margin: 0 auto;
               background: #0B1220; color: #E8EAF0; }
        h1 { font-size: 1.6em; line-height: 1.25; margin: 0 0 .2em; }
        h2 { font-size: 1.3em; margin: 1.2em 0 .3em; }
        h3 { font-size: 1.1em; margin: 1em 0 .3em; }
        p { margin: 0 0 1em; }
        blockquote { border-left: 3px solid #D4A853; margin: 1em 0; padding-left: 14px; color: #B8BDcc; }
        .src { color: #8A90A2; font-size: .85em; margin-bottom: 1.5em; word-break: break-all; }
        a { color: #D4A853; }
        </style></head><body>
        <h1>\(escape(title))</h1>
        <div class="src">\(escape(source))</div>
        \(body)
        </body></html>
        """
    }
}
