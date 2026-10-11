import SwiftUI
import StacklumeDesignSystem

/// Tarjeta premium para una categoría/proyecto/etiqueta: icono sobre su color,
/// nombre y subtítulo.
struct TaxonomyCard: View {
    let icon: String
    let colorHex: String
    let name: String
    let subtitle: String

    @Environment(\.themePalette) private var palette
    private var color: Color { Color(hex: colorHex) }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color.gradient)
                .frame(width: 44, height: 44)
                .overlay(Image(systemName: icon).scaledFont(19, weight: .semibold, scalesWithText: false).foregroundStyle(.white))
                .shadow(color: color.opacity(0.35), radius: 5, y: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).stacklumeFont(.body.weight(.semibold)).foregroundStyle(palette.textPrimary).stacklumeLineLimit(1)
                Text(subtitle).stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(DesignSystem.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
            .strokeBorder(color.opacity(0.22), lineWidth: 1))
    }
}
