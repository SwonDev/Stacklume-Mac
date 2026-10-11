import SwiftUI
import StacklumeDesignSystem

/// Imagen de respaldo para tarjetas de feed RSS/Atom cuando no hay portada ni favicon
/// disponible. Dibuja un degradado radial con el color de acento y la inicial en
/// mayúscula del título del feed, centrada. Diseñado para encajar en el mismo marco y
/// `clipShape` que usa `RSSItemRow` (y similar a la portada de logo centrado de la
/// biblioteca sin og:image).
///
/// Uso mínimo:
/// ```swift
/// FeedFallbackImage(title: item.title)
///     .frame(width: 38, height: 30)
///     .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
/// ```
struct FeedFallbackImage: View {
    @Environment(\.themePalette) private var palette
    let title: String
    /// Color de acento (por defecto usa el dorado de la paleta de tema).
    var tint: Color? = nil

    private var accent: Color { tint ?? palette.accent }

    /// Primera letra en mayúscula del título, ignorando espacios/símbolos al inicio.
    private var initial: String {
        title.first(where: { $0.isLetter || $0.isNumber })
            .map { String($0).uppercased() } ?? "?"
    }

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [accent.opacity(0.28), accent.opacity(0.08)],
                center: .center,
                startRadius: 0,
                endRadius: 32
            )
            Text(initial)
                .stacklumeFont(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
        }
    }
}
