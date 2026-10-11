import SwiftUI
import StacklumeCore
import StacklumeDesignSystem

/// Chip de etiqueta: punto del color de la etiqueta + nombre, sobre una cápsula
/// translúcida del propio color.
struct TagChip: View {
    @Environment(\.themePalette) private var palette
    /// Nombre y color como VALORES (no el `@Model Tag`): así la fila de la lista puede pintar
    /// el chip desde un snapshot capturado una vez, sin faultear `Tag` ni disparar el
    /// seguimiento de Observation en CADA fotograma del scroll. El init `tag:` extrae los valores.
    let name: String
    let colorHex: String

    init(name: String, colorHex: String) {
        self.name = name
        self.colorHex = colorHex
    }
    init(tag: Tag) {
        self.name = tag.name
        self.colorHex = tag.colorHex
    }

    private var color: Color { Color(hex: colorHex) }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(name)
                .stacklumeFont(.caption2.weight(.medium))
                .stacklumeLineLimit(1)
                .readableTint(color, palette: palette, on: [palette.background, palette.surface, palette.popover],
                              overlay: color.opacity(0.14))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.25), lineWidth: 0.5))
    }
}
