import SwiftUI
import StacklumeDesignSystem

/// Estado vacío premium reutilizable: un icono dentro de una pieza de Liquid Glass
/// con tinte de acento, título y mensaje cuidados, y una acción opcional como
/// botón de cristal prominente. Sobre el fondo de ventana con profundidad.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    @Environment(\.themePalette) private var palette

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            // Navy + dorado PREMIUM: círculo de navy profundo con un anillo dorado
            // fino y NÍTIDO (gradiente vertical, iluminado desde arriba) e icono
            // dorado jerárquico. Profundidad con sombra neutra; nada de halo dorado
            // difuso ni cristal tintado (lo que abarataba la estética).
            Image(systemName: icon)
                .scaledFont(30, weight: .light, scalesWithText: false)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(palette.accent)
                .frame(width: 88, height: 88)
                .background(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [palette.surface, palette.background],
                                startPoint: .top, endPoint: .bottom)
                        )
                        .overlay(
                            Circle().strokeBorder(
                                LinearGradient(
                                    colors: [palette.accent.opacity(0.55), palette.accent.opacity(0.12)],
                                    startPoint: .top, endPoint: .bottom),
                                lineWidth: 1)
                        )
                )
                .shadow(color: .black.opacity(0.40), radius: 14, y: 8)
                .accessibilityHidden(true)  // Decorativo: VoiceOver ya lee el título y el mensaje

            VStack(spacing: DesignSystem.Spacing.xs) {
                Text(title)
                    .stacklumeFont(.title2.weight(.semibold))
                    .foregroundStyle(palette.textPrimary)
                Text(message)
                    .stacklumeFont(.callout)
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 360)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Label(actionTitle, systemImage: "plus")
                        .stacklumeFont(.callout.weight(.semibold))
                        .padding(.horizontal, DesignSystem.Spacing.sm)
                        .padding(.vertical, 4)
                }
                .stacklumeButton()
                .padding(.top, DesignSystem.Spacing.xs)
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowBackground())
    }
}
