import Foundation

/// Clave para decidir si dos enlaces son DUPLICADOS. Normaliza SOLO lo que NO cambia a qué
/// recurso apunta la URL, de forma que la MISMA página guardada de dos maneras se detecte
/// como un único enlace (objetivo: que la biblioteca «no se duplique» de forma automática):
///
/// - esquema y host en minúsculas; `http` se unifica a `https` (mismo recurso casi siempre),
/// - se quita el prefijo `www.` del host,
/// - se quita una única barra final del path,
/// - se eliminan los parámetros de SEGUIMIENTO/analítica (`utm_*`, `fbclid`, `gclid`,
///   Mailchimp, HubSpot, Instagram… y `s`/`t` en x.com/twitter) que NO identifican el recurso.
///
/// **NO** se tocan los parámetros de CONTENIDO (`id`, `q`, `page`, `v` de YouTube…) ni el
/// fragmento `#…` (puede ser una ruta de SPA): así nunca se fusionan páginas realmente
/// distintas. La URL ALMACENADA no cambia; esto es solo la clave de comparación.
enum CanonicalURL {
    /// Los adjuntos se identifican por UUID/contenido, nunca por su URL vacía. Esta
    /// frontera también evita fusionar notas locales o entradas con una URL inválida.
    static func webBookmarkKey(_ rawURL: String, fileKind: String?) -> String? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fileKind == nil, !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        return key(trimmed)
    }

    /// Parámetros de seguimiento globales (además de cualquiera con prefijo `utm_`).
    private static let trackingParams: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "wbraid", "gbraid",
        "msclkid", "yclid", "twclid", "igshid", "igsh",
        "mc_cid", "mc_eid", "mkt_tok", "_hsenc", "_hsmi", "hsctatracking",
        "vero_id", "oly_enc_id", "oly_anon_id", "spm", "scm", "ncid", "ref_src",
        "_openstat", "wt_mc", "wt_zmc", "trk_contact", "trk_module",
    ]

    /// Clave de igualdad para deduplicar. Si la URL no es parseable, degrada de forma segura
    /// (minúsculas + sin barra final) sobre el texto recortado.
    static func key(_ urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var comps = URLComponents(string: trimmed) else {
            var s = trimmed.lowercased()
            while s.count > 1, s.hasSuffix("/") { s.removeLast() }
            return s
        }
        // Esquema: minúsculas y http→https (servir contenido distinto por esquema es rarísimo).
        if let scheme = comps.scheme?.lowercased() {
            comps.scheme = (scheme == "http") ? "https" : scheme
        }
        // Host: minúsculas y sin «www.».
        var host = comps.host?.lowercased() ?? ""
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        if host == "civitai.red" || host == "civitai.com" {
            let parts = comps.path.split(separator: "/", omittingEmptySubsequences: true)
            if parts.count >= 2,
               !parts[1].isEmpty, parts[1].utf8.allSatisfy({ (48...57).contains($0) }) {
                if parts[0] == "models", parts.count <= 3 {
                    host = "civitai.com"
                    comps.path = "/models/\(parts[1])"
                } else if parts[0] == "images", parts.count == 2 {
                    host = "civitai.com"
                }
            }
        }
        if !host.isEmpty { comps.host = host }
        // Path: quita una única barra final.
        if comps.path.count > 1, comps.path.hasSuffix("/") {
            comps.path = String(comps.path.dropLast())
        }
        // Query: elimina los parámetros de seguimiento; conserva el resto en su orden.
        if let items = comps.queryItems {
            let kept = items.filter { !isTracking($0.name, host: host) }
            comps.queryItems = kept.isEmpty ? nil : kept
        }
        return comps.string ?? trimmed
    }

    /// ¿`name` es un parámetro de seguimiento (no de contenido)? Cubre `utm_*`, la lista
    /// global y `s`/`t` específicos de x.com/twitter (firmas del compartir).
    private static func isTracking(_ name: String, host: String) -> Bool {
        let n = name.lowercased()
        if n.hasPrefix("utm_") { return true }
        if trackingParams.contains(n) { return true }
        let isX = host == "x.com" || host == "twitter.com"
            || host.hasSuffix(".x.com") || host.hasSuffix(".twitter.com")
        if isX, n == "s" || n == "t" { return true }
        return false
    }
}
