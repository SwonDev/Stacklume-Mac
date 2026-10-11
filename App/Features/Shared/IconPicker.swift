import SwiftUI
import StacklumeDesignSystem

/// Selector de SF Symbol en cuadrícula desde `IconCatalog`.
struct IconPicker: View {
    @Binding var selection: String
    var tint: Color
    @Environment(\.themePalette) private var palette

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 8)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(IconCatalog.all, id: \.self) { symbol in
                Button { selection = symbol } label: {
                    Image(systemName: symbol)
                        .scaledFont(16, scalesWithText: false)
                        .frame(width: 32, height: 32)
                        .foregroundStyle(symbol == selection ? tint.contrastingForeground : palette.textSecondary)
                        .background(symbol == selection ? tint : palette.surface,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Icono \(symbol)")
                .accessibilityValue(symbol == selection ? "Seleccionado" : "Sin seleccionar")
                .accessibilityAddTraits(symbol == selection ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}
