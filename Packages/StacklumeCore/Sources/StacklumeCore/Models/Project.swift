import Foundation
import SwiftData

/// Espacio de trabajo (workspace). Agrupa widgets en fases posteriores; en la
/// Fase 1 sirve para organizar y como base del modelo.
@Model
public final class Project {
    public var id: UUID = UUID()
    public var name: String = ""
    /// Nombre de SF Symbol.
    public var icon: String = "square.stack.3d.up.fill"
    public var colorHex: String = "#D4A853"
    public var order: Int = 0
    /// Proyecto por defecto (vista Home).
    public var isDefault: Bool = false
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String = "",
        icon: String = "square.stack.3d.up.fill",
        colorHex: String = "#D4A853",
        order: Int = 0,
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.order = order
        self.isDefault = isDefault
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    public var isActive: Bool { deletedAt == nil }
}
