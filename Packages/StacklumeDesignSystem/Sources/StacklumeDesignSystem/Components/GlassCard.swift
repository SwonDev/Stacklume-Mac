import SwiftUI

/// Tarjeta de superficie temada. Usa el color de superficie del tema y un borde
/// sutil; las barras del sistema obtienen Liquid Glass automáticamente en iOS 26.
public struct GlassCard<Content: View>: View {
    @Environment(\.themePalette) private var palette
    private let cornerRadius: CGFloat
    private let padding: CGFloat
    private let content: Content

    public init(
        cornerRadius: CGFloat = DesignSystem.cornerRadius,
        padding: CGFloat = DesignSystem.Spacing.md,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(palette.surface)
                    .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 0.5)
            )
    }
}
