import SwiftUI
import StacklumeDesignSystem

/// Presentación canónica de la burbuja; el llamador conserva la selección y preparación del contenido.
struct ChatBubble<Content: View>: View {
    let isUser: Bool
    let availableWidth: CGFloat
    @ViewBuilder var content: () -> Content
    @Environment(\.themePalette) private var palette
    @Environment(\.stacklumeTextScale) private var textScale

    var body: some View {
        Group { content() }
        .stacklumeDefaultFont(factor: textScale)
        // Fija la propuesta del texto antes de activar la selección nativa. Así las
        // medidas ideal/mínima de stacks superiores nunca ensanchan el texto completo.
        .frame(width: max(1, availableWidth - 24), alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .foregroundStyle(isUser ? palette.foreground(on: palette.accent) : palette.textPrimary)
        .tint(isUser ? palette.foreground(on: palette.accent) : palette.readableAccent(on: palette.surface))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isUser ? palette.accent : palette.surface,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
