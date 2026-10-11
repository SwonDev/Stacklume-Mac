import SwiftUI

public extension EnvironmentValues {
    /// Paleta del tema activo. Las vistas la leen para colorearse.
    @Entry var themePalette: ThemePalette = Theme.dark.palette()
    /// Tema activo (por si una vista necesita el enum y no solo la paleta).
    @Entry var appTheme: Theme = .dark
}

public extension View {
    /// Inyecta un tema en el entorno (paleta + enum) y fija el `colorScheme`.
    func stacklumeTheme(_ theme: Theme, systemScheme: ColorScheme = .dark) -> some View {
        let palette = theme.palette(systemScheme: systemScheme)
        return self
            .environment(\.themePalette, palette)
            .environment(\.appTheme, theme)
            .tint(palette.accent)
    }

    /// Fondo con el color de fondo del tema, extendido a los bordes.
    func themedBackground() -> some View {
        modifier(ThemedBackgroundModifier())
    }

    /// Estilo unificado para pantallas basadas en `Form`/`List`: oculta el fondo
    /// gris del sistema, pinta las filas con el `surface` del tema (navy en oscuro,
    /// casi blanco en claro) y extiende el fondo del tema a los bordes. Elimina el
    /// marco gris del sistema que desentonaba con el branding en modo oscuro.
    func brandedForm() -> some View {
        modifier(BrandedFormModifier())
    }

    /// Aplica el acento del tema a un `Picker` tipo menú y fuerza su reconstrucción
    /// cuando cambia el acento. Los `Picker` de menú se respaldan en UIKit y CACHEAN
    /// el tintColor: al cambiar entre dos temas del mismo esquema (p. ej. Carmesí →
    /// Oscuro) el texto del valor conservaba el color antiguo. Ligar el `id` al
    /// acento recrea el control con el color correcto; la selección va por binding,
    /// así que no se pierde.
    func themedMenuTint() -> some View {
        modifier(ThemedMenuTintModifier())
    }
}

private struct ThemedBackgroundModifier: ViewModifier {
    @Environment(\.themePalette) private var palette

    func body(content: Content) -> some View {
        content.background(palette.background.ignoresSafeArea())
    }
}

private struct BrandedFormModifier: ViewModifier {
    @Environment(\.themePalette) private var palette

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .listRowBackground(palette.surface)
            // Las hojas (editor de enlaces, etc.) se presentan fuera de la jerarquía
            // de RootView, así que el ocultado global no las alcanza: lo aplicamos aquí.
            .scrollIndicators(.hidden)
            .background(palette.background.ignoresSafeArea())
    }
}

private struct ThemedMenuTintModifier: ViewModifier {
    @Environment(\.themePalette) private var palette

    func body(content: Content) -> some View {
        content
            .tint(palette.accent)
            .id(palette.accent)
    }
}
