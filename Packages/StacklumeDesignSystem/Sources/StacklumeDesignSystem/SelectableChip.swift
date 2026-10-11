import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Chip seleccionable (toggle) con un punto de color opcional. Usa el acento del
/// tema cuando está seleccionado.
public struct SelectableChip: View {
    @Environment(\.themePalette) private var palette
    private let title: String
    private let isSelected: Bool
    private let colorHex: String?
    private let systemImage: String?
    private let action: () -> Void

    public init(
        _ title: String,
        isSelected: Bool,
        colorHex: String? = nil,
        systemImage: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.isSelected = isSelected
        self.colorHex = colorHex
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let colorHex {
                    Circle().fill(Color(hex: colorHex)).frame(width: 8, height: 8)
                } else if let systemImage {
                    Image(systemName: systemImage).font(.caption2)
                }
                Text(title).font(.caption.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            // Texto con contraste GARANTIZADO sobre el acento (negro o blanco según su
            // luminancia), en vez de `background` que fallaba en temas claros.
            .foregroundStyle(isSelected ? onAccent : palette.textPrimary)
            .background(
                Capsule().fill(isSelected ? palette.accent : palette.surface)
            )
            .overlay(
                Capsule().strokeBorder(isSelected ? .clear : palette.border, lineWidth: 0.5)
            )
            // Área táctil accesible de 44 pt (la cápsula visual queda centrada).
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Negro o blanco según la luminancia del acento, para máximo contraste del texto.
    private var onAccent: Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        UIColor(palette.accent).getRed(&r, green: &g, blue: &b, alpha: &a)
        #elseif canImport(AppKit)
        // NSColor puede estar en un espacio no-RGB; lo convertimos a sRGB antes de
        // leer los componentes, si no `getRed` lanzaría.
        let ns = NSColor(palette.accent).usingColorSpace(.sRGB) ?? NSColor(palette.accent)
        ns.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        func lin(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        return luminance > 0.179 ? .black : .white
    }
}
