import AppKit
import SwiftUI
import CoreText
import StacklumeDesignSystem

enum SidebarSectionID: Hashable { case library, explore, projects }
enum SidebarGroupID: Hashable { case collections, tags, filters, saved, tools }
enum SidebarIndexAction: Hashable { case collections, tags }
enum SidebarNodeID: Hashable {
    case destination(NavTarget)
    case section(SidebarSectionID)
    case group(SidebarGroupID)
    case action(SidebarIndexAction)
}

enum SidebarAction: Hashable {
    case allCollections, allTags, createCategory, createProject
    case collectionSort(String), tagSort(String)
    case editCategory(UUID), subcategory(UUID), openCategory(UUID), copyCategory(UUID)
    case exportJSON(UUID), exportHTML(UUID), enrichCategory(UUID), deleteCategory(UUID)
    case editTag(UUID), deleteTag(UUID), editProject(UUID), deleteProject(UUID), deleteSearch(UUID)
    case beginRename(UUID), updateRename(UUID, String), finishRename(UUID, String), cancelRename
}

struct SidebarMenuEntry: Hashable {
    var title: String
    var symbol: String? = nil
    var action: SidebarAction? = nil
    var enabled = true
    var checked = false
    var children: [SidebarMenuEntry] = []
    var separator = false
    static var divider: Self { Self(title: "", separator: true) }
}

struct SidebarAccessory: Hashable {
    var title: String
    var symbol: String
    var action: SidebarAction? = nil
    var menu: [SidebarMenuEntry] = []
}

enum SidebarRowKind: Hashable { case ordinary, assistant, header, group, index }
enum SidebarCounterStyle: Hashable { case body, caption, caption2 }

struct SidebarDescriptor: Hashable {
    var id: SidebarNodeID
    var title: String
    var kind: SidebarRowKind = .ordinary
    var target: NavTarget? = nil
    var children: [SidebarNodeID] = []
    var symbol: String? = nil
    var iconColor: Color? = nil
    var imageData: Data? = nil
    var counter: String? = nil
    var counterValue: Int? = nil
    var counterUnit: String = "enlaces"
    var counterStyle: SidebarCounterStyle = .body
    var status: String? = nil
    var busy = false
    var truncatesTitle = false
    var menu: [SidebarMenuEntry] = []
    var accessories: [SidebarAccessory] = []
    var dragUUID: UUID? = nil
    var action: SidebarAction? = nil
    var editingUUID: UUID? = nil
    var editingText: String? = nil
    var accessibilityHint: String? = nil

    var accessibilityValue: String {
        if let status { return busy ? status : "\(status). LOCAL" }
        if let counterValue { return "\(counterValue) \(counterValue == 1 ? (counterUnit == "colecciones" ? "colección" : String(counterUnit.dropLast())) : counterUnit)" }
        return ""
    }
}

struct SidebarBookmarkValue: Hashable {
    var category: UUID?
    var tags: Set<UUID>
    var favorite: Bool
    var inbox: Bool
    var done: Bool
}

struct SidebarSnapshot {
    var roots: [SidebarNodeID]
    var nodes: [SidebarNodeID: SidebarDescriptor]
    var parents: [SidebarNodeID: SidebarNodeID]
    var depths: [SidebarNodeID: Int]
    var expandedGroups: Set<SidebarGroupID>
    var categoryParents: [UUID: UUID]
    var categoryIDs: Set<UUID>
    var tagParents: [UUID: UUID]
    var tagIDs: Set<UUID>
    var bookmarks: [UUID: SidebarBookmarkValue]
    var projectLinks: [UUID: Set<UUID>]

    func sameStructure(as other: Self) -> Bool {
        roots == other.roots && nodes.count == other.nodes.count && nodes.allSatisfy {
            other.nodes[$0.key]?.children == $0.value.children
        }
    }

    func ancestors(of id: SidebarNodeID) -> [SidebarNodeID] {
        var visited: Set<SidebarNodeID> = [id]
        var result: [SidebarNodeID] = []
        var current = id
        while let parent = parents[current], visited.insert(parent).inserted {
            result.append(parent); current = parent
        }
        return result.reversed()
    }

    func categoryWouldCycle(source: UUID, target: UUID) -> Bool {
        var current: UUID? = target
        var visited: Set<UUID> = []
        while let id = current {
            if id == source { return true }
            guard visited.insert(id).inserted else { return true }
            current = categoryParents[id]
        }
        return false
    }

    func tagWouldCycle(source: UUID, targetParent: UUID?) -> Bool {
        var current = targetParent
        var visited: Set<UUID> = []
        while let id = current {
            if id == source { return true }
            guard visited.insert(id).inserted else { return true }
            current = tagParents[id]
        }
        return false
    }
}

enum SidebarDropPosition: Hashable { case on, before, after }
struct SidebarDrop: Hashable { var target: SidebarNodeID; var position: SidebarDropPosition }

enum SidebarFontRole: Hashable { case title, index, assistant, status, badge, header, captionCounter, groupCounter, bodyCounter, accessory }

@MainActor struct SidebarNativeTypography {
    let fonts: [SidebarFontRole: NSFont]
    let factor: Double
    let signatures: [SidebarFontRole: String]
    init(context: Font.Context, factor: Double = 1) {
        self.factor = StacklumeTextScale.normalizedFactor(factor)
        let bases: [SidebarFontRole: Font] = [
            .title: .body, .index: .callout, .assistant: .callout.weight(.semibold), .status: .caption2,
            .badge: .caption2.weight(.bold), .header: .caption.weight(.semibold),
            .captionCounter: .caption.monospacedDigit(), .groupCounter: .caption2.monospacedDigit(),
            .bodyCounter: .body.monospacedDigit(), .accessory: .system(size: 12, weight: .semibold)
        ]
        fonts = bases.mapValues { base in
            let font = StacklumeFontScaling.font(base, factor: factor)!
            return font.resolve(in: context).ctFont as NSFont
        }
        signatures = fonts.mapValues { font in
            let attributes = font.fontDescriptor.fontAttributes
            let ordered = attributes.keys.sorted { $0.rawValue < $1.rawValue }
                .map { "\($0.rawValue)=\(String(describing: attributes[$0]!))" }.joined(separator: "|")
            return "\(font.fontName)|\(font.pointSize)|\(ordered)"
        }
    }
    subscript(_ role: SidebarFontRole) -> NSFont { fonts[role]! }
}

struct SidebarMetricKey: Hashable {
    var title: String
    var kind: SidebarRowKind
    var status: String?
    var counter: String?
    var counterStyle: SidebarCounterStyle
    var busy: Bool
    var truncate: Bool
    var accessoryCount: Int
    var hasIcon: Bool
    var width: CGFloat
    var depth: Int
    var scale: CGFloat
    var fonts: [SidebarFontRole: String]
    var factor: Double
    @MainActor init(_ row: SidebarDescriptor, width: CGFloat, depth: Int, backingScale: CGFloat, fonts: SidebarNativeTypography) {
        title = row.title; kind = row.kind; status = row.status; counter = row.counter
        counterStyle = row.counterStyle; busy = row.busy; truncate = row.truncatesTitle
        accessoryCount = row.accessories.count; hasIcon = row.symbol != nil || row.imageData != nil
        self.width = width; self.depth = depth; scale = backingScale
        self.fonts = fonts.signatures; factor = fonts.factor
    }
}

@MainActor struct SidebarAttributedText {
    let string: NSAttributedString
    let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine]
    let size: NSSize
    init(_ text: String, font: NSFont, color: NSColor, width: CGFloat, singleLine: Bool = false, wrapping: NSLineBreakMode = .byWordWrapping) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = singleLine ? .byTruncatingTail : wrapping
        string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        let limit = singleLine ? ceil(font.ascender - font.descender + font.leading) : CGFloat.greatestFiniteMagnitude
        size = string.boundingRect(with: NSSize(width: max(1, width), height: limit), options: options).size
    }
    private init(string: NSAttributedString, size: NSSize) { self.string = string; self.size = size }
    func recolored(_ color: NSColor) -> Self {
        let copy = NSMutableAttributedString(attributedString: string)
        copy.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: copy.length))
        return Self(string: copy, size: size)
    }
    func draw(in rect: NSRect) { string.draw(with: rect, options: options) }
}

@MainActor struct SidebarSelectionPaint {
    let background: NSColor
    let badgeBackground: NSColor
    init(palette: ThemePalette) {
        var resolved: NSColor = .clear
        var badge: NSColor = .clear
        let appearance = NSAppearance(named: palette.colorScheme == .dark ? .darkAqua : .aqua)
            ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            resolved = Self.blend(NSColor(palette.accent), over: NSColor(palette.surface), alpha: 0.18)
            badge = Self.blend(NSColor(palette.accent), over: resolved, alpha: 0.12)
        }
        background = resolved; badgeBackground = badge
    }
    // El resultado opaco fija la composición sRGB que se pinta y se usa para el contraste.
    static func blend(_ tint: NSColor, over base: NSColor, alpha: CGFloat) -> NSColor {
        let tint = tint.usingColorSpace(.sRGB) ?? tint
        let base = base.usingColorSpace(.sRGB) ?? base
        return NSColor(srgbRed: tint.redComponent * alpha + base.redComponent * (1 - alpha),
                       green: tint.greenComponent * alpha + base.greenComponent * (1 - alpha),
                       blue: tint.blueComponent * alpha + base.blueComponent * (1 - alpha), alpha: 1)
    }
    func foreground(_ preferred: Color, palette: ThemePalette, badge: Bool = false) -> NSColor {
        NSColor(palette.readableForeground(preferred, on: Color(nsColor: badge ? badgeBackground : background)))
    }
}

@MainActor struct SidebarRowLayout {
    var height: CGFloat
    var minimumColumnWidth: CGFloat
    var indentation: CGFloat
    var title: SidebarAttributedText
    var titleRect: NSRect
    var status: SidebarAttributedText?
    var statusRect: NSRect = .zero
    var counter: SidebarAttributedText?
    var counterRect: NSRect = .zero
    var badge: SidebarAttributedText?
    var badgeRect: NSRect = .zero
    var iconRect: NSRect = .zero
    var accessoryRects: [NSRect]

    func applyingSelection(_ paint: SidebarSelectionPaint, palette: ThemePalette) -> Self {
        var result = self
        func recolor(_ text: SidebarAttributedText, badge: Bool = false) -> SidebarAttributedText {
            guard text.string.length > 0 else { return text }
            let preferred = text.string.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                ?? NSColor(palette.textPrimary)
            return text.recolored(paint.foreground(Color(nsColor: preferred), palette: palette, badge: badge))
        }
        result.title = recolor(title)
        result.status = status.map { recolor($0) }
        result.counter = counter.map { recolor($0) }
        result.badge = badge.map { recolor($0, badge: true) }
        return result
    }

    static func make(_ row: SidebarDescriptor, width: CGFloat, depth: Int, backingScale: CGFloat,
                     fonts: SidebarNativeTypography, palette: ThemePalette) -> Self {
        let pixel = max(1, backingScale)
        func round(_ value: CGFloat) -> CGFloat { ceil(value * pixel) / pixel }
        let inset = DesignSystem.Spacing.xs
        let gap = DesignSystem.Spacing.xs
        let header = row.kind == .header
        let isSmallTitle = header || row.kind == .group
        let titleFont = fonts[row.kind == .assistant ? .assistant : (row.kind == .index ? .index : (isSmallTitle ? .header : .title))]
        let primary = NSColor(palette.textPrimary)
        let secondary = NSColor(palette.textSecondary)
        let accessoryWidth = max(18, fonts[.accessory].pointSize + 6)
        let accessorySpan = CGFloat(row.accessories.count) * (accessoryWidth + gap)
        let iconWidth: CGFloat = row.symbol != nil || row.imageData != nil ? 18 : 0
        let counterRole: SidebarFontRole = row.counterStyle == .body ? .bodyCounter : (row.counterStyle == .caption ? .captionCounter : .groupCounter)
        let counter = row.counter.map { SidebarAttributedText($0, font: fonts[counterRole], color: secondary, width: .greatestFiniteMagnitude, singleLine: true) }
        let badge = row.kind == .assistant && !row.busy
            ? SidebarAttributedText("LOCAL", font: fonts[.badge], color: primary, width: .greatestFiniteMagnitude, singleLine: true) : nil
        let tailWidth: CGFloat = row.busy && row.kind == .assistant ? 16 : (badge.map { round($0.size.width) + 12 } ?? 0)
        let countWidth = counter.map { round($0.size.width) + gap } ?? 0
        let glyph = SidebarAttributedText("M", font: titleFont, color: primary, width: .greatestFiniteMagnitude, singleLine: true).size.width
        let minimumColumnWidth = CGFloat(depth + 1) * DesignSystem.Spacing.md + 2 * inset + iconWidth + (iconWidth > 0 ? gap : 0) + tailWidth + (tailWidth > 0 ? gap : 0) + countWidth + accessorySpan + round(glyph)
        let requiredLocalWidth = 2 * inset + max(iconWidth + (iconWidth > 0 ? gap : 0) + round(glyph), accessoryWidth, tailWidth)
        let indentation = min(CGFloat(depth + 1) * DesignSystem.Spacing.md, max(0, width - requiredLocalWidth))
        let localWidth = max(1, width - indentation)
        if minimumColumnWidth > width {
            return reflow(row, localWidth: localWidth, indentation: indentation,
                          minimumColumnWidth: minimumColumnWidth, backingScale: pixel, fonts: fonts, palette: palette)
        }
        let leading = inset + (iconWidth > 0 ? iconWidth + gap : 0)
        let trailing = localWidth - inset - accessorySpan
        let textWidth = max(round(glyph), trailing - leading - countWidth - tailWidth - (tailWidth > 0 ? gap : 0))
        let title = SidebarAttributedText(row.title, font: titleFont, color: row.kind == .index ? NSColor(palette.accent) : (isSmallTitle ? secondary : primary),
                                         width: textWidth, singleLine: row.truncatesTitle && fonts.factor == 1)
        let status = row.status.map { SidebarAttributedText($0, font: fonts[.status], color: secondary, width: textWidth, singleLine: fonts.factor == 1) }
        let textHeight = round(title.size.height) + (status.map { 1 + round($0.size.height) } ?? 0)
        let badgeHeight = badge.map { round($0.size.height) + 4 } ?? (row.busy ? 16 : 0)
        let top = header ? DesignSystem.Spacing.sm : inset + (row.kind == .assistant ? 3 : 0)
        let bottom = inset + (row.kind == .assistant ? 3 : 0)
        let contentHeight = max(textHeight, iconWidth, badgeHeight, accessoryWidth * (row.accessories.isEmpty ? 0 : 1), counter.map { round($0.size.height) } ?? 0)
        let height = round(top + contentHeight + bottom)
        let titleY = top + (contentHeight - textHeight) / 2
        let titleRect = NSRect(x: leading, y: titleY, width: textWidth, height: round(title.size.height))
        let accessoryRects = row.accessories.indices.map { index in
            NSRect(x: localWidth - inset - CGFloat(row.accessories.count - index) * (accessoryWidth + gap) + gap,
                   y: top + (contentHeight - accessoryWidth) / 2, width: accessoryWidth, height: accessoryWidth)
        }
        var result = Self(height: height, minimumColumnWidth: minimumColumnWidth, indentation: indentation, title: title, titleRect: titleRect,
                          status: status, counter: counter, badge: badge, accessoryRects: accessoryRects)
        if let status { result.statusRect = NSRect(x: leading, y: titleRect.maxY + 1, width: textWidth, height: round(status.size.height)) }
        if let counter { result.counterRect = NSRect(x: trailing - countWidth + gap, y: top + (contentHeight - round(counter.size.height)) / 2, width: countWidth - gap, height: round(counter.size.height)) }
        if tailWidth > 0 { result.badgeRect = NSRect(x: trailing - tailWidth, y: top + (contentHeight - badgeHeight) / 2, width: tailWidth, height: badgeHeight) }
        if iconWidth > 0 { result.iconRect = NSRect(x: inset, y: top + (contentHeight - iconWidth) / 2, width: iconWidth, height: iconWidth) }
        return result
    }

    // Solo el desbordamiento medido lleva metadatos y acciones a líneas adicionales.
    private static func reflow(_ row: SidebarDescriptor, localWidth: CGFloat, indentation: CGFloat,
                               minimumColumnWidth: CGFloat, backingScale: CGFloat,
                               fonts: SidebarNativeTypography, palette: ThemePalette) -> Self {
        func round(_ value: CGFloat) -> CGFloat { ceil(value * backingScale) / backingScale }
        let inset = DesignSystem.Spacing.xs, gap = DesignSystem.Spacing.xs
        let primary = NSColor(palette.textPrimary), secondary = NSColor(palette.textSecondary)
        let small = row.kind == .header || row.kind == .group
        let titleFont = fonts[row.kind == .assistant ? .assistant : (row.kind == .index ? .index : (small ? .header : .title))]
        let icon: CGFloat = row.symbol != nil || row.imageData != nil ? 18 : 0
        let leading = inset + (icon > 0 ? icon + gap : 0)
        let innerWidth = max(1, localWidth - 2 * inset)
        let textWidth = max(1, localWidth - inset - leading)
        let title = SidebarAttributedText(row.title, font: titleFont,
            color: row.kind == .index ? NSColor(palette.accent) : (small ? secondary : primary), width: textWidth)
        let status = row.status.map { SidebarAttributedText($0, font: fonts[.status], color: secondary, width: textWidth) }
        let top = row.kind == .header ? DesignSystem.Spacing.sm : inset + (row.kind == .assistant ? 3 : 0)
        let bottom = inset + (row.kind == .assistant ? 3 : 0)
        let titleHeight = round(title.size.height)
        let textHeight = titleHeight + (status.map { 1 + round($0.size.height) } ?? 0)
        var result = Self(height: 0, minimumColumnWidth: minimumColumnWidth, indentation: indentation,
                          title: title, titleRect: NSRect(x: leading, y: top, width: textWidth, height: titleHeight),
                          status: status, accessoryRects: [])
        if let status { result.statusRect = NSRect(x: leading, y: top + titleHeight + 1, width: textWidth, height: round(status.size.height)) }
        if icon > 0 { result.iconRect = NSRect(x: inset, y: top, width: icon, height: icon) }
        var x = inset, y = top + max(textHeight, icon) + gap, lineHeight: CGFloat = 0
        func place(_ size: NSSize) -> NSRect {
            if x > inset && x + size.width > localWidth - inset {
                x = inset; y += lineHeight + gap; lineHeight = 0
            }
            let rect = NSRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width + gap; lineHeight = max(lineHeight, size.height)
            return rect
        }
        if let text = row.counter {
            let role: SidebarFontRole = row.counterStyle == .body ? .bodyCounter : (row.counterStyle == .caption ? .captionCounter : .groupCounter)
            let counter = SidebarAttributedText(text, font: fonts[role], color: secondary, width: innerWidth, wrapping: .byCharWrapping)
            result.counter = counter
            result.counterRect = place(NSSize(width: min(innerWidth, round(counter.size.width)), height: round(counter.size.height)))
        }
        if row.kind == .assistant {
            if row.busy { result.badgeRect = place(NSSize(width: 16, height: 16)) }
            else {
                let badge = SidebarAttributedText("LOCAL", font: fonts[.badge], color: primary, width: max(1, innerWidth - 12), wrapping: .byCharWrapping)
                result.badge = badge
                result.badgeRect = place(NSSize(width: min(innerWidth, round(badge.size.width) + 12), height: round(badge.size.height) + 4))
            }
        }
        let accessoryWidth = max(18, fonts[.accessory].pointSize + 6)
        result.accessoryRects = row.accessories.map { _ in place(NSSize(width: accessoryWidth, height: accessoryWidth)) }
        result.height = round(y + lineHeight + bottom)
        return result
    }
}
