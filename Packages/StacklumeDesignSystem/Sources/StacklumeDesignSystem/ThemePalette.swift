import SwiftUI

/// Paleta de colores resuelta de un tema, lista para consumir en las vistas.
public struct ThemePalette: Sendable, Equatable {
    public var background: Color
    public var surface: Color
    public var popover: Color
    public var textPrimary: Color
    public var textSecondary: Color
    public var accent: Color
    public var border: Color
    public var colorScheme: ColorScheme

    public init(
        background: Color,
        surface: Color,
        popover: Color,
        textPrimary: Color,
        textSecondary: Color,
        accent: Color,
        border: Color,
        colorScheme: ColorScheme
    ) {
        self.background = background
        self.surface = surface
        self.popover = popover
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.accent = accent
        self.border = border
        self.colorScheme = colorScheme
    }
}
