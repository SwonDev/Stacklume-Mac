import SwiftUI

/// Mantiene los puntos originales al 100 % y aplica la escala explícita del Mac al texto.
/// @ScaledMetric conserva su métrica relativa; los glifos fijos pueden excluir la escala de texto.
extension View {
    func scaledFont(_ size: CGFloat,
                    weight: Font.Weight = .regular,
                    design: Font.Design = .default,
                    relativeTo style: Font.TextStyle = .body,
                    scalesWithText: Bool = true, file: StaticString = #fileID, line: Int = #line) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, design: design, style: style, scalesWithText: scalesWithText, file: file, line: line))
    }
}

private struct ScaledSystemFont: ViewModifier {
    @Environment(\.stacklumeTextScale) private var textScale
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design
    private let scalesWithText: Bool
    private let file: StaticString
    private let line: Int

    init(size: CGFloat, weight: Font.Weight, design: Font.Design, style: Font.TextStyle, scalesWithText: Bool, file: StaticString, line: Int) {
        // `@ScaledMetric(wrappedValue:relativeTo:)`: en el ajuste por defecto devuelve el valor
        // tal cual; con texto más grande/pequeño lo escala proporcionalmente al estilo dado.
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.design = design
        self.scalesWithText = scalesWithText
        self.file = file
        self.line = line
    }

    func body(content: Content) -> some View {
        content.stacklumeFont(.system(size: size, weight: weight, design: design), file: file, line: line)
            .environment(\.stacklumeTextScale, scalesWithText ? textScale : 1)
    }
}
