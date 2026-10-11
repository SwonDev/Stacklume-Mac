import Foundation
import SwiftData

/// Sesión de enlaces: un grupo de marcadores que se abren todos a la vez
/// (equivale al "session launcher" del original).
@Model
public final class LinkSession {
    public var id: UUID = UUID()
    public var name: String = ""
    public var icon: String = "rectangle.stack.fill"
    public var colorHex: String = "#7AA2F7"
    public var order: Int = 0
    public var createdAt: Date = Date()

    @Relationship public var links: [Bookmark] = []

    public init(
        id: UUID = UUID(),
        name: String = "",
        icon: String = "rectangle.stack.fill",
        colorHex: String = "#7AA2F7",
        order: Int = 0,
        links: [Bookmark] = []
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.order = order
        self.links = links
        self.createdAt = Date()
    }
}
