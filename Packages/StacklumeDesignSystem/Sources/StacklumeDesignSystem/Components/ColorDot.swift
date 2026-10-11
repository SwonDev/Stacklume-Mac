import SwiftUI

/// Punto de color (para categorías y etiquetas).
public struct ColorDot: View {
    private let colorHex: String
    private let size: CGFloat

    public init(colorHex: String, size: CGFloat = 12) {
        self.colorHex = colorHex
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(Color(hex: colorHex))
            .frame(width: size, height: size)
            .overlay(
                Circle().strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
            )
    }
}

/// Etiqueta visual de una tag (punto + nombre).
public struct TagChip: View {
    @Environment(\.themePalette) private var palette
    private let name: String
    private let colorHex: String

    public init(name: String, colorHex: String) {
        self.name = name
        self.colorHex = colorHex
    }

    public var body: some View {
        HStack(spacing: DesignSystem.Spacing.xxs) {
            ColorDot(colorHex: colorHex, size: 8)
            Text(name)
                .font(.caption)
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)                 // nunca parte el nombre en vertical
                .truncationMode(.tail)
        }
        // El chip toma su ancho natural en una sola línea; si el contenedor es
        // estrecho, se recorta con "…" en vez de crecer en vertical.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, DesignSystem.Spacing.xs)
        .padding(.vertical, DesignSystem.Spacing.xxs)
        .background(
            Capsule().fill(Color(hex: colorHex).opacity(0.15))
        )
        .overlay(
            Capsule().strokeBorder(Color(hex: colorHex).opacity(0.4), lineWidth: 0.5)
        )
    }
}
