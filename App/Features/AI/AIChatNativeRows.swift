import AppKit
import SwiftUI
import StacklumeDesignSystem

/// Proyección efímera de presentación; no persiste ni modifica el DTO de conversación.
struct AIChatNativeMessage: Equatable, Sendable {
    struct Activity: Equatable, Sendable { let title: String; let systemImage: String }
    let id: UUID
    let isUser: Bool
    let text: String
    let actions: [Activity]
    let references: [AssistantLinkReference]
}

/// Identidades de las filas originales. Las referencias no dependen de su índice visible.
enum AIChatNativeRowID: Hashable, Sendable {
    case message(UUID), header(UUID), reference(UUID, String), footer(UUID), actions(UUID), progress, empty
}

@MainActor
enum AIChatNativeRow {
    case message(AIChatNativeMessage, first: Bool)
    case header(UUID, [AssistantLinkReference])
    case reference(UUID, AssistantLinkReference, expanded: Bool, added: Bool)
    case footer(UUID, Int, expanded: Bool)
    case actions(AIChatNativeMessage)
    case progress(String)
    case empty

    var id: AIChatNativeRowID {
        switch self {
        case .message(let m, _): .message(m.id)
        case .header(let id, _): .header(id)
        case .reference(let id, let ref, _, _): .reference(id, ref.id)
        case .footer(let id, _, _): .footer(id)
        case .actions(let m): .actions(m.id)
        case .progress: .progress
        case .empty: .empty
        }
    }
    var topSpacing: CGFloat {
        switch self {
        case .message(_, let first): first ? DesignSystem.Spacing.md : DesignSystem.Spacing.sm
        case .header: 6
        case .reference, .footer: DesignSystem.Spacing.xs
        case .actions: 4
        case .progress: DesignSystem.Spacing.sm
        case .empty: DesignSystem.Spacing.xl
        }
    }
    var diagnosticKind: ScrollDiagnosticRowKind {
        switch self {
        case .message, .empty: .message
        case .header: .header
        case .reference: .reference
        case .footer: .footer
        case .actions: .actions
        case .progress: .progress
        }
    }
    func equivalent(to other: Self) -> Bool {
        switch (self, other) {
        case (.message(let a, let af), .message(let b, let bf)):
            a.id == b.id && af == bf && a.isUser == b.isUser && a.text == b.text && a.actions == b.actions && a.references == b.references
        case (.header(let a, let ar), .header(let b, let br)): a == b && ar == br
        case (.reference(let a, let ar, let ae, let aa), .reference(let b, let br, let be, let ba)):
            a == b && ar == br && ae == be && aa == ba
        case (.footer(let a, let ac, let ae), .footer(let b, let bc, let be)): a == b && ac == bc && ae == be
        case (.actions(let a), .actions(let b)): a.id == b.id && a.text == b.text && a.references == b.references
        case (.progress(let a), .progress(let b)): a == b
        case (.empty, .empty): true
        default: false
        }
    }

    static func make(messages: [AIChatNativeMessage], isResponding: Bool, progress: String?, expandedReferences: Set<String>,
                     expandedDecks: Set<UUID>, addedURLs: Set<String>, fallback: String) -> [Self] {
        var rows: [Self] = []
        if messages.isEmpty { rows.append(.empty) }
        for (i, m) in messages.enumerated() {
            rows.append(.message(m, first: i == 0))
            if !m.isUser, !m.references.isEmpty {
                rows.append(.header(m.id, m.references))
                let visible = expandedDecks.contains(m.id) ? m.references : Array(m.references.prefix(5))
                rows += visible.map { .reference(m.id, $0, expanded: expandedReferences.contains($0.id),
                                                added: $0.origin == .library || addedURLs.contains($0.url)) }
                if m.references.count > 5 { rows.append(.footer(m.id, m.references.count, expanded: expandedDecks.contains(m.id))) }
            }
            if !m.isUser, m.id == messages.last?.id, !isResponding, !m.text.isEmpty { rows.append(.actions(m)) }
        }
        if isResponding { rows.append(.progress(progress ?? fallback)) }
        return rows
    }

    /// Esta limpieza es la de la fachada previa: las URLs generadas siguen siendo texto inerte.
    static func presentedText(_ msg: AIChatNativeMessage) -> String {
        guard !msg.references.isEmpty else { return msg.text }
        let cleaned = msg.text.components(separatedBy: "\n").compactMap { line -> String? in
            var l = line.replacingOccurrences(of: #"\s*\(https?://[^)\s]+\)"#, with: "", options: .regularExpression)
            l = l.replacingOccurrences(of: #"https?://[^\s)]+"#, with: "", options: .regularExpression)
            l = l.replacingOccurrences(of: #"\(\s*\)"#, with: "", options: .regularExpression)
            l = l.replacingOccurrences(of: #"\s*[|:–—-]\s*$"#, with: "", options: .regularExpression)
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t == "-" || t == "•" || t == "–" || t == "—" || t == "*" { return nil }
            return l
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Esto es lo que encontré:" : cleaned
    }
}

@MainActor
struct AIChatNativeStyle {
    let fonts: AIChatNativeFonts
    let palette: ThemePalette
    var primary: NSColor { NSColor(palette.textPrimary) }
    var secondary: NSColor { NSColor(palette.textSecondary) }
    var accent: NSColor { NSColor(palette.accent) }
    var surface: NSColor { NSColor(palette.surface) }
    var border: NSColor { NSColor(palette.border) }
    var readableAccent: NSColor { NSColor(palette.readableAccent(on: palette.surface)) }
    func equivalent(to other: Self) -> Bool {
        palette == other.palette && fonts.body == other.fonts.body && fonts.callout == other.fonts.callout && fonts.lead == other.fonts.lead
            && fonts.heading == other.fonts.heading && fonts.quote == other.fonts.quote
            && fonts.caption == other.fonts.caption && fonts.captionMedium == other.fonts.captionMedium && fonts.captionStrong == other.fonts.captionStrong && fonts.chip == other.fonts.chip
    }
}

/// Comandos proceden del DTO validado o de acciones fijas; el texto del modelo nunca los crea.
enum AIChatNativeCommand: Sendable {
    case copyMessage(UUID), regenerate, send(String), preview(AssistantLinkReference), open(AssistantLinkReference)
    case add([AssistantLinkReference]), copyURL(AssistantLinkReference), toggleReference(String), toggleDeck(UUID)
}

@MainActor
struct AIChatNativePart {
    enum Kind {
        case text(NSAttributedString, selectable: Bool, maximumLines: Int)
        case button(String, String?, AIChatNativeCommand, enabled: Bool, font: NSFont? = nil, color: NSColor? = nil)
        case menu(String, String, [(String, AIChatNativeCommand)], font: NSFont? = nil)
        case symbol(String, NSColor, CGFloat)
        case progress
    }
    var frame: CGRect
    var kind: Kind
    var background: NSColor?
    var radius: CGFloat = 0
    var tooltip: String?
}

struct AIChatNativeMetric {
    let height: CGFloat
    let textFrames: [CGRect]
    let primaryTextFrame: CGRect?
}

@MainActor
struct AIChatNativeContent {
    var parts: [AIChatNativePart] = []
    var decorations: [(CGRect, NSColor, CGFloat, NSColor?)] = []
    var height: CGFloat = 0
    var primaryTextFrame: CGRect?
    var metric: AIChatNativeMetric {
        .init(height: height, textFrames: parts.compactMap { p in if case .text = p.kind { p.frame } else { nil } },
              primaryTextFrame: primaryTextFrame)
    }
}

/// Construye exactamente el contenido que se mide y que dibuja la celda visible.
@MainActor
struct AIChatNativeRowLayout {
    let style: AIChatNativeStyle
    let width: CGFloat
    let measurer: AIChatTextKitMeasurer
    let addedURLs: Set<String>
    private var contentWidth: CGFloat { max(1, width - 2 * DesignSystem.Spacing.md) }
    private var x: CGFloat { DesignSystem.Spacing.md }

    func content(for row: AIChatNativeRow) -> AIChatNativeContent {
        var c = AIChatNativeContent()
        var y = row.topSpacing
        func plain(_ text: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
            AIChatNativeText.plain(text, font: font, color: color)
        }
        func text(_ value: NSAttributedString, at left: CGFloat, top: CGFloat, width: CGFloat,
                  lines: Int = 0, selectable: Bool = false) -> CGFloat {
            let h = measurer.height(of: value, width: max(1, width), maximumLines: lines)
            c.parts.append(.init(frame: CGRect(x: left, y: top, width: max(1, width), height: h),
                                 kind: .text(value, selectable: selectable, maximumLines: lines)))
            return h
        }
        func buttonSize(_ title: String, symbol: String?, font: NSFont, minimumHeight: CGFloat = 17, verticalPadding: CGFloat = 4) -> CGSize {
            let attr = plain(title, font, style.primary)
            let w = max(1, ceil(attr.size().width) + (symbol == nil ? 0 : 18))
            let h = max(minimumHeight, measurer.height(of: attr, width: w) + verticalPadding)
            return AIChatNativeControls.fittingSize(of: AIChatNativeControls.button(title: title, symbol: symbol, font: font, color: style.primary),
                                                   proposed: CGSize(width: w, height: h))
        }
        func button(_ title: String, symbol: String? = nil, command: AIChatNativeCommand,
                    at left: CGFloat, top: CGFloat, width: CGFloat? = nil, enabled: Bool = true,
                    color: NSColor? = nil, tooltip: String? = nil, font: NSFont? = nil, minimumHeight: CGFloat = 17, verticalPadding: CGFloat = 4) -> CGSize {
            let buttonFont = font ?? style.fonts.captionStrong
            let natural = buttonSize(title, symbol: symbol, font: buttonFont, minimumHeight: minimumHeight, verticalPadding: verticalPadding)
            let w = max(1, min(width ?? contentWidth, natural.width))
            let h = natural.height
            c.parts.append(.init(frame: CGRect(x: left, y: top, width: w, height: h),
                                 kind: .button(title, symbol, command, enabled: enabled, font: buttonFont, color: color), tooltip: tooltip))
            return CGSize(width: w, height: h)
        }
        func horizontalButtons(_ values: [(String, String?, AIChatNativeCommand)], left: CGFloat, top: CGFloat,
                               right: CGFloat, responseActions: Bool = false) -> CGFloat {
            var bx = left, by = top, lineHeight: CGFloat = 0
            for (title, symbol, command) in values {
                let natural = buttonSize(title, symbol: symbol, font: responseActions ? style.fonts.captionMedium : style.fonts.captionStrong,
                                         minimumHeight: responseActions ? 16 : 17, verticalPadding: responseActions ? 3 : 4).width
                if bx > left && bx + natural > right { bx = left; by += lineHeight + 6; lineHeight = 0 }
                let size = button(title, symbol: symbol, command: command, at: bx, top: by, width: max(1, right - bx), color: responseActions ? style.secondary : nil, font: responseActions ? style.fonts.captionMedium : nil, minimumHeight: responseActions ? 16 : 17, verticalPadding: responseActions ? 3 : 4)
                bx += size.width + 12; lineHeight = max(lineHeight, size.height)
            }
            return by + lineHeight - top
        }
        switch row {
        case .message(let m, _):
            if !m.isUser, !m.actions.isEmpty {
                for action in m.actions {
                    let attr = plain(action.title, style.fonts.chip, style.secondary)
                    let h = measurer.height(of: attr, width: max(1, contentWidth - 84)) + 6
                    let chipWidth = min(contentWidth - 60, ceil(attr.size().width) + 34)
                    c.decorations.append((CGRect(x: x, y: y, width: max(1, chipWidth), height: h), style.surface.withAlphaComponent(0.5), h / 2, nil))
                    c.parts.append(.init(frame: CGRect(x: x + 8, y: y + 3, width: 12, height: 12), kind: .symbol(action.systemImage, style.secondary, 10)))
                    _ = text(attr, at: x + 26, top: y + 3, width: max(1, chipWidth - 34))
                    y += h + 3
                }
                y += 3
            }
            let leading = m.isUser ? 50 + DesignSystem.Spacing.xs : 26 + DesignSystem.Spacing.xs
            let trailing = m.isUser ? 0 : 40 + DesignSystem.Spacing.xs
            let bubbleWidth = max(1, contentWidth - leading - trailing)
            let attr = m.isUser ? plain(m.text.isEmpty ? "…" : m.text, style.fonts.body, NSColor(style.palette.foreground(on: style.palette.accent)))
                : AIChatNativeText.structured(m.text.isEmpty ? "…" : AIChatNativeRow.presentedText(m), fonts: style.fonts, primary: style.primary, secondary: style.secondary)
            let h = text(attr, at: x + leading + 12, top: y + 9, width: max(1, bubbleWidth - 24), selectable: true)
            c.primaryTextFrame = c.parts.last?.frame
            c.decorations.append((CGRect(x: x + leading, y: y, width: bubbleWidth, height: h + 18), m.isUser ? style.accent : style.surface, 14, nil))
            if !m.isUser {
                c.decorations.append((CGRect(x: x, y: y, width: 26, height: 26), style.accent.withAlphaComponent(0.14), 13, nil))
                c.parts.append(.init(frame: CGRect(x: x + 6, y: y + 6, width: 14, height: 14), kind: .symbol("sparkles", style.accent, 12)))
            }
            y += max(h + 18, m.isUser ? 0 : 26)
        case .header(_, let refs):
            let local = refs.count { $0.origin == .library }, web = refs.count - local
            let title = local == refs.count ? (local == 1 ? "1 enlace de tu biblioteca" : "\(local) enlaces de tu biblioteca")
                : web == refs.count ? (web == 1 ? "1 fuente web" : "\(web) fuentes web") : "\(refs.count) fuentes"
            let pending = refs.filter { $0.origin == .web && !addedURLs.contains($0.url) }
            let right = x + max(1, contentWidth - 40) - 4
            var reserve: CGFloat = 0, bh: CGFloat = 0
            if pending.count > 1 {
                let natural = buttonSize("Agregar todos", symbol: "plus.rectangle.on.rectangle", font: style.fonts.captionStrong).width
                let s = button("Agregar todos", symbol: "plus.rectangle.on.rectangle", command: .add(pending), at: max(x + 4, right - natural), top: y,
                               width: max(1, right - x - 4), tooltip: "Agregar todos los resultados a tu biblioteca")
                reserve = s.width + 8; bh = s.height
            }
            c.parts.append(.init(frame: CGRect(x: x + 4, y: y + 2, width: 12, height: 12), kind: .symbol(local > 0 && web == 0 ? "books.vertical" : "globe", style.secondary, 11)))
            y += max(bh, text(plain(title, style.fonts.captionStrong, style.secondary), at: x + 20, top: y, width: max(1, right - x - 20 - reserve)))
        case .reference(_, let ref, let expanded, let added):
            let cardWidth = max(1, contentWidth - 40), cardTop = y, left = x + 12, inner = max(1, cardWidth - 24)
            y += 12
            c.decorations.append((CGRect(x: left, y: y, width: 28, height: 28), style.accent.withAlphaComponent(0.12), 8, nil))
            c.parts.append(.init(frame: CGRect(x: left + 7, y: y + 7, width: 14, height: 14), kind: .symbol(ref.origin == .library ? "bookmark.fill" : "globe", style.accent, 11)))
            let titleWidth = max(1, inner - 68)
            let th = text(plain(ref.title, style.fonts.heading, style.primary), at: left + 38, top: y, width: titleWidth, lines: 2)
            let host = URL(string: ref.url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? ref.url
            let hh = text(plain(host, style.fonts.caption, style.secondary), at: left + 38, top: y + th + 2, width: titleWidth, lines: 1)
            // El botón cubre título y host; TextKit conserva exactamente las mismas métricas.
            c.parts.append(.init(frame: CGRect(x: left + 38, y: y, width: titleWidth, height: th + 2 + hh),
                                 kind: .button("", nil, .preview(ref), enabled: true), tooltip: "Previsualizar la fuente sin salir del chat"))
            _ = button("", symbol: expanded ? "chevron.up.circle.fill" : "chevron.down.circle", command: .toggleReference(ref.id),
                       at: x + cardWidth - 32, top: y, width: 20, tooltip: expanded ? "Ocultar detalles" : "Mostrar vista rápida")
            y += max(28, th + 2 + hh)
            if expanded {
                y += 4
                let summary = (ref.summary?.isEmpty == false ? ref.summary! : (ref.origin == .library ? "Este enlace ya forma parte de tu biblioteca." : "Abre la previsualización para consultar los metadatos de la página."))
                y += text(plain(summary, style.fonts.caption, style.secondary), at: left + 38, top: y, width: max(1, inner - 38), lines: ref.summary?.isEmpty == false ? 5 : 0)
                let metadata = (ref.collection.map { [("folder", $0)] } ?? []) + Array(ref.tags.prefix(3)).map { ("tag", $0) }
                if !metadata.isEmpty {
                    y += 7
                    var mx = left + 38, mh: CGFloat = 0
                    let remaining = max(1, inner - 38), slot = max(1, (remaining - CGFloat(metadata.count - 1) * 6) / CGFloat(metadata.count))
                    for (symbol, label) in metadata {
                        let labelHeight = measurer.height(of: plain(label, style.fonts.chip, style.secondary), width: max(1, slot - 14), maximumLines: 1)
                        c.parts.append(.init(frame: CGRect(x: mx, y: y, width: min(10, slot), height: labelHeight), kind: .symbol(symbol, style.secondary, 10)))
                        mh = max(mh, text(plain(label, style.fonts.chip, style.secondary), at: mx + min(14, slot), top: y, width: max(1, slot - 14), lines: 1))
                        mx += slot + 6
                    }
                    y += mh
                }
            }
            y += 4
            var actions: [(String, String?, AIChatNativeCommand)] = [("Previsualizar", "eye", .preview(ref))]
            if URL(string: ref.url) != nil { actions.append(("Abrir", "arrow.up.right.square", .open(ref))) }
            let actionStart = y
            y += horizontalButtons(actions, left: left, top: y, right: left + inner - 22)
            c.parts.append(.init(frame: CGRect(x: left + inner - 18, y: actionStart, width: 18, height: max(17, y - actionStart)),
                kind: .menu("Más acciones para \(ref.title)", "ellipsis.circle", [("Preguntar por este enlace", .send("Analiza este enlace de la última respuesta y dime por qué es relevante: \(ref.url)")), ("Copiar enlace", .copyURL(ref))])))
            y += 4
            if ref.origin == .web {
                y += button(added ? "Añadido" : "Agregar", symbol: added ? "checkmark.circle.fill" : "plus.circle", command: .add([ref]), at: left, top: y, width: inner,
                            enabled: !added, color: style.readableAccent).height
            } else {
                y += text(plain("En tu biblioteca", style.fonts.captionStrong, style.secondary), at: left, top: y, width: inner)
            }
            y += 12
            c.decorations.insert((CGRect(x: x, y: cardTop, width: cardWidth, height: y - cardTop), style.surface, 12,
                                  expanded ? style.accent.withAlphaComponent(0.28) : style.border.withAlphaComponent(0.5)), at: 0)
        case .footer(let id, let count, let expanded):
            y += button(expanded ? "Mostrar menos" : "Mostrar \(count - 5) más", symbol: expanded ? "chevron.up" : "chevron.down",
                        command: .toggleDeck(id), at: x + 4, top: y, width: max(1, contentWidth - 44)).height
        case .actions(let m):
            let values: [(String, String?, AIChatNativeCommand)] = [("Copiar", "doc.on.doc", .copyMessage(m.id)), ("Regenerar", "arrow.clockwise", .regenerate)]
            let top = y + 1
            let height = horizontalButtons(values, left: x + 34, top: top, right: x + contentWidth, responseActions: true)
            var menu: [(String, AIChatNativeCommand)] = [("Explícalo con más detalle", .send("Amplía la última respuesta con más detalle, manteniendo una estructura clara.")),
                ("Hazlo más breve", .send("Resume la última respuesta en tres puntos claros como máximo."))]
            if !m.references.isEmpty { menu.append(("Compara los enlaces", .send("Compara los enlaces de la última respuesta y dime las diferencias clave."))) }
            let lastFrame = c.parts.last?.frame ?? CGRect(x: x + 34, y: top, width: 0, height: 16)
            let menuSize = AIChatNativeControls.fittingSize(of: AIChatNativeControls.menu(title: "Continuar", symbol: "ellipsis.bubble", font: style.fonts.captionMedium, color: style.secondary),
                proposed: CGSize(width: ceil(plain("Continuar", style.fonts.captionStrong, style.secondary).size().width) + 18, height: max(16, lastFrame.height)))
            let menuFits = lastFrame.maxX + 12 + menuSize.width <= x + contentWidth
            let menuTop = menuFits ? lastFrame.minY : top + height + 6
            c.parts.append(.init(frame: CGRect(x: menuFits ? lastFrame.maxX + 12 : x + 34, y: menuTop, width: menuSize.width, height: menuSize.height),
                                 kind: .menu("Continuar", "ellipsis.bubble", menu, font: style.fonts.captionMedium), tooltip: "Continuar a partir de esta respuesta"))
            y = max(top + height, menuTop + menuSize.height)
        case .progress(let value):
            c.parts.append(.init(frame: CGRect(x: x, y: y, width: 14, height: 14), kind: .progress))
            y += max(14, text(plain(value, style.fonts.caption, style.secondary), at: x + 20, top: y, width: max(1, contentWidth - 20)))
        case .empty:
            let invitation = "Pregúntame por tus enlaces, busca en internet, o pídeme que organice, etiquete o navegue por la app."
            y += text(plain(invitation, style.fonts.callout, style.secondary), at: x, top: y, width: contentWidth)
            y += DesignSystem.Spacing.md
            let w = min(440, contentWidth), left = x + max(0, (contentWidth - w) / 2)
            for prompt in Self.suggestedPrompts {
                let attr = plain(prompt, style.fonts.callout, style.primary)
                let h = measurer.height(of: attr, width: max(1, w - 64)) + 20
                c.decorations.append((CGRect(x: left, y: y, width: w, height: h), style.surface, 12, style.border.withAlphaComponent(0.5)))
                c.parts.append(.init(frame: CGRect(x: left + 12, y: y + 10, width: 12, height: 12), kind: .symbol("sparkles", style.accent, 11)))
                _ = text(attr, at: left + 32, top: y + 10, width: max(1, w - 64))
                c.parts.append(.init(frame: CGRect(x: left + w - 24, y: y + 10, width: 12, height: 12), kind: .symbol("arrow.up.right", style.secondary, 10)))
                c.parts.append(.init(frame: CGRect(x: left, y: y, width: w, height: h), kind: .button("", nil, .send(prompt), enabled: true), tooltip: prompt))
                y += h + DesignSystem.Spacing.xs
            }
            y -= DesignSystem.Spacing.xs
        }
        c.height = max(1, y)
        return c
    }
    static let suggestedPrompts = ["¿Cuántos enlaces tengo y de qué temas?", "Optimiza mi biblioteca y quita duplicados",
        "Etiqueta y clasifica mis enlaces sin clasificar", "¿Qué enlaces están rotos?", "Busca en internet apps de productividad para Mac"]
}
