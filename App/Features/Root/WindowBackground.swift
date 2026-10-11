import SwiftUI
import AppKit
import StacklumeDesignSystem

/// Fondo continuo navy de Stacklume. La variación vertical es deliberadamente mínima:
/// da al cristal algo que refractar sin recuperar los halos ni las «manchas» de color
/// rechazadas en iteraciones anteriores.
struct WindowBackground: View {
    @Environment(\.themePalette) private var palette

    var body: some View {
        ZStack {
            palette.background
            LinearGradient(
                colors: [palette.surface.opacity(0.26), .clear, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        }
            .ignoresSafeArea()
    }
}

/// Tematiza la `NSWindow` que contiene esta vista para que su BARRA DE TÍTULO deje de verse con
/// el material gris del sistema y se integre con el navy del tema. Hace el titlebar TRANSPARENTE
/// (el contenido navy sube por debajo, full-size) y pinta el fondo de la ventana con `background`.
/// Reactivo: al cambiar de tema/acento, `updateNSView` repinta la ventana al instante.
///
/// Se aplica como `.background(WindowChrome(...))`: un `NSView` invisible y sin tamaño cuyo único
/// cometido es alcanzar `view.window`. Sirve para la ventana principal y para los sheets (cada
/// sheet es su propia `NSWindow`), así ningún titlebar queda gris. No toca los semáforos ni los
/// botones de la toolbar, solo el FONDO de la franja.
extension Color {
    /// Elige blanco o negro por contraste WCAG sobre un relleno opaco.
    @MainActor var contrastingForeground: Color {
        NativeForegroundContrast.select(on: self)
    }
}

extension ThemePalette {
    /// Conserva el acento si es legible; el fondo debe ser el relleno opaco real.
    @MainActor func readableAccent(on background: Color, minimumContrast: Double = 4.5) -> Color {
        NativeForegroundContrast.select(on: background, accent: accent, fallback: textPrimary,
                                        scheme: colorScheme, minimumContrast: minimumContrast)
    }

    @MainActor func foreground(on background: Color) -> Color {
        NativeForegroundContrast.select(on: background, scheme: colorScheme)
    }

    @MainActor func readableForeground(_ preferred: Color, on background: Color,
                                       minimumContrast: Double = 4.5) -> Color {
        NativeForegroundContrast.select(on: background, accent: preferred, fallback: textPrimary,
                                        scheme: colorScheme, minimumContrast: minimumContrast)
    }

    /// `nil` exige un respaldo opaco: ningún candidato cumple en todo el intervalo de fondos.
    @MainActor func readableForeground(_ preferred: Color, on backgrounds: [Color],
                                       overlay: Color? = nil, minimumContrast: Double = 4.5) -> Color? {
        NativeForegroundContrast.select(on: backgrounds, overlay: overlay, preferred: preferred,
                                        fallback: textPrimary, scheme: colorScheme,
                                        minimumContrast: minimumContrast)
    }
}

@MainActor private enum NativeForegroundContrast {
    private struct Key: Hashable {
        let background: Color
        let accent: Color?
        let fallback: Color?
        let appearance: String
        let minimumContrast: Double
    }

    private struct RGBA {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        static func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }

        var luminance: Double {
            0.2126 * Self.linear(red) + 0.7152 * Self.linear(green) + 0.0722 * Self.linear(blue)
        }

        func contrast(on background: RGBA) -> Double? {
            guard background.alpha >= 0.999999 else { return nil }
            let gammaBlend = RGBA(red: red * alpha + background.red * (1 - alpha),
                                  green: green * alpha + background.green * (1 - alpha),
                                  blue: blue * alpha + background.blue * (1 - alpha), alpha: 1).luminance
            let linearBlend = luminance * alpha + background.luminance * (1 - alpha)
            func ratio(_ foreground: Double) -> Double {
                (max(foreground, background.luminance) + 0.05) / (min(foreground, background.luminance) + 0.05)
            }
            // El velo puede mezclarse en sRGB o lineal; exigimos el peor de ambos.
            return min(ratio(gammaBlend), ratio(linearBlend))
        }
    }

    // Incluye la apariencia para no conservar la resolución de un color dinámico al cambiar de tema.
    private static var cache: [Key: Color] = [:]
    private struct CompositeKey: Hashable {
        let backgrounds: [Color]
        let overlay: Color?
        let preferred: Color
        let fallback: Color
        let appearance: String
        let minimumContrast: Double
    }
    private struct CompositeResult { let color: Color? }
    private static var compositeCache: [CompositeKey: CompositeResult] = [:]

    private static func reserveCacheEntry() {
        if cache.count + compositeCache.count >= 512 {
            cache.removeAll(keepingCapacity: true)
            compositeCache.removeAll(keepingCapacity: true)
        }
    }

    static func select(on background: Color, accent: Color? = nil, fallback: Color? = nil,
                       scheme: ColorScheme? = nil, minimumContrast: Double = 4.5) -> Color {
        let appearance = scheme.flatMap { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua) }
            ?? NSAppearance.currentDrawing()
        let key = Key(background: background, accent: accent, fallback: fallback,
                      appearance: appearance.name.rawValue, minimumContrast: minimumContrast)
        if let cached = cache[key] { return cached }
        var result = Color.primary
        appearance.performAsCurrentDrawingAppearance {
            guard let base = components(background) else { return }
            if let accent, let color = components(accent),
               let contrast = color.contrast(on: base), contrast >= minimumContrast {
                result = accent
            } else if let fallback, let color = components(fallback),
                      let contrast = color.contrast(on: base), contrast >= minimumContrast {
                result = fallback
            } else {
                let black = (base.luminance + 0.05) / 0.05
                let white = 1.05 / (base.luminance + 0.05)
                result = black >= white ? .black : .white
            }
        }
        reserveCacheEntry()
        cache[key] = result
        return result
    }

    static func select(on backgrounds: [Color], overlay: Color?, preferred: Color,
                       fallback: Color, scheme: ColorScheme, minimumContrast: Double) -> Color? {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            ?? NSAppearance.currentDrawing()
        let key = CompositeKey(backgrounds: backgrounds, overlay: overlay, preferred: preferred,
                               fallback: fallback, appearance: appearance.name.rawValue,
                               minimumContrast: minimumContrast)
        if let cached = compositeCache[key] { return cached.color }
        var result: Color?
        appearance.performAsCurrentDrawingAppearance {
            let bases = backgrounds.compactMap(components)
            guard !bases.isEmpty, bases.count == backgrounds.count,
                  bases.allSatisfy({ $0.alpha >= 0.999999 }) else { return }
            var fills = bases
            if let overlay {
                guard let veil = components(overlay) else { return }
                func gamma(_ value: Double) -> Double {
                    value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
                }
                fills = bases.flatMap { base in
                    let a = veil.alpha
                    return [
                        RGBA(red: veil.red * a + base.red * (1 - a),
                             green: veil.green * a + base.green * (1 - a),
                             blue: veil.blue * a + base.blue * (1 - a), alpha: 1),
                        RGBA(red: gamma(RGBA.linear(veil.red) * a + RGBA.linear(base.red) * (1 - a)),
                             green: gamma(RGBA.linear(veil.green) * a + RGBA.linear(base.green) * (1 - a)),
                             blue: gamma(RGBA.linear(veil.blue) * a + RGBA.linear(base.blue) * (1 - a)), alpha: 1)
                    ]
                }
            }
            // La caja RGB contiene también los puntos intermedios del degradado, no solo sus extremos.
            let low = RGBA(red: fills.map(\.red).min()!, green: fills.map(\.green).min()!,
                           blue: fills.map(\.blue).min()!, alpha: 1)
            let high = RGBA(red: fills.map(\.red).max()!, green: fills.map(\.green).max()!,
                            blue: fills.map(\.blue).max()!, alpha: 1)
            func minimum(_ color: RGBA) -> Double {
                let a = color.alpha
                let gammaLow = RGBA(red: color.red * a + low.red * (1 - a),
                                    green: color.green * a + low.green * (1 - a),
                                    blue: color.blue * a + low.blue * (1 - a), alpha: 1).luminance
                let gammaHigh = RGBA(red: color.red * a + high.red * (1 - a),
                                     green: color.green * a + high.green * (1 - a),
                                     blue: color.blue * a + high.blue * (1 - a), alpha: 1).luminance
                func intervalRatio(_ lower: Double, _ upper: Double) -> Double {
                    if lower > high.luminance { return (lower + 0.05) / (high.luminance + 0.05) }
                    if upper < low.luminance { return (low.luminance + 0.05) / (upper + 0.05) }
                    return 1
                }
                return min(intervalRatio(gammaLow, gammaHigh),
                           intervalRatio(color.luminance * a + low.luminance * (1 - a),
                                         color.luminance * a + high.luminance * (1 - a)))
            }
            for candidate in [preferred, fallback, Color.black, Color.white] {
                if let color = components(candidate), minimum(color) >= minimumContrast {
                    result = candidate
                    break
                }
            }
        }
        reserveCacheEntry()
        compositeCache[key] = CompositeResult(color: result)
        return result
    }

    private static func components(_ color: Color) -> RGBA? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return RGBA(red: Double(rgb.redComponent), green: Double(rgb.greenComponent),
                    blue: Double(rgb.blueComponent), alpha: Double(rgb.alphaComponent))
    }
}

extension View {
    /// Conserva el tinte cuando cumple AA sobre los fondos conocidos; el respaldo solo cubre el texto.
    @MainActor func readableTint(_ color: Color, palette: ThemePalette, on backgrounds: [Color],
                                overlay: Color? = nil, minimumContrast: Double = 4.5) -> some View {
        let foreground = palette.readableForeground(color, on: backgrounds, overlay: overlay,
                                                     minimumContrast: minimumContrast)
        return foregroundStyle(foreground ?? palette.textPrimary)
            .background {
                if foreground == nil { palette.surface }
            }
    }

    /// Re-inyecta el TEMA ACTIVO (paleta CON el acento personalizado del usuario + tint + esquema)
    /// en una hoja/overlay presentado. En macOS los `.sheet` NO heredan de forma fiable los
    /// `EnvironmentKey` personalizados del presentador, así que el modal salía con el acento por
    /// DEFECTO del tema (dorado) en vez del elegido por el usuario (p. ej. salmón). Aplícalo al
    /// contenido de cada `.sheet` para que herede exactamente la misma piel que la ventana.
    func themedSheet(_ palette: ThemePalette, _ theme: Theme) -> some View {
        environment(\.themePalette, palette)
            .environment(\.appTheme, theme)
            .tint(palette.accent)
            .preferredColorScheme(theme.preferredColorScheme)
            // Tooltips temáticos también dentro de la hoja (su propia capa, con la paleta explícita).
            .tooltipLayer(palette)
    }

    /// Variante para vistas que solo tienen la paleta a mano (no el `Theme`): igualmente re-inyecta
    /// la paleta CON el acento personalizado y el `tint`, que es lo que se perdía en los sheets.
    func themedSheet(_ palette: ThemePalette) -> some View {
        environment(\.themePalette, palette)
            .tint(palette.accent)
            .tooltipLayer(palette)
    }
}

struct WindowChrome: NSViewRepresentable {
    var background: Color
    /// `true` (ventana principal, NavigationSplitView): el contenido sube BAJO el titlebar para el
    /// look inmersivo. `false` (ventana de Ajustes con `TabView` de preferencias): el contenido NO
    /// sube, si no la barra de pestañas se SUPERPONE con el contenido scrolleado por detrás.
    var fullSize: Bool = true

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        apply(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(from: nsView)
    }

    private func apply(from view: NSView) {
        let color = NSColor(background)
        // La ventana puede no existir aún en el primer ciclo de layout: difiere al runloop.
        DispatchQueue.main.async { [weak view, fullSize] in
            guard let window = view?.window else { return }
            window.titlebarAppearsTransparent = true
            window.backgroundColor = color
            window.isOpaque = true
            if fullSize { window.styleMask.insert(.fullSizeContentView) }
            else { window.styleMask.remove(.fullSizeContentView) }
            Self.configureSystemToolbarTooltips(in: window)

            // SwiftUI registra algunos ítems predeterminados (como el toggle del sidebar)
            // después del primer ciclo del titlebar. Una segunda pasada acotada completa
            // su tooltip sin sustituir ni duplicar el control nativo.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak window] in
                guard let window else { return }
                Self.configureSystemToolbarTooltips(in: window)
            }
        }
    }

    @MainActor
    private static func configureSystemToolbarTooltips(in window: NSWindow) {
        guard let toolbar = window.toolbar else { return }
        let toggleSidebar = #selector(NSSplitViewController.toggleSidebar(_:))
        for item in toolbar.items where item.action == toggleSidebar {
            let tooltip = "Mostrar u ocultar la barra lateral"
            item.toolTip = tooltip
            item.view?.toolTip = tooltip
        }
    }
}
