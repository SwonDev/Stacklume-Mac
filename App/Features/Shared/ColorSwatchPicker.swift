import SwiftUI
import AppKit
import StacklumeDesignSystem

/// Colores predefinidos y rueda nativa visible; ambos conservan el mismo binding de color.
struct ColorSwatchPicker: View {
    @Binding var selection: String
    @Environment(\.themePalette) private var palette

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 8)

    /// ¿El color elegido NO está entre los predefinidos? → es personalizado.
    private var isCustom: Bool {
        !ColorPresets.all.contains { $0.caseInsensitiveCompare(selection) == .orderedSame }
    }

    /// Puente Color↔hex para la rueda nativa.
    private var customColor: Binding<Color> {
        Binding(get: { Color(hex: selection) },
                set: { selection = $0.hexString })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(ColorPresets.all, id: \.self) { hex in
                    swatch(hex)
                }
            }
            customSwatch
        }
        .padding(.vertical, 4)
    }

    private func swatch(_ hex: String) -> some View {
        let color = Color(hex: hex)
        let selected = hex.caseInsensitiveCompare(selection) == .orderedSame
        return Button { selection = hex } label: {
            Circle()
                .fill(color)
                .frame(width: 26, height: 26)
                .overlay {
                    if selected {
                        Circle().strokeBorder(palette.foreground(on: color), lineWidth: 2)
                    }
                }
                .padding(3)
                .background(Circle().fill(palette.surface))
                .overlay {
                    if selected {
                        Circle().strokeBorder(palette.foreground(on: palette.surface), lineWidth: 2)
                    }
                }
                .padding(2)
                .background(Circle().fill(palette.surface))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Color \(hex)")
        .accessibilityValue(selected ? "Seleccionado" : "Sin seleccionar")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var customSwatch: some View {
        ColorPicker("Color personalizado", selection: customColor, supportsOpacity: false)
            .accessibilityValue(selection + (isCustom ? ", personalizado seleccionado" : ", color predefinido"))
            .accessibilityAddTraits(isCustom ? .isSelected : [])
            .themedHelp("Color personalizado")
    }
}

extension Color {
    /// Representación hex «#RRGGBB» en sRGB (para guardar el color elegido en la rueda).
    var hexString: String {
        let ns = (NSColor(self).usingColorSpace(.sRGB)) ?? NSColor(self)
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
