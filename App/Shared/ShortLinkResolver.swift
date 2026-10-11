import Foundation
import SwiftData
import StacklumeCore

/// Expande las URLs ACORTADAS (t.co, bit.ly…) a su destino real. Un enlace `t.co/xxxx` no
/// dice nada: muestra el logo de X, host «t.co» y no se le pueden sacar metadatos buenos. Aquí
/// se sigue la redirección y se devuelve la URL final, para que el favicon/imagen/título salgan
/// de la página DE VERDAD y «Abrir original» lleve al sitio correcto.
///
/// Solo actúa sobre hosts acortadores conocidos (no toca el resto). 100 % local salvo la
/// petición de red que sigue la redirección. Lo usa el [[LibraryCompleter]] antes de enriquecer.
@MainActor
enum ShortLinkResolver {

    /// Hosts acortadores cuyas URLs hay que expandir. NO se incluye `youtu.be`: es una URL
    /// canónica de YouTube (no un acortador a expandir), igual que `g.co` u otros oficiales.
    static let shortenerHosts: Set<String> = [
        "t.co", "bit.ly", "bitly.com", "buff.ly", "ow.ly", "tinyurl.com", "goo.gl",
        "is.gd", "dlvr.it", "ift.tt", "trib.al", "rebrand.ly", "cutt.ly", "lnkd.in",
        "fb.me", "rb.gy", "shorturl.at", "tiny.cc", "t.ly", "v.gd", "x.gd", "s.id",
    ]

    /// ¿La URL es de un acortador conocido?
    static func isShortened(_ urlString: String) -> Bool {
        host(of: urlString).map { shortenerHosts.contains($0) } ?? false
    }

    /// Sigue las redirecciones y devuelve la URL FINAL (absoluta), o `nil` si no se pudo
    /// resolver o no cambió de host. Intenta HEAD (ligero), luego GET (redirección HTTP) y, por
    /// último, el destino embebido en el HTML: algunos acortadores (t.co) sirven una página 200
    /// con `<meta http-equiv="refresh" content="0;URL=…">` o `location.replace("…")` en vez de un
    /// 301 (típico de enlaces a descargas directas). Así esos también se expanden.
    static func resolve(_ urlString: String) async -> String? {
        guard let url = StacklumeAutomationPolicy.openableStoredURL(
            urlString.contains("://") ? urlString : "https://" + urlString
        ), StacklumeAutomationPolicy.allowsExternalCaptureURL(url) else { return nil }
        if let final = await finalURL(for: url, method: "HEAD") { return final }
        if let final = await finalURL(for: url, method: "GET") { return final }
        return await metaRefreshTarget(for: url)
    }

    /// `response.url` es la URL final tras seguir las redirecciones (URLSession las sigue solo).
    /// Solo se acepta si cambió de host (de verdad se expandió el acortador).
    private static func finalURL(for url: URL, method: String) async -> String? {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 12
        // User-Agent de Safari real: algunos acortadores responden distinto a peticiones «bot».
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")
        guard let response = try? await ExternalHTTPClient.shared.response(for: request),
              let resolved = response.url?.absoluteString,
              let original = host(of: url.absoluteString),
              let finalHost = host(of: resolved),
              original != finalHost else { return nil }
        return resolved
    }

    /// Descarga el HTML del 200 y extrae el destino de un `meta refresh` o `location.replace`
    /// (acortadores que no usan 301, como t.co con descargas directas). Devuelve la URL solo si
    /// es absoluta y cambia de host respecto al acortador.
    private static func metaRefreshTarget(for url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        guard let result = try? await ExternalHTTPClient.shared.data(
            for: request,
            maximumBytes: 512 * 1_024,
            allowedMIMEPrefixes: ["text/html", "application/xhtml"]
        ), let html = String(data: result.data, encoding: .utf8)
            ?? String(data: result.data, encoding: .isoLatin1) else { return nil }

        // 1) <meta http-equiv="refresh" content="0;URL=https://…">
        if let target = firstCapture(
            #"(?i)http-equiv=[\"']?refresh[\"']?[^>]*?url=([^\"'> ]+)"#, in: html) {
            return validated(target, against: url)
        }
        // 2) location.replace("https:\/\/…") / location.href = "…"
        if let raw = firstCapture(
            #"location\.(?:replace\(|href\s*=\s*)[\"']([^\"']+)[\"']"#, in: html) {
            return validated(raw.replacingOccurrences(of: "\\/", with: "/"), against: url)
        }
        return nil
    }

    /// Acepta el destino solo si es absoluto y de OTRO host (de verdad expande el acortador).
    private static func validated(_ target: String, against original: URL) -> String? {
        let decoded = target.removingPercentEncoding ?? target
        guard let dest = StacklumeAutomationPolicy.openableStoredURL(decoded),
              StacklumeAutomationPolicy.allowsExternalCaptureURL(dest),
              let destHost = dest.host()?.lowercased(),
              let origHost = original.host()?.lowercased(), destHost != origHost else { return nil }
        return dest.absoluteString
    }

    /// Primer grupo de captura de `pattern` en `text` (regex, case-insensitive donde el patrón
    /// lo indique). `nil` si no casa.
    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func host(of urlString: String) -> String? {
        let value = urlString.contains("://") ? urlString : "https://" + urlString
        return URL(string: value)?.host()?.lowercased().replacingOccurrences(of: "www.", with: "")
    }
}
