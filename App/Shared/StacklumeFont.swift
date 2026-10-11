import SwiftUI

extension EnvironmentValues {
    @Entry var stacklumeTextScale: Double = 1
    @Entry var stacklumeFontMeasurement: StacklumeFontMeasurement?
}

/// Solo QA instala esta captura; no incluye contenido del usuario ni identificadores persistentes.
@MainActor struct StacklumeFontMeasurement {
    var record: (String, Int, Double, Double, Double, Bool) -> Void
}

enum StacklumeFontScaling {
    static func font(_ base: Font?, factor: Double) -> Font? {
        let scale = StacklumeTextScale.normalizedFactor(factor)
        return base.map { scale == 1 ? $0 : $0.scaled(by: scale) }
    }
}

extension View {
    func stacklumeFont(_ font: Font?, file: StaticString = #fileID, line: Int = #line) -> some View {
        modifier(StacklumeFontModifier(base: font, file: file, line: line))
    }
}

private struct StacklumeFontModifier: ViewModifier {
    let base: Font?
    let file: StaticString
    let line: Int
    @Environment(\.stacklumeTextScale) private var textScale
    @Environment(\.stacklumeFontMeasurement) private var measurement
    @Environment(\.fontResolutionContext) private var fontContext

    func body(content: Content) -> some View {
        let factor = StacklumeTextScale.normalizedFactor(textScale)
        let font = StacklumeFontScaling.font(base, factor: factor)
        if let measurement, let base, let font {
            let original = base.resolve(in: fontContext)
            let actual = font.resolve(in: fontContext)
            let _ = measurement.record(String(describing: file), line, factor, original.pointSize, actual.pointSize, actual.isBold)
        }
        return content.font(font)
    }
}

/// Se instancia exclusivamente en escenas normales; QA inyecta stacklumeTextScale desde State.
private struct StacklumeTextScalePreference: ViewModifier {
    @AppStorage(StacklumeTextScale.storageKey) private var percent = 100
    func body(content: Content) -> some View {
        content.environment(\.stacklumeTextScale, StacklumeTextScale(storedPercent: percent).factor)
            .modifier(StacklumeDefaultFontModifier(factor: StacklumeTextScale(storedPercent: percent).factor))
    }
}

extension View {
    func stacklumeTextScalePreference() -> some View { modifier(StacklumeTextScalePreference()) }
}

/// Solo cubre tipografía heredada; las fuentes declaradas en descendientes usan stacklumeFont.
private struct StacklumeDefaultFontModifier: ViewModifier {
    let factor: Double
    @Environment(\.font) private var inheritedFont
    func body(content: Content) -> some View {
        content.stacklumeFont(factor == 1 ? inheritedFont : .body)
            .environment(\.stacklumeTextScale, factor)
    }
}

extension View {
    func stacklumeDefaultFont(factor: Double) -> some View {
        modifier(StacklumeDefaultFontModifier(factor: StacklumeTextScale.normalizedFactor(factor)))
    }
}

private struct StacklumeLineLimitModifier: ViewModifier {
    let limit: Int?
    @Environment(\.stacklumeTextScale) private var scale
    func body(content: Content) -> some View {
        content.lineLimit(StacklumeTextScale.normalizedFactor(scale) == 1 ? limit : nil)
    }
}

private struct StacklumeMinimumScaleModifier: ViewModifier {
    let minimum: CGFloat
    @Environment(\.stacklumeTextScale) private var scale
    func body(content: Content) -> some View { content.minimumScaleFactor(StacklumeTextScale.normalizedFactor(scale) == 1 ? minimum : 1) }
}

extension View {
    func stacklumeLineLimit(_ limit: Int?) -> some View {
        modifier(StacklumeLineLimitModifier(limit: limit))
    }
    func stacklumeMinimumScaleFactor(_ minimum: CGFloat) -> some View {
        modifier(StacklumeMinimumScaleModifier(minimum: minimum))
    }
}
