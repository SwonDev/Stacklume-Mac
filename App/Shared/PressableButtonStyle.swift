import SwiftUI

/// Estilo de botón con una micro-interacción premium: al pulsar, el contenido se
/// encoge muy levemente (y baja la opacidad) con una curva corta, y vuelve al
/// soltar. Pensado para botones de icono `plain` que de otro modo no tienen
/// feedback de pulsación en macOS. NO usar sobre botones de cristal (`.glass`/
/// `.glassProminent`): esos ya traen su propio realce nativo y reemplazarlo
/// rompería el efecto Liquid Glass de DESIGN.md.
///
/// Respeta Reduce Motion: si está activo, no aplica escala (solo el cambio de
/// opacidad mínimo del sistema), evitando movimiento decorativo.
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.nativeUIQAAccessibility) private var qaAccessibility
    private var reduceMotion: Bool { qaAccessibility?.motion(system: systemReduceMotion) ?? systemReduceMotion }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(scale(for: configuration.isPressed))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7),
                       value: configuration.isPressed)
    }

    private func scale(for isPressed: Bool) -> CGFloat {
        guard !reduceMotion else { return 1 }
        return isPressed ? 0.92 : 1
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// Acceso cómodo: `.buttonStyle(.pressable)`.
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}
