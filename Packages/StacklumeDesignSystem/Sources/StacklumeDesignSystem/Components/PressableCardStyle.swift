import SwiftUI

/// Estilo de botón para tarjetas: al pulsar, un ligero hundimiento (escala + opacidad)
/// con muelle, para una sensación táctil premium. Respeta «Reducir movimiento»
/// (sin escala). Pensado para tarjetas visuales (cuadrícula, moodboard, widgets),
/// no para filas de lista (donde compite con el swipe).
public struct PressableCardStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == PressableCardStyle {
    /// Hundimiento sutil al pulsar, para tarjetas visuales.
    static var pressableCard: PressableCardStyle { PressableCardStyle() }
}
