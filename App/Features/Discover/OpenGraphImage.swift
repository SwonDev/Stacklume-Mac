import SwiftUI
import AppKit
import StacklumeCore
import StacklumeDesignSystem

// MARK: - Servicio

/// Obtiene la imagen de portada «real» de un sitio web extrayendo su metaetiqueta
/// Open Graph (`og:image`) o Twitter Card del `<head>`. Esto da a la galería de apps
/// una captura/hero del propio proyecto en vez de solo el icono. Cachea por sitio
/// (incluido el «no hay imagen», para no reintentar) y deduplica peticiones en curso.
actor OpenGraphImageService {
    static let shared = OpenGraphImageService()

    private var cache: [String: String?] = [:]
    private var inFlight: [String: Task<String?, Never>] = [:]

    /// URL de la portada del sitio, o `nil` si no se encontró ninguna.
    func image(for website: String) async -> String? {
        if let cached = cache[website] { return cached }
        if let task = inFlight[website] { return await task.value }
        let task = Task<String?, Never> { await Self.fetch(website) }
        inFlight[website] = task
        let result = await task.value
        cache[website] = result
        inFlight[website] = nil
        return result
    }

    private static func fetch(_ website: String) async -> String? {
        guard let url = StacklumeAutomationPolicy.openableStoredURL(website),
              StacklumeAutomationPolicy.allowsAutomaticNetworkURL(url) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 Stacklume/1.0",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,*/*;q=0.8", forHTTPHeaderField: "Accept")
        // Las metaetiquetas og viven en el <head>: pedimos solo el principio del HTML.
        request.setValue("bytes=0-262143", forHTTPHeaderField: "Range")
        guard let result = try? await ExternalHTTPClient.shared.data(
            for: request,
            maximumBytes: 256 * 1_024,
            acceptedStatusCodes: 200...299,
            allowedMIMEPrefixes: ["text/html", "application/xhtml"]
        ), !result.data.isEmpty else { return nil }
        guard let html = String(data: result.data, encoding: .utf8)
                ?? String(data: result.data, encoding: .isoLatin1)
        else { return nil }
        return extractImage(from: html, baseURL: url)
    }

    /// Busca la mejor portada disponible, probando varias propiedades por orden.
    static func extractImage(from html: String, baseURL: URL) -> String? {
        let keys = ["og:image:secure_url", "og:image:url", "og:image", "twitter:image:src", "twitter:image"]
        for key in keys {
            if let raw = metaContent(html: html, property: key) {
                return resolve(raw, against: baseURL)
            }
        }
        return nil
    }

    /// Extrae el `content` de una `<meta>` cuya `property`/`name` sea `property`,
    /// tolerando cualquier orden de los atributos.
    private static func metaContent(html: String, property: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let patterns = [
            "<meta[^>]+(?:property|name)=[\"']\(escaped)[\"'][^>]*content=[\"']([^\"']+)[\"']",
            "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]*(?:property|name)=[\"']\(escaped)[\"']"
        ]
        for pattern in patterns {
            guard let range = html.range(of: pattern, options: [.regularExpression, .caseInsensitive])
            else { continue }
            let fragment = String(html[range])
            guard let contentRange = fragment.range(
                of: "content=[\"']([^\"']+)[\"']", options: [.regularExpression, .caseInsensitive])
            else { continue }
            let content = String(fragment[contentRange])
                .replacingOccurrences(of: "content=", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if !content.isEmpty { return RSSText.decode(content) }
        }
        return nil
    }

    /// Resuelve una URL relativa o sin esquema (`//host/…`) contra la del sitio.
    private static func resolve(_ src: String, against base: URL) -> String? {
        let raw: String
        if src.hasPrefix("http://") || src.hasPrefix("https://") {
            raw = src
        } else if src.hasPrefix("//") {
            raw = (base.scheme ?? "https") + ":" + src
        } else {
            raw = URL(string: src, relativeTo: base)?.absoluteString ?? src
        }
        guard let url = StacklumeAutomationPolicy.openableStoredURL(raw),
              StacklumeAutomationPolicy.allowsAutomaticNetworkURL(url) else { return nil }
        return url.absoluteString
    }
}

// MARK: - Vista de portada

/// Portada de un sitio que carga su `og:image` de forma diferida y la presenta con
/// `CoverImageContent` (rellena si es captura/banner real; desenfoque + centrada nítida
/// si es un logo pequeño — nunca recorta ni pixela). Mientras carga, o si no hay imagen,
/// muestra el `placeholder` de marca. Cascada de DESIGN.md: og:image → respaldo.
struct OpenGraphCover<Placeholder: View>: View {
    let website: String
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            placeholder()
            if let image {
                CoverImageContent(image: image).transition(.opacity)
            }
        }
        .clipped()
        .task(id: website) {
            image = nil
            guard let og = await OpenGraphImageService.shared.image(for: website),
                  let url = URL(string: og) else { return }
            guard let loaded = await SecureImageCache.shared.image(for: url), !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.25)) { image = loaded }
        }
    }
}
