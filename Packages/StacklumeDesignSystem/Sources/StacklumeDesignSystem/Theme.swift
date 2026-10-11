import SwiftUI

/// Conjunto crudo de tokens OKLCH de un tema (transcritos del `globals.css` original).
struct ThemeTokens: Sendable {
    let background: OKLCH
    let surface: OKLCH
    let popover: OKLCH
    let textPrimary: OKLCH
    let textSecondary: OKLCH
    let accent: OKLCH
    let border: OKLCH
    let scheme: ColorScheme

    var palette: ThemePalette {
        ThemePalette(
            background: background.color,
            surface: surface.color,
            popover: popover.color,
            textPrimary: textPrimary.color,
            textSecondary: textSecondary.color,
            accent: accent.color,
            border: border.color,
            colorScheme: scheme
        )
    }
}

/// Los 24 temas de Stacklume. `system` sigue la apariencia del dispositivo.
public enum Theme: String, CaseIterable, Identifiable, Sendable {
    case system
    case dark, light
    case midnight, ocean, forest, slate, crimson, aurora
    case nordic, catppuccin, tokyo, rosepine, gruvbox, solardark, vampire
    case solarized, arctic, sakura, lavender, mint, cement, stone, steel

    public var id: String { rawValue }

    public var displayName: String {
        let raw: String
        switch self {
        case .system: raw = "Sistema"
        case .dark: raw = "Oscuro"
        case .light: raw = "Claro"
        case .midnight: raw = "Medianoche"
        case .ocean: raw = "Océano"
        case .forest: raw = "Bosque"
        case .slate: raw = "Pizarra"
        case .crimson: raw = "Carmesí"
        case .aurora: raw = "Aurora"
        case .nordic: raw = "Nórdico"
        case .catppuccin: raw = "Catppuccin"
        case .tokyo: raw = "Tokyo Night"
        case .rosepine: raw = "Rosé Pine"
        case .gruvbox: raw = "Gruvbox"
        case .solardark: raw = "Solar oscuro"
        case .vampire: raw = "Vampiro"
        case .solarized: raw = "Solarized"
        case .arctic: raw = "Ártico"
        case .sakura: raw = "Sakura"
        case .lavender: raw = "Lavanda"
        case .mint: raw = "Menta"
        case .cement: raw = "Cemento"
        case .stone: raw = "Piedra"
        case .steel: raw = "Acero"
        }
        return localizedToken(raw)
    }

    /// Esquema preferido para `preferredColorScheme`. `nil` en `system`.
    public var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        default: tokens(systemScheme: .dark).scheme
        }
    }

    /// Paleta resuelta. `systemScheme` solo se usa para el tema `system`.
    public func palette(systemScheme: ColorScheme = .dark) -> ThemePalette {
        tokens(systemScheme: systemScheme).palette
    }

    func tokens(systemScheme: ColorScheme) -> ThemeTokens {
        switch self {
        case .system:
            (systemScheme == .dark ? Theme.dark : Theme.light).tokens(systemScheme: systemScheme)

        case .dark:
            ThemeTokens(background: .init(0.10, 0.025, 250), surface: .init(0.15, 0.035, 250),
                        popover: .init(0.13, 0.03, 250), textPrimary: .init(0.95, 0.01, 85),
                        textSecondary: .init(0.72, 0.03, 250), accent: .init(0.75, 0.14, 85),
                        border: .init(0.28, 0.045, 250), scheme: .dark)
        case .light:
            ThemeTokens(background: .init(0.97, 0.012, 80), surface: .init(0.99, 0.008, 85),
                        popover: .init(0.995, 0.006, 85), textPrimary: .init(0.22, 0.035, 55),
                        textSecondary: .init(0.42, 0.03, 60), accent: .init(0.65, 0.16, 80),
                        border: .init(0.82, 0.02, 80), scheme: .light)
        case .midnight:
            ThemeTokens(background: .init(0.06, 0.015, 270), surface: .init(0.10, 0.03, 275),
                        popover: .init(0.08, 0.025, 275), textPrimary: .init(0.93, 0.01, 280),
                        textSecondary: .init(0.65, 0.03, 275), accent: .init(0.72, 0.20, 290),
                        border: .init(0.22, 0.04, 275), scheme: .dark)
        case .ocean:
            ThemeTokens(background: .init(0.08, 0.025, 215), surface: .init(0.12, 0.035, 215),
                        popover: .init(0.10, 0.03, 215), textPrimary: .init(0.93, 0.01, 195),
                        textSecondary: .init(0.65, 0.025, 215), accent: .init(0.72, 0.14, 195),
                        border: .init(0.24, 0.05, 215), scheme: .dark)
        case .forest:
            ThemeTokens(background: .init(0.08, 0.025, 145), surface: .init(0.12, 0.035, 145),
                        popover: .init(0.10, 0.03, 145), textPrimary: .init(0.93, 0.01, 145),
                        textSecondary: .init(0.65, 0.025, 145), accent: .init(0.72, 0.18, 145),
                        border: .init(0.24, 0.05, 145), scheme: .dark)
        case .slate:
            ThemeTokens(background: .init(0.10, 0.01, 230), surface: .init(0.14, 0.015, 230),
                        popover: .init(0.12, 0.012, 230), textPrimary: .init(0.93, 0.005, 230),
                        textSecondary: .init(0.65, 0.015, 230), accent: .init(0.65, 0.12, 230),
                        border: .init(0.26, 0.022, 230), scheme: .dark)
        case .crimson:
            ThemeTokens(background: .init(0.08, 0.02, 15), surface: .init(0.12, 0.03, 15),
                        popover: .init(0.10, 0.025, 15), textPrimary: .init(0.93, 0.012, 50),
                        textSecondary: .init(0.65, 0.025, 20), accent: .init(0.65, 0.22, 25),
                        border: .init(0.24, 0.05, 15), scheme: .dark)
        case .aurora:
            ThemeTokens(background: .init(0.07, 0.02, 295), surface: .init(0.11, 0.03, 295),
                        popover: .init(0.09, 0.025, 295), textPrimary: .init(0.93, 0.01, 170),
                        textSecondary: .init(0.65, 0.025, 295), accent: .init(0.75, 0.22, 165),
                        border: .init(0.23, 0.04, 295), scheme: .dark)
        case .nordic:
            ThemeTokens(background: .init(0.16, 0.030, 245), surface: .init(0.18, 0.028, 245),
                        popover: .init(0.17, 0.028, 245), textPrimary: .init(0.90, 0.015, 245),
                        textSecondary: .init(0.60, 0.020, 245), accent: .init(0.75, 0.14, 85),
                        border: .init(0.28, 0.025, 245), scheme: .dark)
        case .catppuccin:
            ThemeTokens(background: .init(0.168, 0.020, 280), surface: .init(0.200, 0.018, 280),
                        popover: .init(0.185, 0.018, 280), textPrimary: .init(0.875, 0.018, 280),
                        textSecondary: .init(0.64, 0.015, 280), accent: .init(0.72, 0.18, 308),
                        border: .init(0.30, 0.016, 280), scheme: .dark)
        case .tokyo:
            ThemeTokens(background: .init(0.155, 0.030, 270), surface: .init(0.185, 0.028, 270),
                        popover: .init(0.170, 0.028, 270), textPrimary: .init(0.86, 0.018, 260),
                        textSecondary: .init(0.63, 0.018, 260), accent: .init(0.68, 0.18, 248),
                        border: .init(0.28, 0.025, 270), scheme: .dark)
        case .rosepine:
            ThemeTokens(background: .init(0.165, 0.025, 330), surface: .init(0.195, 0.022, 330),
                        popover: .init(0.180, 0.022, 330), textPrimary: .init(0.87, 0.018, 330),
                        textSecondary: .init(0.64, 0.016, 330), accent: .init(0.76, 0.14, 22),
                        border: .init(0.28, 0.020, 330), scheme: .dark)
        case .gruvbox:
            ThemeTokens(background: .init(0.215, 0.025, 75), surface: .init(0.240, 0.022, 75),
                        popover: .init(0.228, 0.022, 75), textPrimary: .init(0.88, 0.025, 80),
                        textSecondary: .init(0.64, 0.018, 80), accent: .init(0.78, 0.18, 82),
                        border: .init(0.32, 0.020, 75), scheme: .dark)
        case .solardark:
            ThemeTokens(background: .init(0.170, 0.040, 215), surface: .init(0.195, 0.038, 215),
                        popover: .init(0.182, 0.038, 215), textPrimary: .init(0.78, 0.030, 200),
                        textSecondary: .init(0.62, 0.022, 200), accent: .init(0.63, 0.18, 195),
                        border: .init(0.27, 0.035, 215), scheme: .dark)
        case .vampire:
            ThemeTokens(background: .init(0.130, 0.045, 25), surface: .init(0.158, 0.042, 25),
                        popover: .init(0.144, 0.042, 25), textPrimary: .init(0.88, 0.020, 25),
                        textSecondary: .init(0.64, 0.020, 25), accent: .init(0.52, 0.22, 28),
                        border: .init(0.24, 0.038, 25), scheme: .dark)
        case .solarized:
            ThemeTokens(background: .init(0.965, 0.035, 88), surface: .init(0.985, 0.025, 88),
                        popover: .init(0.995, 0.020, 88), textPrimary: .init(0.32, 0.040, 200),
                        textSecondary: .init(0.52, 0.025, 200), accent: .init(0.58, 0.18, 195),
                        border: .init(0.85, 0.030, 88), scheme: .light)
        case .arctic:
            ThemeTokens(background: .init(0.98, 0.005, 220), surface: .init(1.00, 0.003, 220),
                        popover: .init(1.00, 0.002, 220), textPrimary: .init(0.18, 0.02, 230),
                        textSecondary: .init(0.45, 0.025, 230), accent: .init(0.55, 0.18, 230),
                        border: .init(0.84, 0.015, 220), scheme: .light)
        case .sakura:
            ThemeTokens(background: .init(0.97, 0.010, 5), surface: .init(0.995, 0.007, 5),
                        popover: .init(1.00, 0.005, 5), textPrimary: .init(0.22, 0.040, 340),
                        textSecondary: .init(0.45, 0.035, 340), accent: .init(0.62, 0.22, 355),
                        border: .init(0.83, 0.030, 355), scheme: .light)
        case .lavender:
            ThemeTokens(background: .init(0.97, 0.010, 290), surface: .init(0.995, 0.007, 290),
                        popover: .init(1.00, 0.005, 290), textPrimary: .init(0.22, 0.040, 280),
                        textSecondary: .init(0.45, 0.035, 280), accent: .init(0.60, 0.22, 290),
                        border: .init(0.83, 0.030, 290), scheme: .light)
        case .mint:
            ThemeTokens(background: .init(0.97, 0.010, 155), surface: .init(0.995, 0.007, 155),
                        popover: .init(1.00, 0.005, 155), textPrimary: .init(0.20, 0.040, 155),
                        textSecondary: .init(0.45, 0.032, 155), accent: .init(0.55, 0.20, 155),
                        border: .init(0.83, 0.030, 155), scheme: .light)
        case .cement:
            ThemeTokens(background: .init(0.88, 0.008, 250), surface: .init(0.92, 0.006, 250),
                        popover: .init(0.94, 0.005, 250), textPrimary: .init(0.22, 0.020, 250),
                        textSecondary: .init(0.42, 0.015, 250), accent: .init(0.55, 0.18, 275),
                        border: .init(0.77, 0.010, 250), scheme: .light)
        case .stone:
            ThemeTokens(background: .init(0.868, 0.018, 75), surface: .init(0.91, 0.014, 75),
                        popover: .init(0.93, 0.012, 75), textPrimary: .init(0.24, 0.030, 72),
                        textSecondary: .init(0.43, 0.020, 72), accent: .init(0.58, 0.14, 68),
                        border: .init(0.76, 0.018, 75), scheme: .light)
        case .steel:
            ThemeTokens(background: .init(0.808, 0.015, 230), surface: .init(0.85, 0.012, 230),
                        popover: .init(0.87, 0.010, 230), textPrimary: .init(0.22, 0.025, 230),
                        textSecondary: .init(0.39, 0.016, 230), accent: .init(0.52, 0.16, 235),
                        border: .init(0.72, 0.015, 230), scheme: .light)
        }
    }
}
