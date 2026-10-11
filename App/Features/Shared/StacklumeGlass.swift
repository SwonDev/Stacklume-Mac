import SwiftUI
import StacklumeDesignSystem

/// Primitivas canónicas de Liquid Glass de Stacklume.
///
/// El cristal pertenece exclusivamente a la capa funcional: navegación, controles,
/// cabeceras y overlays. El color de marca nunca rellena el cristal; aparece como un
/// velo y un borde de baja opacidad para conservar la refracción nativa de macOS.
private struct StacklumeLiquidGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool

    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.nativeUIQAAccessibility) private var qaAccessibility
    private var reduceTransparency: Bool { qaAccessibility?.transparency(system: systemReduceTransparency) ?? systemReduceTransparency }
    @Environment(\.colorSchemeContrast) private var systemContrast
    private var contrast: ColorSchemeContrast { qaAccessibility?.contrast(system: systemContrast) ?? systemContrast }

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(palette.surface.opacity(0.98), in: shape)
                .overlay {
                    shape.stroke(
                        palette.textPrimary.opacity(contrast == .increased ? 0.34 : 0.16),
                        lineWidth: contrast == .increased ? 1 : 0.5
                    )
                }
        } else {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        }
    }
}

extension View {
    /// Liquid Glass neutro con respaldo opaco automático para «Reducir transparencia».
    /// Debe aplicarse después de resolver tamaño, relleno y forma del componente.
    func stacklumeGlass(in shape: some Shape, interactive: Bool = false) -> some View {
        modifier(StacklumeLiquidGlassModifier(shape: shape, interactive: interactive))
    }

    /// Agrupa controles de cristal próximos para que el compositor los trate como una
    /// única familia y evite que un efecto intente muestrear otro.
    func stacklumeGlassContainer(spacing: CGFloat = DesignSystem.Spacing.xs) -> some View {
        GlassEffectContainer(spacing: spacing) { self }
    }
}

/// Fondo de cristal para superficies funcionales amplias. Se coloca detrás del contenido,
/// de modo que títulos e iconos permanecen nítidos y el efecto nunca interfiere con eventos.
struct StacklumeGlassBackdrop<S: Shape>: View {
    let shape: S
    var tint: Color? = nil
    var tintOpacity: Double = 0.08
    var surfaceOpacity: Double = 0.24
    var borderOpacity: Double = 0.10

    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.nativeUIQAAccessibility) private var qaAccessibility
    private var reduceTransparency: Bool { qaAccessibility?.transparency(system: systemReduceTransparency) ?? systemReduceTransparency }
    @Environment(\.colorSchemeContrast) private var systemContrast
    private var contrast: ColorSchemeContrast { qaAccessibility?.contrast(system: systemContrast) ?? systemContrast }

    var body: some View {
        ZStack {
            shape.fill(palette.surface.opacity(reduceTransparency ? 0.98 : surfaceOpacity))
            if let tint {
                shape.fill(tint.opacity(reduceTransparency ? tintOpacity * 0.45 : tintOpacity))
            }
        }
        .stacklumeGlass(in: shape)
        .overlay {
            shape.stroke(
                palette.textPrimary.opacity(contrast == .increased ? 0.30 : borderOpacity),
                lineWidth: contrast == .increased ? 1 : 0.5
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Botón canónico de Stacklume: cristal interactivo neutro, con velo dorado solo en
/// la acción principal. Sustituye a la mezcla de `.glass`, `.glassProminent` y estilos
/// sólidos que daba pesos visuales distintos en cada pantalla.
struct StacklumeGlassButtonStyle: ButtonStyle {
    var prominent = true
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        StacklumeGlassButtonBody(
            configuration: configuration,
            prominent: prominent,
            compact: compact
        )
    }

    private struct StacklumeGlassButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let compact: Bool

        @Environment(\.themePalette) private var palette
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
        @Environment(\.nativeUIQAAccessibility) private var qaAccessibility
        private var reduceMotion: Bool { qaAccessibility?.motion(system: systemReduceMotion) ?? systemReduceMotion }
        @Environment(\.colorSchemeContrast) private var systemContrast
        private var contrast: ColorSchemeContrast { qaAccessibility?.contrast(system: systemContrast) ?? systemContrast }
        @State private var hovering = false

        var body: some View {
            let shape = Capsule(style: .continuous)
            configuration.label
                .foregroundStyle(palette.textPrimary)
                .padding(.horizontal, compact ? 7 : 16)
                .padding(.vertical, compact ? 4 : 8)
                .background {
                    if prominent {
                        shape.fill(palette.accent.opacity(hovering ? 0.16 : 0.10))
                    }
                }
                .stacklumeGlass(in: shape, interactive: true)
                .overlay {
                    shape.strokeBorder(
                        prominent
                            ? palette.accent.opacity(contrast == .increased ? 0.72 : (hovering ? 0.52 : 0.40))
                            : palette.textPrimary.opacity(contrast == .increased ? 0.30 : 0.12),
                        lineWidth: contrast == .increased ? 1 : 0.75
                    )
                }
                .clipShape(shape)
                .shadow(
                    color: .black.opacity(hovering ? 0.30 : 0.18),
                    radius: hovering ? 10 : 6,
                    y: hovering ? 4 : 3
                )
                .brightness(configuration.isPressed ? -0.04 : 0)
                .scaleEffect(
                    reduceMotion ? 1 : (configuration.isPressed ? 0.97 : (hovering ? 1.015 : 1))
                )
                .opacity(isEnabled ? 1 : 0.48)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.76),
                    value: hovering
                )
                .animation(
                    reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.72),
                    value: configuration.isPressed
                )
                .onHover { hovering = $0 }
                .contentShape(shape)
        }
    }
}

extension View {
    /// Aplica el botón Liquid Glass canónico. `prominent` solo añade orientación de
    /// acento; `compact` está pensado para acciones de icono y grupos densos.
    func stacklumeButton(prominent: Bool = true, compact: Bool = false) -> some View {
        buttonStyle(StacklumeGlassButtonStyle(prominent: prominent, compact: compact))
    }
}
