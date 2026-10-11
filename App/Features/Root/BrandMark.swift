import SwiftUI
import StacklumeDesignSystem

/// Marca de Stacklume (isotipo dorado + wordmark) para la cabecera del sidebar,
/// igual que en la app original.
struct BrandMark: View {
    @Environment(\.themePalette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image("StacklumeLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .shadow(color: palette.accent.opacity(0.40), radius: 8, y: 2)
            Text("Stacklume")
                .stacklumeFont(.title3.weight(.bold))
                .foregroundStyle(palette.textPrimary)
            Spacer(minLength: 0)

            Button {
                NotificationCenter.default.post(name: .stacklumeOpenCommandPalette, object: nil)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                    Text("⌘K")
                        .stacklumeFont(.caption2.monospaced())
                }
            }
            .stacklumeButton(prominent: false, compact: true)
            .controlSize(.small)
            .themedHelp("Buscar enlaces, colecciones y secciones")
            .accessibilityLabel("Buscar en Stacklume")
            .accessibilityHint("Abre la búsqueda global")
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, 10)
        // Lente local dentro del rail: refracta las filas que pasan por debajo y evita
        // cualquier solapamiento legible, sin volver al antiguo marco rectangular.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            StacklumeGlassBackdrop(
                shape: shape,
                tint: palette.accent,
                tintOpacity: 0.025,
                surfaceOpacity: 0.20,
                borderOpacity: 0.11
            )
        }
        .clipShape(shape)
        .shadow(color: .black.opacity(0.22), radius: 11, y: 5)
        // Junta mínima: se distingue la zona fija sin separarla visualmente del árbol.
        .padding(.horizontal, 5)
        .padding(.top, 5)
        .padding(.bottom, 1)
    }
}
