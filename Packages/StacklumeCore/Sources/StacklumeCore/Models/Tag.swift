import Foundation
import SwiftData

/// Etiqueta (tag) de color. Relación N:N con `Bookmark`.
@Model
public final class Tag {
    public var id: UUID = UUID()
    public var name: String = ""
    /// Color en formato hex (#RRGGBB).
    public var colorHex: String = "#7AA2F7"
    public var order: Int = 0
    public var createdAt: Date = Date()
    public var deletedAt: Date?

    // Jerarquía (etiquetas anidadas, estilo Raindrop #padre/hijo). Self-referential.
    public var parent: Tag?
    @Relationship(deleteRule: .nullify, inverse: \Tag.parent)
    public var children: [Tag] = []

    /// Enlaces que tienen esta etiqueta (la inversa se declara en `Bookmark.tags`).
    public var links: [Bookmark] = []

    public init(
        id: UUID = UUID(),
        name: String = "",
        colorHex: String = "#7AA2F7",
        order: Int = 0
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.order = order
        self.createdAt = Date()
    }

    public var isActive: Bool { deletedAt == nil }

    public var activeLinkCount: Int {
        links.filter { $0.deletedAt == nil }.count
    }
}
