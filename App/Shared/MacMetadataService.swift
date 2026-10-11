import Foundation
import StacklumeCore
import StacklumeMetadata

/// Obtiene metadatos de una URL combinando detección de plataforma y descarga
/// del HTML (Open Graph). Sin dependencias externas.
struct MacMetadataService: Sendable {

    init() {}

    /// Resuelve los metadatos de una URL. Nunca lanza: ante fallo de red devuelve
    /// al menos la detección de plataforma y el host como título.
    func fetchMetadata(for rawURL: String) async -> LinkMetadata {
        let normalized = Self.normalize(rawURL)
        let detection = PlatformDetector.detect(normalized)
        let host = MacMetadataURL.normalizedHost(of: normalized)

        var metadata = LinkMetadata(
            url: normalized,
            platform: detection.platform,
            contentType: detection.contentType,
            platformColor: detection.brandColorHex
        )
        metadata.imageURL = detection.directThumbnailURL
        metadata.faviconURL = FaviconProvider.googleFavicon(forURL: normalized)

        guard let url = URL(string: normalized) else {
            metadata.title = host
            return metadata
        }

        if let html = await fetchHTML(from: url) {
            let og = OpenGraphParser.parse(html: html, baseURL: url)
            metadata.title = og.title ?? metadata.title
            metadata.details = og.description
            metadata.siteName = og.siteName
            metadata.author = og.author
            if metadata.imageURL == nil { metadata.imageURL = og.imageURL }
            if let favicon = og.faviconURL { metadata.faviconURL = favicon }
        }

        // Fuentes especiales (App Store, Twitter/X) que necesitan una API dedicada.
        await MacSpecialEnrichers.enrich(&metadata, url: normalized)

        if metadata.title == nil || metadata.title?.isEmpty == true {
            metadata.title = host
        }
        return metadata
    }

    // MARK: - Red

    private func fetchHTML(from url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Stacklume/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        guard let result = try? await ExternalHTTPClient.shared.data(
            for: request, maximumBytes: 2 * 1_024 * 1_024
        ) else { return nil }
        let limited = result.data.prefix(512 * 1_024)
        return String(data: limited, encoding: .utf8)
            ?? String(data: limited, encoding: .isoLatin1)
    }

    // MARK: - Utilidades

    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") { return trimmed }
        return "https://" + trimmed
    }
}
