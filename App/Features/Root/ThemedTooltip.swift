import SwiftUI
import StacklumeDesignSystem

/// Tooltips con la estética de Stacklume (según el tema activo) en lugar del tooltip GRIS del
/// sistema (`.help(...)` nativo, que no se puede tematizar). Sustituye a `.help` en toda la app:
/// `.themedHelp("texto")` en vez de `.help("texto")`.
///
/// Cómo funciona (mismo patrón que el hover preview de la biblioteca, [[preview-hover-bocadillo]]):
/// el modifier detecta el `onHover` (con un retardo, como el sistema) y, mientras está activo,
/// publica por una `anchorPreference` el rectángulo del elemento + el texto. Una ÚNICA capa
/// (`.tooltipLayer()`, puesta en cada superficie raíz: ventana, hojas, Ajustes, Ayuda, menubar)
/// lee esa preferencia y dibuja el bocadillo POR ENCIMA de todo, colocado arriba o abajo según el
/// espacio. Así nunca se recorta dentro de listas/contenedores y siempre usa el color del tema.
///
/// Accesibilidad: `themedHelp` añade además `accessibilityHint`, así que VoiceOver conserva la
/// ayuda que daba `.help` (no se pierde nada al migrar).

/// Lo que un elemento «con tooltip» publica mientras tiene el ratón encima.
struct TooltipRequest: Equatable {
    let text: String
    let anchor: Anchor<CGRect>
    // `Anchor` no es Equatable; basta comparar el texto (solo hay un tooltip activo a la vez).
    static func == (lhs: TooltipRequest, rhs: TooltipRequest) -> Bool { lhs.text == rhs.text }
}

/// Preferencia que lleva el tooltip activo (o `nil`) hasta la capa que lo dibuja.
struct TooltipPreferenceKey: PreferenceKey {
    static let defaultValue: TooltipRequest? = nil
    static func reduce(value: inout TooltipRequest?, nextValue: () -> TooltipRequest?) {
        if let next = nextValue() { value = next }
    }
}

/// Modifier que reemplaza a `.help`: muestra el tooltip temático tras un breve hover.
private struct ThemedHelpModifier: ViewModifier {
    let text: String
    @State private var active = false
    /// Cambia en cada entrada/salida del ratón: invalida los retardos pendientes (anti-parpadeo).
    @State private var hoverToken = 0

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hoverToken += 1
                if inside {
                    let token = hoverToken
                    Task { @MainActor in
                        // Retardo similar al del sistema, algo más ágil en controles densos.
                        try? await Task.sleep(for: .milliseconds(480))
                        if token == hoverToken { active = true }
                    }
                } else {
                    active = false
                }
            }
            .anchorPreference(key: TooltipPreferenceKey.self, value: .bounds) { anchor in
                active && !text.isEmpty ? TooltipRequest(text: text, anchor: anchor) : nil
            }
    }
}

/// Tooltip Liquid Glass compacto. El respaldo navy evita que un acento intenso situado
/// detrás contamine la lente; el cristal sigue siendo neutro y conserva la refracción.
private struct TooltipTextLayout: Layout {
    let maximumWidth: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let text = subviews.first else { return .zero }
        let ideal = text.sizeThatFits(.unspecified)
        let available = proposal.width.map { min($0, maximumWidth) } ?? maximumWidth
        let width = min(ideal.width, available)
        let fitted = text.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: ceil(width), height: ceil(fitted.height))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let text = subviews.first else { return }
        text.place(
            at: CGPoint(x: bounds.midX, y: bounds.midY),
            anchor: .center,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

private struct ThemedTooltipBubble: View {
    let text: String
    let palette: ThemePalette
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        TooltipTextLayout(maximumWidth: 278) {
            Text(text)
                .stacklumeFont(.caption.weight(.medium))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(3)
                .multilineTextAlignment(.center)
        }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(palette.background.opacity(0.34), in: shape)
            .stacklumeGlass(in: shape)
            .overlay {
                shape.strokeBorder(
                    palette.textPrimary.opacity(contrast == .increased ? 0.34 : 0.15),
                    lineWidth: contrast == .increased ? 1 : 0.6
                )
            }
            .shadow(color: .black.opacity(0.38), radius: 16, y: 7)
            .accessibilityHidden(true)
    }
}

/// Capa que dibuja el tooltip activo por encima de su contenido. Se aplica una vez por
/// «superficie» (ventana principal, cada hoja, Ajustes, Ayuda, popover del menubar).
private struct TooltipLayerModifier: ViewModifier {
    /// Palette explícita (la pasan las hojas/menubar, que inyectan el tema por su cuenta y cuyo
    /// `@Environment` aquí aún no lo tendría); si es `nil`, se usa el del entorno.
    var paletteOverride: ThemePalette?
    @Environment(\.themePalette) private var envPalette
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.nativeUIQAAccessibility) private var qaAccessibility
    private var reduceMotion: Bool { qaAccessibility?.motion(system: systemReduceMotion) ?? systemReduceMotion }
    @State private var tipSize: CGSize = .zero

    private var palette: ThemePalette { paletteOverride ?? envPalette }

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(TooltipPreferenceKey.self) { request in
            GeometryReader { geo in
                if let request {
                    let rect = geo[request.anchor]
                    let margin: CGFloat = 8
                    // Arriba si cabe; si no, debajo (p. ej. botones pegados al borde superior).
                    let above = rect.minY > tipSize.height + margin + 4
                    let centerY = above
                        ? rect.minY - margin - tipSize.height / 2
                        : rect.maxY + margin + tipSize.height / 2
                    // Centrado sobre el elemento, sin salirse por los lados de la superficie.
                    let halfW = tipSize.width / 2
                    let centerX = min(max(rect.midX, halfW + 6), geo.size.width - halfW - 6)
                    ThemedTooltipBubble(text: request.text, palette: palette)
                        .id(request.text)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { tipSize = $0 }
                        .position(x: centerX, y: centerY)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .scale(scale: 0.96).combined(with: .opacity)
                        )
                }
            }
            .allowsHitTesting(false)   // el tooltip NUNCA roba clics/hover al contenido
            .animation(
                reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.84),
                value: request
            )
        }
    }
}

extension View {
    /// Tooltip temático (sustituye a `.help`). Úsalo SIEMPRE en vez de `.help` para que la ayuda
    /// emergente siga la estética de Stacklume. Conserva la ayuda de VoiceOver (`accessibilityHint`).
    func themedHelp(_ text: String) -> some View {
        modifier(ThemedHelpModifier(text: text))
            .accessibilityHint(Text(text))
    }

    /// Coloca la capa que dibuja los tooltips temáticos. Aplícala una vez en la raíz de cada
    /// superficie con su propia ventana (ventana principal, hojas, Ajustes, Ayuda, menubar).
    /// `palette` explícita para superficies que inyectan el tema por su cuenta (hojas, menubar).
    func tooltipLayer(_ palette: ThemePalette? = nil) -> some View {
        modifier(TooltipLayerModifier(paletteOverride: palette))
    }
}
