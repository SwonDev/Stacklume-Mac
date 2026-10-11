import SwiftUI
import StacklumeCore
import StacklumeDesignSystem

/// Insignia de la plataforma de un enlace: símbolo sobre el color de marca, en
/// una pieza redondeada. Tamaño configurable.
struct PlatformBadge: View {
    let platform: Platform
    var size: CGFloat = 36

    private var brand: Color { Color(hex: platform.brandColorHex) }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(brand.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: platform.sfSymbol)
                    .scaledFont(size * 0.46, weight: .semibold, scalesWithText: false)
                    .foregroundStyle(.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: brand.opacity(0.35), radius: 5, y: 2)
    }
}

/// Mosaico de respaldo con la INICIAL del dominio sobre un color estable derivado del propio
/// dominio. Sustituye al globo genérico (`PlatformBadge` de plataforma `.generic`) cuando un
/// enlace NO tiene un favicon que cargue: siempre se ve intencionado e identifica el sitio de
/// un vistazo, en vez del globo «roto» que el usuario quería desterrar.
///
/// El color es DETERMINISTA: el mismo dominio recibe siempre el mismo color entre arranques
/// (hash propio djb2, NO `hashValue`, cuya semilla cambia por sesión y haría parpadear el color).
struct MonogramTile: View {
    /// Host o título del que sacar la inicial y el color (basta el host del enlace).
    let text: String
    var size: CGFloat = 36

    /// Paleta cálida coherente con la del resto de la app (misma que usa el autotagger).
    private static let palette = [
        "#D4A853", "#F05138", "#FF6B6B", "#FF8C42", "#34D399", "#4ECDC4",
        "#0066FF", "#7AA2F7", "#C8A8FF", "#A259FF", "#FF4FA3", "#1DB954",
    ]

    private var initial: String {
        let firstLetter = text.first { $0.isLetter || $0.isNumber }
        return firstLetter.map { String($0).uppercased() } ?? "•"
    }

    private var color: Color {
        var hash: UInt64 = 5381
        for byte in text.lowercased().utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return Color(hex: Self.palette[Int(hash % UInt64(Self.palette.count))])
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(initial)
                    .scaledFont(size * 0.46, weight: .semibold, scalesWithText: false)
                    .foregroundStyle(.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: color.opacity(0.35), radius: 5, y: 2)
    }
}
