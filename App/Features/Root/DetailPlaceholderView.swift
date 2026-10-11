import SwiftUI
import StacklumeDesignSystem

/// Columna 3 sin selección: estado vacío premium con el escudo de Stacklume tenue
/// y una invitación discreta. Centrado sobre el fondo de ventana con profundidad,
/// fiel a la calma visual del rediseño.
struct DetailPlaceholderView: View {
    @Environment(\.themePalette) private var palette

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            Image("StacklumeLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .opacity(0.28)
                .shadow(color: palette.accent.opacity(0.22), radius: 26, y: 10)
                .accessibilityHidden(true)  // Decorativo: VoiceOver ya lee el texto de invitación

            VStack(spacing: DesignSystem.Spacing.xs) {
                Text("Selecciona un enlace para ver su ficha")
                    .stacklumeFont(.title3.weight(.semibold))
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
                Text("Aquí aparecerán su portada, sus metadatos y sus acciones.")
                    .stacklumeFont(.callout)
                    .foregroundStyle(palette.textSecondary.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowBackground())
    }
}
