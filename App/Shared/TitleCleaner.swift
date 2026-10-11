import Foundation
import StacklumeCore

/// Limpieza DETERMINISTA del ruido de los títulos OG: quita el nombre del sitio que
/// muchas páginas anteponen o posponen al título real («GitHub - owner/repo: …»,
/// «Vídeo - YouTube», «Título - Wikipedia, la enciclopedia libre»). No depende de la
/// IA (que a veces reescribe y no encaja): trabaja sobre separadores conocidos y solo
/// elimina el segmento si coincide con el nombre del sitio o el dominio. Conservador:
/// si no reconoce ruido claro, devuelve el título tal cual.
enum TitleCleaner {
    /// Separadores típicos entre el título real y el nombre del sitio.
    private static let separators = [" - ", " | ", " · ", " — ", " – ", " :: ", " • "]

    /// Etiquetas de dominio genéricas que NO sirven como "marca" del sitio.
    private static let domainStopwords: Set<String> = [
        "www", "com", "org", "net", "io", "co", "app", "dev", "gg", "tv", "edu",
        "gov", "ai", "me", "es", "en", "www2", "m", "amp", "html", "http", "https"
    ]

    /// Devuelve el título sin el ruido del sitio. Idempotente.
    static func clean(_ title: String, siteName: String?, host: String) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > 2 else { return title }
        let candidates = siteCandidates(siteName: siteName, host: host)
        guard !candidates.isEmpty else { return t }

        // 1) Sufijo: «<título real> <sep> <sitio>» (YouTube, Wikipedia, etc.).
        for sep in separators {
            guard let r = t.range(of: sep, options: .backwards) else { continue }
            let head = t[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let tail = t[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if head.count >= 3, matchesSite(tail, candidates) {
                t = head
                break
            }
        }

        // 2) Prefijo: «<sitio> <sep> <título real>» (GitHub, foros, etc.).
        for sep in separators {
            guard let r = t.range(of: sep) else { continue }
            let head = t[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let rest = t[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if rest.count >= 3, matchesSite(head, candidates) {
                t = rest
                break
            }
        }

        return t.isEmpty ? title : t
    }

    // MARK: - Internos

    /// Nombres por los que se reconoce el sitio: el `siteName` y la "marca" del dominio
    /// (etiquetas significativas del host), normalizados.
    private static func siteCandidates(siteName: String?, host: String) -> [String] {
        var result: [String] = []
        if let s = siteName?.trimmingCharacters(in: .whitespaces), !s.isEmpty {
            result.append(normalize(s))
        }
        let cleanedHost = host.replacingOccurrences(of: "www.", with: "")
        for label in cleanedHost.split(separator: ".").map(String.init) {
            let lower = label.lowercased()
            if lower.count >= 3, !domainStopwords.contains(lower) {
                result.append(normalize(label))
            }
        }
        return result.filter { !$0.isEmpty }
    }

    /// ¿El `segment` corresponde al nombre del sitio? Coincide si, normalizado, es igual
    /// a un candidato o empieza por él (p. ej. «wikipedialaenciclopedialibre» empieza por
    /// «wikipedia»). Exige candidatos de ≥3 para no falsar con etiquetas cortas.
    private static func matchesSite(_ segment: String, _ candidates: [String]) -> Bool {
        let seg = normalize(segment)
        guard !seg.isEmpty else { return false }
        for c in candidates where c.count >= 3 {
            if seg == c || seg.hasPrefix(c) || c.hasPrefix(seg) { return true }
        }
        return false
    }

    /// Minúsculas, sin tildes, solo alfanuméricos (para comparar de forma robusta).
    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}
