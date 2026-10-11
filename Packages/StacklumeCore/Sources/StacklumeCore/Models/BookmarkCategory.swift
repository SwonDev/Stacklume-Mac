import Foundation
import SwiftData

/// Categoría (carpeta) jerárquica de enlaces.
@Model
public final class BookmarkCategory {
    public var id: UUID = UUID()
    public var name: String = ""
    public var details: String?
    /// Nombre de SF Symbol.
    public var icon: String = "folder.fill"
    /// Color en formato hex (#RRGGBB).
    public var colorHex: String = "#D4A853"
    public var order: Int = 0

    /// Portada personalizada de la colección (JPEG comprimido). Si está presente,
    /// la cuadrícula de colecciones la muestra en lugar del mosaico de portadas.
    @Attribute(.externalStorage) public var coverImageData: Data?

    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?

    // Jerarquía (self-referential)
    public var parent: BookmarkCategory?
    @Relationship(deleteRule: .nullify, inverse: \BookmarkCategory.parent)
    public var children: [BookmarkCategory] = []

    // Enlaces de la categoría
    @Relationship(deleteRule: .nullify, inverse: \Bookmark.category)
    public var links: [Bookmark] = []

    public init(
        id: UUID = UUID(),
        name: String = "",
        details: String? = nil,
        icon: String = "folder.fill",
        colorHex: String = "#D4A853",
        order: Int = 0,
        parent: BookmarkCategory? = nil
    ) {
        self.id = id
        self.name = name
        self.details = details
        self.icon = icon
        self.colorHex = colorHex
        self.order = order
        self.parent = parent
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    public var isActive: Bool { deletedAt == nil }

    /// Número de enlaces activos (no borrados) de la categoría.
    public var activeLinkCount: Int {
        links.filter { $0.deletedAt == nil }.count
    }
}
