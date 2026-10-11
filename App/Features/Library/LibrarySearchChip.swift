import SwiftUI
import StacklumeDesignSystem

/// Chip de búsqueda guardada para la cabecera de la Biblioteca: cápsula translúcida
/// discreta con icono dorado + nombre. Clic = aplicar la búsqueda; el menú contextual
/// (eliminar) lo añade el llamador. Pensado para macOS: hover sutil, sin hápticos.
///
/// Sigue DESIGN.md: chips sutiles, el dorado (`palette.accent`) reservado al icono
/// como acento; el cuerpo es una cápsula del propio acento con muy poca opacidad para
/// no competir con el contenido. No usa cristal (la fila de chips no es capa funcional).
struct LibrarySearchChip: View {
    @Environment(\.themePalette) private var palette
    @State private var isHovering = false

    let label: String
    var systemImage: String = "bookmark.fill"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.accent)
                Text(label)
                    .stacklumeFont(.caption.weight(.medium))
                    .foregroundStyle(palette.textPrimary)
                    .stacklumeLineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(palette.accent.opacity(isHovering ? 0.18 : 0.10), in: Capsule())
            .overlay(Capsule().strokeBorder(palette.accent.opacity(0.25), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .onHover { isHovering = $0 }
        .themedHelp("Aplicar búsqueda: \(label)")
        .accessibilityLabel("Aplicar búsqueda guardada \(label)")
    }
}
