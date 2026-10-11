import Foundation
import SwiftData

/// Espacio de nombres del módulo de dominio.
public enum StacklumeCore {
    public static let displayName = "Stacklume"
    public static let version = "0.1.0"

    /// App Group para compartir el store entre la app y la Share Extension.
    public static let appGroupID = "group.com.swondev.stacklume"

    /// Lista de modelos SwiftData que componen el esquema de la app.
    /// La capa de persistencia la usa para construir el `ModelContainer`.
    public static let models: [any PersistentModel.Type] = [
        Bookmark.self,
        BookmarkCategory.self,
        Tag.self,
        Project.self,
        AppSettings.self,
        ClassificationRule.self,
        DashboardWidget.self,
        PlacedSticker.self,
        LinkSession.self,
        Highlight.self,
        TrackedApp.self
    ]
}
