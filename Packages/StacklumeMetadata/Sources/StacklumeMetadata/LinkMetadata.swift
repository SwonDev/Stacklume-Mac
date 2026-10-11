import Foundation
import StacklumeCore

/// Metadatos resueltos de una URL, listos para volcar en un `Bookmark`.
public struct LinkMetadata: Sendable, Equatable {
    public var url: String
    public var title: String?
    public var details: String?
    public var imageURL: String?
    public var faviconURL: String?
    public var siteName: String?
    public var author: String?
    public var platform: Platform
    public var contentType: ContentType
    public var platformColor: String?
    /// Palabras clave del recurso (p. ej. keywords del paquete npm/PyPI/cargo) que
    /// se convierten en etiquetas automáticas.
    public var keywords: [String]

    public init(
        url: String,
        title: String? = nil,
        details: String? = nil,
        imageURL: String? = nil,
        faviconURL: String? = nil,
        siteName: String? = nil,
        author: String? = nil,
        platform: Platform = .generic,
        contentType: ContentType = .website,
        platformColor: String? = nil,
        keywords: [String] = []
    ) {
        self.url = url
        self.title = title
        self.details = details
        self.imageURL = imageURL
        self.faviconURL = faviconURL
        self.siteName = siteName
        self.author = author
        self.platform = platform
        self.contentType = contentType
        self.platformColor = platformColor
        self.keywords = keywords
    }
}
