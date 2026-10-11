import SwiftUI
import StacklumeDesignSystem

/// Muestra canónica de tema, compartida por Apariencia y el ensayo nativo sin persistencia propia.
struct ThemeSwatch: View {
    let theme: Theme
    let systemScheme: ColorScheme
    let isSelected: Bool
    let onSelect: () -> Void
    @Environment(\.themePalette) private var palette

    var body: some View {
        let preview = theme.palette(systemScheme: systemScheme)
        return Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    // Mini-mockup representativo: barra de acento, dos líneas de texto y
                    // una tarjeta con el color de superficie.
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(preview.background)
                        .overlay(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 5) {
                                Capsule().fill(preview.accent).frame(width: 26, height: 6)
                                RoundedRectangle(cornerRadius: 2).fill(preview.textPrimary.opacity(0.9))
                                    .frame(width: 46, height: 5)
                                RoundedRectangle(cornerRadius: 2).fill(preview.textSecondary.opacity(0.7))
                                    .frame(width: 32, height: 5)
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(preview.surface)
                                    .frame(height: 16)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .strokeBorder(preview.border, lineWidth: 0.5)
                                    )
                            }
                            .padding(9)
                        }

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .scaledFont(17, weight: .bold, scalesWithText: false)
                            .foregroundStyle(palette.foreground(on: palette.accent), palette.accent)
                            .padding(6)
                    }
                }
                .frame(height: 76)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isSelected ? palette.readableAccent(on: preview.background, minimumContrast: 3) : preview.border,
                                      lineWidth: isSelected ? 2.5 : 1)
                )
                .shadow(color: isSelected ? palette.accent.opacity(0.25) : .clear, radius: 6)

                Text(theme.displayName)
                    .stacklumeFont(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(palette.textPrimary)
                    .stacklumeLineLimit(1)
                    .stacklumeMinimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(theme.displayName)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
