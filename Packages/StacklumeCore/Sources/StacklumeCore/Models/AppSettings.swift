import Foundation
import SwiftData

/// Preferencias de la aplicación. Se mantiene un único registro (singleton)
/// gestionado por la capa de persistencia.
@Model
public final class AppSettings {
    public var id: UUID = UUID()

    /// Identificador del tema activo (coincide con `Theme.id` del DesignSystem).
    /// Se guarda como `String` para que `Core` no dependa de `DesignSystem`.
    public var themeID: String = "dark"

    public var viewMode: ViewMode = ViewMode.list
    public var viewDensity: ViewDensity = ViewDensity.normal
    public var language: AppLanguage = AppLanguage.es

    public var gridColumns: Int = 6
    public var defaultSortField: String = "createdAt"
    public var defaultSortOrder: String = "desc"
    public var thumbnailSize: String = "medium"
    public var confirmBeforeDelete: Bool = true
    public var linkClickBehavior: String = "in-app"
    public var onboardingCompleted: Bool = false

    /// Proveedor de IA: "apple" (Foundation Models on-device) o "liquid"
    /// (LFM2.5-8B-A1B local vía MLX). Migración ligera.
    public var aiProvider: String = "apple"

    public var updatedAt: Date = Date()

    public init(
        themeID: String = "dark",
        viewMode: ViewMode = .list,
        viewDensity: ViewDensity = .normal,
        language: AppLanguage = .es
    ) {
        self.id = UUID()
        self.themeID = themeID
        self.viewMode = viewMode
        self.viewDensity = viewDensity
        self.language = language
        self.updatedAt = Date()
    }
}
