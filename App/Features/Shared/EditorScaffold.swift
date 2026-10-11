import SwiftUI
import StacklumeDesignSystem

/// Marco común y TEMATIZADO para las hojas de edición (categoría, etiqueta, proyecto…):
/// cabecera con título, contenido (normalmente un `Form`) y pie con Cancelar/Confirmar,
/// todo sobre `WindowBackground()` con los tokens del tema. Sustituye al `NavigationStack`
/// + `toolbar` del sistema, cuyas barras grises no se adaptaban al tema elegido.
///
/// Conserva el comportamiento de teclado del sistema: Intro confirma (`.defaultAction`) y
/// Escape cancela (`.cancelAction`).
struct EditorScaffold<Content: View>: View {
    let title: String
    let confirmTitle: String
    var canConfirm: Bool = true
    /// Texto del botón secundario (Cancelar). `nil` lo OCULTA: para paneles con un solo
    /// botón de cierre (Ajustes, paneles informativos) donde «Cancelar» no aporta.
    var cancelTitle: String? = "Cancelar"
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @ViewBuilder var content: () -> Content

    @Environment(\.themePalette) private var palette
    @Environment(\.stacklumeTextScale) private var textScale

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .stacklumeFont(.title3.weight(.bold))
                    .foregroundStyle(palette.textPrimary)
                Spacer()
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.top, 18)
            .padding(.bottom, 12)
            .background {
                StacklumeGlassBackdrop(
                    shape: Rectangle(),
                    tint: palette.accent,
                    tintOpacity: 0.025
                )
            }

            Divider().overlay(palette.border.opacity(0.4))

            content().stacklumeDefaultFont(factor: textScale)

            Divider().overlay(palette.border.opacity(0.4))

            HStack(spacing: DesignSystem.Spacing.sm) {
                Spacer()
                if let cancelTitle {
                    Button(cancelTitle, action: onCancel)
                        .stacklumeButton(prominent: false)
                        .stacklumeDefaultFont(factor: textScale)
                        .controlSize(.large)
                        .keyboardShortcut(.cancelAction)
                }
                Button(confirmTitle, action: onConfirm)
                    .stacklumeButton()
                    .stacklumeDefaultFont(factor: textScale)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.vertical, 14)
            .background {
                StacklumeGlassBackdrop(
                    shape: Rectangle(),
                    tint: palette.accent,
                    tintOpacity: 0.025
                )
            }
        }
        .background(WindowBackground())
    }
}
