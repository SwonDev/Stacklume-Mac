import Foundation
import SwiftData

/// DashboardWidget del dashboard (bento / kanban / lista).
@Model
public final class DashboardWidget {
    public var id: UUID = UUID()
    public var type: WidgetType = WidgetType.favorites
    public var title: String = ""
    public var size: WidgetSize = WidgetSize.medium
    public var order: Int = 0

    /// Texto de configuración (p. ej. el contenido de una nota).
    public var configText: String?
    /// Categoría asociada (para el widget de categoría).
    public var categoryID: UUID?
    /// Color de acento personalizado (hex).
    public var colorHex: String?
    /// Columna del tablero Kanban (nil = sin asignar).
    public var kanbanColumn: String?
    /// Nº máximo de elementos a mostrar (nil = automático según el tamaño).
    public var itemLimit: Int?

    public var createdAt: Date = Date()
    public var deletedAt: Date?

    /// Proyecto al que pertenece (nil = Inicio).
    public var project: Project?

    public init(
        id: UUID = UUID(),
        type: WidgetType = .favorites,
        title: String = "",
        size: WidgetSize? = nil,
        order: Int = 0,
        configText: String? = nil,
        categoryID: UUID? = nil,
        colorHex: String? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title.isEmpty ? type.displayName : title
        self.size = size ?? type.defaultSize
        self.order = order
        self.configText = configText
        self.categoryID = categoryID
        self.colorHex = colorHex
        self.createdAt = Date()
    }

    public var isActive: Bool { deletedAt == nil }
}
