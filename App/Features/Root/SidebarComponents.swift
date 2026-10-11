import SwiftUI
import StacklumeCore
import StacklumeDesignSystem

// Componentes auxiliares del sidebar, extraídos de `SidebarView` para acotar su tamaño.
// Tipos independientes (sin estado propio entrelazado): movimiento puro, comportamiento
// idéntico. Antes eran `private` dentro de SidebarView; ahora internos al módulo.

/// HUD no intrusivo que aparece en la parte inferior del sidebar mientras se enriquece
/// una colección con IA. Muestra el nombre de la colección, progreso y «Detener».
struct CollectionEnrichHUD: View {
    let collectionName: String
    let done: Int
    let total: Int
    let palette: ThemePalette
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            ProgressView()
                .scaleEffect(0.8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mejorando «\(collectionName)»…")
                    .stacklumeFont(.caption.weight(.medium))
                    .foregroundStyle(palette.textPrimary)
                    .stacklumeLineLimit(1)
                if total > 0 {
                    Text("\(done) / \(total)")
                        .stacklumeFont(.caption2)
                        .foregroundStyle(palette.textSecondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
            Button("Detener") { onStop() }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(palette.accent)
                .accessibilityLabel("Detener mejora de «\(collectionName)»")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(total > 0
            ? "Mejorando «\(collectionName)», \(done) de \(total)"
            : "Mejorando «\(collectionName)»")
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }
}

/// Fila genérica de un destino fijo del sidebar (sin contador). El resaltado de
/// selección lo gestiona la `List` nativa; aquí solo etiqueta + icono + `.tag`.
struct NavTargetRow: View {
    let target: NavTarget
    let title: String
    let icon: String
    let palette: ThemePalette
    /// Recuento opcional a la derecha (facetas de los filtros inteligentes). Solo se muestra
    /// si es mayor que 0, para no llenar de ceros (p. ej. «Enlaces rotos» suele ser 0).
    var count: Int? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Label {
            HStack {
                Text(title)
                if let count, count > 0 {
                    Spacer(minLength: 8)
                    Text(count > 999 ? "999+" : "\(count)")
                        .stacklumeFont(.caption)
                        .monospacedDigit()
                        .foregroundStyle(palette.textSecondary)
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: count)
                        .accessibilityLabel("\(min(count, 999)) \(count == 1 ? "enlace" : "enlaces")")
                }
            }
        } icon: {
            Image(systemName: icon)
        }
        .tag(target)
    }
}

/// Acceso primario al asistente. A diferencia de una fila genérica, explica qué hace
/// y deja claro que el procesamiento permanece en este Mac. Su posición y jerarquía
/// hacen que la IA sea descubrible sin convertirla en un banner promocional.
struct SidebarAssistantRow: View {
    let status: String
    let isBusy: Bool
    let palette: ThemePalette

    var body: some View {
        Label {
            HStack(spacing: DesignSystem.Spacing.xs) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Asistente IA")
                        .stacklumeFont(.callout.weight(.semibold))
                        .foregroundStyle(palette.textPrimary)
                    Text(status)
                        .stacklumeFont(.caption2)
                        .foregroundStyle(palette.textSecondary)
                        .stacklumeLineLimit(1)
                }

                Spacer(minLength: DesignSystem.Spacing.xs)

                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                } else {
                    Text("LOCAL")
                        .stacklumeFont(.caption2.weight(.bold))
                        .foregroundStyle(palette.textPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            palette.accent.opacity(0.12),
                            in: Capsule()
                        )
                        .accessibilityHidden(true)
                }
            }
        } icon: {
            Image(systemName: "sparkles")
                .foregroundStyle(palette.accent)
        }
        .padding(.vertical, 3)
        .tag(NavTarget.ai)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Asistente IA")
        .accessibilityValue(status)
        .accessibilityHint("Abre el chat local con tu biblioteca")
    }
}
