import Foundation
import StacklumeMetadata
import StacklumeDesignSystem

/// Busca la MEJOR imagen representativa de una página web cuando el enlace no tiene
/// portada (sin `og:image`). Hace web fetch del HTML y aplica una cadena de respaldo:
///
/// 1. `og:image` / `twitter:image` (vía `OpenGraphParser`, el mismo parser del alta).
/// 2. La imagen «hero» más prominente del `<body>` (heurística por posición/tamaño,
///    descartando iconos, logos, sprites, avatares, píxeles de seguimiento y SVG).
///
/// Cada candidato se VALIDA descargándolo de verdad (`ImageCache`): solo se devuelve
/// uno que decodifique a una imagen real de ≥ 200 px en su lado mayor, así nunca se
/// fija una portada rota o diminuta. NO usa el modelo LLM: es descarga + parseo, por lo
/// que funciona aunque la IA on-device no esté disponible (como espera el usuario:
/// «la IA hace web fetch y descarga la imagen principal»).
enum PageImageFinder {

    /// URL absoluta de la mejor imagen de la página, o `nil` si no expone ninguna
    /// imagen de contenido razonable (en ese caso se conserva el logo centrado).
    static func bestImageURL(for rawURL: String, retry: Bool = false) async -> String? {
        await validatedCandidates(for: rawURL, limit: 1, retry: retry).first
    }

    /// Hasta `limit` URLs de imagen VALIDADAS (descargadas y ≥ 200 px en su lado mayor),
    /// en orden de prioridad (og:image primero, luego las `<img>` hero del cuerpo). Para
    /// la galería de selección de portada, donde el usuario elige entre varias candidatas.
    static func validatedCandidates(for rawURL: String, limit: Int, retry: Bool = false) async -> [String] {
        guard !Task.isCancelled else { return [] }
        let normalized = rawURL.contains("://") ? rawURL : "https://" + rawURL
        guard let url = StacklumeAutomationPolicy.openableStoredURL(normalized),
              StacklumeAutomationPolicy.allowsAutomaticNetworkURL(url),
              let html = await fetchHTML(from: url), !Task.isCancelled else { return [] }

        var candidates: [String] = []
        // 1) Open Graph / Twitter Card (reutiliza el parser del paquete de metadatos).
        if let og = OpenGraphParser.parse(html: html, baseURL: url).imageURL, isLikelyContentImage(og) {
            candidates.append(og)
        }
        // 2) Imágenes hero del cuerpo (orden del documento, ya filtradas).
        candidates.append(contentsOf: heroCandidates(in: html, baseURL: url))

        // Dedup conservando el orden de prioridad.
        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0).inserted }

        // Quédate con las que descargan y decodifican a una imagen real y grande.
        var valid: [String] = []
        for candidate in candidates.prefix(16) {
            guard !Task.isCancelled else { return [] }
            guard let u = URL(string: candidate) else { continue }
            if retry { await SecureImageCache.shared.retry(for: u) }
            guard let img = await SecureImageCache.shared.image(for: u), !Task.isCancelled else { continue }
            if max(img.size.width, img.size.height) >= 200 {
                valid.append(candidate)
                if valid.count >= limit { break }
            }
        }
        return valid
    }

    // MARK: - Extracción de candidatos «hero»

    /// Imágenes candidatas del cuerpo, en orden del documento. Incluye `<link
    /// rel="image_src">` (algunos sitios lo usan) y los `<img>` que superan el filtro.
    private static func heroCandidates(in html: String, baseURL: URL) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        for tag in matches(in: html, pattern: "<link\\b[^>]*>") {
            guard let rel = attribute("rel", in: tag)?.lowercased(), rel.contains("image_src"),
                  let href = attribute("href", in: tag), let abs = absoluteURL(href, base: baseURL),
                  isLikelyContentImage(abs), seen.insert(abs).inserted else { continue }
            result.append(abs)
        }

        for tag in matches(in: html, pattern: "<img\\b[^>]*>") {
            guard let raw = bestSource(in: tag), let abs = absoluteURL(raw, base: baseURL),
                  isLikelyContentImage(abs) else { continue }
            // Descarta si declara dimensiones explícitas y son pequeñas (icono/avatar).
            if let w = Int(attribute("width", in: tag) ?? ""), let h = Int(attribute("height", in: tag) ?? ""),
               max(w, h) < 200 { continue }
            if seen.insert(abs).inserted { result.append(abs) }
        }
        return result
    }

    /// Mejor URL de un `<img>`: prioriza el mayor ancho de `srcset`; si no, el primer
    /// atributo de origen no vacío (incluye carga diferida `data-src`/`data-original`).
    private static func bestSource(in imgTag: String) -> String? {
        if let srcset = attribute("srcset", in: imgTag) ?? attribute("data-srcset", in: imgTag),
           let best = largestFromSrcset(srcset) {
            return best
        }
        for key in ["src", "data-src", "data-original", "data-lazy-src", "data-image"] {
            if let value = attribute(key, in: imgTag), !value.isEmpty, !value.hasPrefix("data:") {
                return value
            }
        }
        return nil
    }

    /// De un `srcset` («url 320w, url2 640w»), devuelve la URL con mayor descriptor de
    /// ancho (`w`); si no hay descriptores, la primera.
    private static func largestFromSrcset(_ srcset: String) -> String? {
        var best: (width: Int, url: String)?
        for part in srcset.split(separator: ",") {
            let tokens = part.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard let url = tokens.first.map(String.init) else { continue }
            let width = tokens.count > 1 ? Int(tokens[1].replacingOccurrences(of: "w", with: "")) ?? 0 : 0
            if best == nil || width > best!.width { best = (width, url) }
        }
        return best?.url
    }

    /// Heurística de descarte: rechaza recursos que casi nunca son la imagen principal
    /// (iconos, logos, sprites, avatares, píxeles de seguimiento, SVG, placeholders).
    private static func isLikelyContentImage(_ urlString: String) -> Bool {
        let lower = urlString.lowercased()
        guard !lower.hasPrefix("data:"), !lower.hasSuffix(".svg") else { return false }
        let banned = ["sprite", "icon", "logo", "favicon", "avatar", "emoji", "pixel",
                      "spacer", "blank", "placeholder", "loading", "1x1", "badge",
                      "/ads/", "tracking", "beacon", "doubleclick"]
        return !banned.contains { lower.contains($0) }
    }

    // MARK: - Red

    private static func fetchHTML(from url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        // User-Agent de Safari de escritorio: algunas webs sirven HTML/imágenes distintas
        // (mejores) a un navegador de escritorio que a un móvil o a un bot.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        guard let result = try? await ExternalHTTPClient.shared.data(
            for: request,
            maximumBytes: 1_024 * 1_024,
            allowedMIMEPrefixes: ["text/html", "application/xhtml"]
        ) else { return nil }
        return String(data: result.data, encoding: .utf8)
            ?? String(data: result.data, encoding: .isoLatin1)
    }

    // MARK: - Regex helpers (locales: los del paquete son privados)

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)')"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(tag.startIndex..., in: tag)
        guard let match = regex.firstMatch(in: tag, range: range) else { return nil }
        for idx in [2, 3] where match.numberOfRanges > idx {
            if let r = Range(match.range(at: idx), in: tag) { return String(tag[r]) }
        }
        return nil
    }

    private static func absoluteURL(_ value: String, base: URL?) -> String? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return nil }
        if v.hasPrefix("http://") || v.hasPrefix("https://") { return v }
        if v.hasPrefix("//") { return "https:" + v }
        if let base, let resolved = URL(string: v, relativeTo: base)?.absoluteString { return resolved }
        return nil
    }
}
