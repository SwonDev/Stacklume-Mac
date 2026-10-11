import SwiftUI

/// Placeholder animado (shimmer) que reserva el espacio mientras carga contenido
/// remoto —p. ej. las portadas de los enlaces—, evitando el «pop» al aparecer la
/// imagen. Respeta «Reducir movimiento»: en ese caso muestra un fondo estático sutil
/// sin el barrido luminoso.
public struct SkeletonView: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    public init() {}

    public var body: some View {
        let base = palette.textSecondary.opacity(0.10)
        Rectangle()
            .fill(base)
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        let w = geo.size.width
                        LinearGradient(
                            colors: [.clear, palette.textSecondary.opacity(0.16), .clear],
                            startPoint: .leading, endPoint: .trailing)
                        .frame(width: w * 0.6, height: geo.size.height)
                        // Barre de fuera-izquierda a fuera-derecha, en bucle.
                        .offset(x: animating ? w * 1.0 : -w * 0.6)
                    }
                }
            }
            .clipped()
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    animating = true
                }
            }
            .accessibilityHidden(true)
    }
}
