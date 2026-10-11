import AppKit
import SwiftUI
import Foundation

/// La misma representación segura sirve a TextKit de medición y a las celdas seleccionables.
@MainActor
struct AIChatNativeFonts {
    let body: NSFont
    let callout: NSFont
    let lead: NSFont
    let heading: NSFont
    let quote: NSFont
    let caption: NSFont
    let captionMedium: NSFont
    let captionStrong: NSFont
    let chip: NSFont

    static func resolve(context: Font.Context, factor: Double,
                        measurement: StacklumeFontMeasurement?) -> Self {
        func font(_ base: Font, line: Int = #line) -> NSFont {
            let normalized = StacklumeTextScale.normalizedFactor(factor)
            let actual = (normalized == 1 ? base : base.scaled(by: normalized)).resolve(in: context)
            if let measurement {
                let original = base.resolve(in: context)
                measurement.record(#fileID, line, normalized, original.pointSize, actual.pointSize, actual.isBold)
            }
            return actual.ctFont as NSFont
        }
        return .init(body: font(.body), callout: font(.callout), lead: font(.callout.weight(.medium)),
                     heading: font(.callout.weight(.semibold)), quote: font(.body.italic()),
                     caption: font(.caption), captionMedium: font(.caption.weight(.medium)), captionStrong: font(.caption.weight(.semibold)),
                     chip: font(.caption2.weight(.medium)))
    }
}

@MainActor
struct AIChatNativeText {
    static func plain(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    static func structured(_ text: String, fonts: AIChatNativeFonts,
                           primary: NSColor, secondary: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for block in AssistantResponsePresentation.blocks(from: text) {
            if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
            let content: String
            switch block.kind {
            case .bullets: content = block.items.map { "• \($0)" }.joined(separator: "\n")
            case .numbered: content = block.items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            default: content = block.text
            }
            let font: NSFont
            switch block.kind {
            case .lead: font = fonts.lead
            case .heading: font = fonts.heading
            case .quote: font = fonts.quote
            default: font = fonts.body
            }
            result.append(plain(content, font: font, color: block.kind == .quote ? secondary : primary))
        }
        return result
    }
}

/// Solo un text system de medición; los resultados publicados no retienen storage ni glyphs.
@MainActor
final class AIChatTextKitMeasurer {
    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private let container = NSTextContainer()
    private(set) var measurements = 0
    private(set) var maximumUTF16 = 0

    init() {
        manager.allowsNonContiguousLayout = false
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
    }

    func height(of text: NSAttributedString, width: CGFloat, maximumLines: Int = 0) -> CGFloat {
        install(text, width: width, maximumLines: maximumLines)
        defer { releaseText() }
        return ceil(max(manager.usedRect(for: container).maxY, manager.extraLineFragmentUsedRect.maxY))
    }

    func character(at point: CGPoint, in text: NSAttributedString, width: CGFloat) -> (index: Int, lineOffset: CGFloat) {
        install(text, width: width)
        defer { releaseText() }
        guard text.length > 0 else { return (0, 0) }
        let index = min(text.length - 1, manager.characterIndex(for: point, in: container,
                                                             fractionOfDistanceBetweenInsertionPoints: nil))
        let glyph = manager.glyphIndexForCharacter(at: index)
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return (index, max(0, point.y - line.minY))
    }

    func verticalPosition(of character: Int, lineOffset: CGFloat, in text: NSAttributedString, width: CGFloat) -> CGFloat {
        install(text, width: width)
        defer { releaseText() }
        guard text.length > 0 else { return 0 }
        let index = max(0, min(character, text.length - 1))
        let glyph = manager.glyphIndexForCharacter(at: index)
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return line.minY + min(max(0, lineOffset), max(0, line.height - 1))
    }

    func line(for character: Int, in text: NSAttributedString, width: CGFloat) -> Int {
        install(text, width: width); defer { releaseText() }
        var ordinal = 0, result = 0
        let target = min(max(0, character), max(0, text.length - 1))
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, _, _, glyphs, stop in
            let range = self.manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            if NSLocationInRange(target, range) { result = ordinal; stop.pointee = true }
            ordinal += 1
        }
        return result
    }
    func range(forLine line: Int, in text: NSAttributedString, width: CGFloat) -> NSRange {
        install(text, width: width); defer { releaseText() }
        var ordinal = 0, result = NSRange(location: NSNotFound, length: 0)
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, _, _, glyphs, stop in
            if ordinal == line { result = self.manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil); stop.pointee = true }
            ordinal += 1
        }
        return result
    }
    func frame(for range: NSRange, in text: NSAttributedString, width: CGFloat) -> CGRect {
        install(text, width: width); defer { releaseText() }
        guard range.location != NSNotFound, range.location >= 0, NSMaxRange(range) <= text.length else { return .zero }
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return manager.boundingRect(forGlyphRange: glyphs, in: container)
    }

    var retainedUTF16: Int { storage.length }

    private func install(_ text: NSAttributedString, width: CGFloat, maximumLines: Int = 0) {
        measurements += 1
        maximumUTF16 = max(maximumUTF16, text.length)
        container.containerSize = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        container.maximumNumberOfLines = maximumLines
        container.lineBreakMode = maximumLines > 0 ? .byTruncatingTail : .byWordWrapping
        storage.setAttributedString(text)
        manager.ensureLayout(for: container)
    }

    private func releaseText() { storage.setAttributedString(NSAttributedString(string: "")) }
}
