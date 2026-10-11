import AppKit

@MainActor
enum AIChatNativeControls {
    static func button(title: String, symbol: String?, font: NSFont, color: NSColor) -> NSButton {
        let button = NSButton(frame: .zero)
        button.title = title; button.font = font
        button.isBordered = false; button.bezelStyle = .inline; button.alignment = .left
        button.contentTintColor = color
        button.attributedTitle = AIChatNativeText.plain(title, font: font, color: color)
        if let symbol { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading }
        return button
    }
    static func menu(title: String, symbol: String, font: NSFont, color: NSColor) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false; button.bezelStyle = .inline; button.font = font
        button.imagePosition = title.hasPrefix("Más acciones") ? .imageOnly : .imageLeading
        let menu = NSMenu()
        let label = NSMenuItem(title: title.hasPrefix("Más acciones") ? "" : title, action: nil, keyEquivalent: "")
        label.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        label.attributedTitle = AIChatNativeText.plain(label.title, font: font, color: color)
        menu.addItem(label); button.menu = menu
        return button
    }
    static func fittingSize(of button: NSButton, proposed: CGSize) -> CGSize {
        guard !button.title.isEmpty, let cell = button.cell else { return proposed }
        button.setFrameSize(proposed)
        let title = button.attributedTitle.size(), rect = cell.titleRect(forBounds: button.bounds)
        guard rect.width < title.width || rect.height < title.height else { return proposed }
        let native = button.intrinsicContentSize
        return CGSize(width: ceil(max(proposed.width + max(0, title.width - rect.width), native.width)),
                      height: ceil(max(proposed.height + max(0, title.height - rect.height), native.height, cell.cellSize.height)))
    }
}

@MainActor
private final class AIChatCommandTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke(_ sender: Any?) { action() }
}

/// Una celda posee únicamente el text system de su contenido visible. El pool se devuelve vacío.
@MainActor
final class AIChatNativeCell: NSView {
    private(set) var rowID: AIChatNativeRowID?
    private(set) var textViews: [NSTextView] = []
    var primarySelectableText: (index: Int, view: NSTextView)? {
        guard let index = textViews.firstIndex(where: { $0.isSelectable }) else { return nil }
        return (index, textViews[index])
    }
    private(set) var controls: [NSControl] = []
    private var targets: [AIChatCommandTarget] = []
    private var decorations: [(CGRect, NSColor, CGFloat, NSColor?)] = []
    private var tooltipRegions: [(CGRect, String)] = []
    private var hover: ((String?, CGRect) -> Void)?
    private var tracking: NSTrackingArea?
    private var hoveredRegion: Int?
    var onWillDetach: ((AIChatNativeCell) -> Void)?
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { onWillDetach?(self) }
        super.viewWillMove(toWindow: newWindow)
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    func configure(id: AIChatNativeRowID, content: AIChatNativeContent, style: AIChatNativeStyle,
                   command: @escaping (AIChatNativeCommand) -> Void, hover: @escaping (String?, CGRect) -> Void = { _, _ in }) {
        clear(); rowID = id; decorations = content.decorations; self.hover = hover
        tooltipRegions = content.parts.compactMap { p in p.tooltip.map { (p.frame, $0) } }
        for part in content.parts {
            switch part.kind {
            case .text(let attributed, let selectable, let maximumLines):
                let storage = NSTextStorage(attributedString: attributed)
                let manager = NSLayoutManager(); manager.allowsNonContiguousLayout = false
                let container = NSTextContainer(containerSize: NSSize(width: max(1, part.frame.width), height: .greatestFiniteMagnitude))
                container.lineFragmentPadding = 0
                container.widthTracksTextView = false; container.heightTracksTextView = false
                container.maximumNumberOfLines = maximumLines
                container.lineBreakMode = maximumLines > 0 ? .byTruncatingTail : .byWordWrapping
                storage.addLayoutManager(manager); manager.addTextContainer(container)
                let view = NSTextView(frame: part.frame, textContainer: container)
                view.isEditable = false; view.isSelectable = selectable
                view.isRichText = true; view.importsGraphics = false; view.allowsUndo = false
                view.drawsBackground = false; view.textContainerInset = .zero
                view.isVerticallyResizable = false; view.isHorizontallyResizable = false
                view.isAutomaticLinkDetectionEnabled = false; view.isAutomaticDataDetectionEnabled = false
                view.isAutomaticTextReplacementEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
                view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticSpellingCorrectionEnabled = false
                view.setAccessibilityElement(false)
                addSubview(view); textViews.append(view)
            case .button(let title, let symbol, let value, let enabled, let font, let color):
                let button = AIChatNativeControls.button(title: title, symbol: symbol, font: font ?? style.fonts.captionStrong, color: color ?? style.primary)
                button.frame = part.frame
                button.isEnabled = enabled; button.setAccessibilityHelp(part.tooltip)
                if title.isEmpty && symbol == nil { button.isTransparent = true }
                let target = AIChatCommandTarget { command(value) }
                button.target = target; button.action = #selector(AIChatCommandTarget.invoke(_:))
                targets.append(target); controls.append(button); addSubview(button)
                button.setAccessibilityElement(false)
            case .menu(let title, let symbol, let items, let font):
                let button = AIChatNativeControls.menu(title: title, symbol: symbol, font: font ?? style.fonts.captionStrong, color: style.secondary)
                button.frame = part.frame
                let menu = button.menu!
                for (label, value) in items {
                    let item = NSMenuItem(title: label, action: #selector(AIChatCommandTarget.invoke(_:)), keyEquivalent: "")
                    let target = AIChatCommandTarget { command(value) }; targets.append(target); item.target = target
                    menu.addItem(item)
                }
                button.menu = menu; button.setAccessibilityHelp(part.tooltip ?? title)
                button.setAccessibilityElement(false)
                controls.append(button); addSubview(button)
            case .symbol(let name, let color, let size):
                let image = NSImageView(frame: part.frame)
                image.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: .semibold))
                image.contentTintColor = color; image.imageScaling = .scaleProportionallyDown
                image.setAccessibilityElement(false); addSubview(image)
            case .progress:
                let indicator = NSProgressIndicator(frame: part.frame)
                indicator.style = .spinning; indicator.controlSize = .small; indicator.isIndeterminate = true
                indicator.startAnimation(nil); indicator.setAccessibilityElement(false); addSubview(indicator)
            }
        }
        updateTrackingAreas(); needsDisplay = true
    }
    func clear() {
        onWillDetach = nil
        hover?(nil, .zero); hover = nil; tooltipRegions.removeAll(); hoveredRegion = nil
        for control in controls {
            control.target = nil; control.action = nil
            if let popup = control as? NSPopUpButton {
                for item in popup.menu?.items ?? [] { item.target = nil; item.action = nil }
            }
        }
        if let tracking { removeTrackingArea(tracking) }; tracking = nil
        for view in textViews { view.textStorage?.setAttributedString(NSAttributedString(string: "")); view.delegate = nil }
        for indicator in subviews.compactMap({ $0 as? NSProgressIndicator }) { indicator.stopAnimation(nil) }
        for view in subviews { view.removeFromSuperview() }
        textViews.removeAll(); controls.removeAll(); targets.removeAll(); decorations.removeAll(); rowID = nil
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }; tracking = nil
        guard !tooltipRegions.isEmpty else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        tracking = area; addTrackingArea(area)
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = tooltipRegions.firstIndex { $0.0.contains(point) }
        guard index != hoveredRegion else { return }; hoveredRegion = index
        if let index { let region = tooltipRegions[index]; hover?(region.1, region.0) }
        else { hover?(nil, .zero) }
    }
    override func mouseExited(with event: NSEvent) { hoveredRegion = nil; hover?(nil, .zero) }
    func contains(_ responder: NSResponder) -> Bool {
        guard var view = responder as? NSView else { return false }
        for _ in 0..<32 {
            if view === self { return true }
            guard let parent = view.superview else { return false }; view = parent
        }
        return false
    }
    override func draw(_ dirtyRect: NSRect) {
        for (rect, fill, radius, border) in decorations where rect.intersects(dirtyRect) {
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            fill.setFill(); path.fill()
            if let border { border.setStroke(); path.lineWidth = 0.5; path.stroke() }
        }
    }
}

/// La tabla expone todas las filas lógicas a AX, sin construir sus vistas fuera del clip.
@MainActor
final class AIChatNativeTableView: NSTableView {
    weak var controller: AIChatNativeController?
    var logicalRows: [AIChatAccessibilityRow] = []
    override func accessibilityRows() -> [any NSAccessibilityRow]? { logicalRows }
    override func accessibilityChildren() -> [Any]? { logicalRows }
    override func accessibilityVisibleRows() -> [any NSAccessibilityRow]? {
        let range = rows(in: visibleRect)
        guard range.location != NSNotFound else { return [] }
        return Array(logicalRows.dropFirst(range.location).prefix(range.length))
    }
    override func accessibilityCell(forColumn column: Int, row: Int) -> Any? {
        guard column == 0, logicalRows.indices.contains(row) else { return nil }
        return logicalRows[row]
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.control, .option]).isEmpty, let key = event.specialKey,
           controller?.navigate(key, command: event.modifierFlags.contains(.command)) == true { return }
        controller?.beginInteraction(); super.keyDown(with: event)
    }
}

/// NSObject expone callbacks síncronos. El estado se mantiene en un objeto MainActor
/// independiente; los resultados que cruzan la frontera son valores Sendable.
nonisolated private func AIChatAccessibilityMain<T: Sendable>(_ body: @MainActor @Sendable () -> T) -> T {
    if Thread.isMainThread { return MainActor.assumeIsolated { body() } }
    return DispatchQueue.main.sync { body() }
}

@MainActor
private final class AIChatAccessibilityState {
    weak var controller: AIChatNativeController?
    let id: AIChatNativeRowID
    let sessionID: UUID?
    init(controller: AIChatNativeController, id: AIChatNativeRowID) {
        self.controller = controller; self.id = id; sessionID = controller.snapshot?.sessionID
    }
    var index: Int? {
        guard let snapshot = controller?.snapshot, snapshot.sessionID == sessionID else { return nil }
        return snapshot.index(of: id)
    }
    var row: AIChatNativeRow? { guard let index else { return nil }; return controller?.snapshot?.rows[index] }
    func frame() -> CGRect {
        guard let controller, let index, let window = controller.table.window else { return .zero }
        return window.convertToScreen(controller.table.convert(controller.table.rect(ofRow: index), to: nil))
    }
    func label() -> String {
        switch row {
        case .message(let m, _): (m.isUser ? "Tu mensaje" : "Respuesta del asistente") + (m.actions.isEmpty ? "" : ": " + m.actions.map(\.title).joined(separator: ", "))
        case .reference(_, let r, _, _): r.title
        case .header: "Fuentes de la respuesta"
        case .footer: "Más fuentes"
        case .actions: "Acciones de respuesta"
        case .progress(let value): value
        case .empty: "Iniciar conversación"
        case .none: ""
        }
    }
    func primaryText() -> NSAttributedString? {
        guard let style = controller?.snapshot?.style, case .message(let m, _) = row else { return nil }
        return m.isUser ? AIChatNativeText.plain(m.text.isEmpty ? "…" : m.text, font: style.fonts.body, color: NSColor(style.palette.foreground(on: style.palette.accent)))
            : AIChatNativeText.structured(m.text.isEmpty ? "…" : AIChatNativeRow.presentedText(m), fonts: style.fonts, primary: style.primary, secondary: style.secondary)
    }
    func value() -> String {
        autoreleasepool {
            if let primary = primaryText() { return primary.string }
            switch row {
            case .reference(_, let ref, let expanded, let added):
                let host = URL(string: ref.url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? ref.url
                var values = [ref.title, host, ref.origin == .library ? "En tu biblioteca" : (added ? "Añadido" : "Fuente web")]
                if expanded {
                    values.append(ref.summary?.isEmpty == false ? ref.summary! : (ref.origin == .library ? "Este enlace ya forma parte de tu biblioteca." : "Abre la previsualización para consultar los metadatos de la página."))
                    if let collection = ref.collection { values.append(collection) }; values += Array(ref.tags.prefix(3))
                }
                return values.joined(separator: "\n")
            case .header(_, let refs):
                let local = refs.count { $0.origin == .library }
                if local == refs.count { return refs.count == 1 ? "1 enlace de tu biblioteca" : "\(refs.count) enlaces de tu biblioteca" }
                if local == 0 { return refs.count == 1 ? "1 fuente web" : "\(refs.count) fuentes web" }
                return "\(refs.count) fuentes"
            case .footer(_, let count, let expanded): return expanded ? "Mostrar menos" : "Mostrar \(count - 5) más"
            case .progress(let text): return text
            case .empty: return "Pregúntame por tus enlaces, busca en internet, o pídeme que organice, etiquete o navegue por la app."
            default: return label()
            }
        }
    }
    func commands() -> [(String, AIChatNativeCommand)] {
        switch row {
        case .reference(_, let ref, let expanded, let added):
            var values: [(String, AIChatNativeCommand)] = [("Previsualizar", .preview(ref)),
                (expanded ? "Ocultar detalles" : "Mostrar vista rápida", .toggleReference(ref.id)),
                ("Preguntar por este enlace", .send("Analiza este enlace de la última respuesta y dime por qué es relevante: \(ref.url)")), ("Copiar enlace", .copyURL(ref))]
            if URL(string: ref.url) != nil { values.insert(("Abrir", .open(ref)), at: 1) }
            if ref.origin == .web && !added { values.append(("Agregar", .add([ref]))) }
            return values
        case .header(_, let refs):
            let pending = refs.filter { $0.origin == .web && controller?.snapshot?.addedURLs.contains($0.url) != true }
            return pending.count > 1 ? [("Agregar todos", .add(pending))] : []
        case .footer(let id, let count, let expanded): return [(expanded ? "Mostrar menos" : "Mostrar \(count - 5) más", .toggleDeck(id))]
        case .actions(let m):
            var values: [(String, AIChatNativeCommand)] = [("Copiar", .copyMessage(m.id)), ("Regenerar", .regenerate),
                ("Explícalo con más detalle", .send("Amplía la última respuesta con más detalle, manteniendo una estructura clara.")),
                ("Hazlo más breve", .send("Resume la última respuesta en tres puntos claros como máximo."))]
            if !m.references.isEmpty { values.append(("Compara los enlaces", .send("Compara los enlaces de la última respuesta y dime las diferencias clave."))) }
            return values
        case .empty: return AIChatNativeRowLayout.suggestedPrompts.map { ($0, .send($0)) }
        default: return []
        }
    }
    func perform(_ command: AIChatNativeCommand) -> Bool {
        guard index != nil, let controller else { return false }; controller.perform(command); return true
    }
    func focus() -> Bool {
        guard index != nil, let cell = controller?.materialize(id) else { return false }
        return cell.window?.makeFirstResponder(cell.primarySelectableText?.view ?? cell) ?? false
    }
    func selection() -> NSRange { guard index != nil else { return NSRange(location: 0, length: 0) }; return controller?.selection(for: id) ?? NSRange(location: 0, length: 0) }
    func setSelection(_ range: NSRange) { guard index != nil else { return }; controller?.setSelection(range, for: id) }
    func isFocused() -> Bool { index != nil && controller?.isFocused(id) == true }
    func line(for index: Int) -> Int {
        guard let controller, let i = self.index, let snapshot = controller.snapshot,
              let rect = snapshot.metrics[i].primaryTextFrame, let text = primaryText() else {
            let v = value() as NSString
            return v.substring(to: min(max(0, index), v.length)).components(separatedBy: "\n").count - 1
        }
        return controller.anchorMeasurer.line(for: index, in: text, width: rect.width)
    }
    func range(forLine line: Int) -> NSRange {
        guard let controller, let i = index, let snapshot = controller.snapshot,
              let rect = snapshot.metrics[i].primaryTextFrame, let text = primaryText() else {
            let lines = value().components(separatedBy: "\n")
            guard lines.indices.contains(line) else { return NSRange(location: NSNotFound, length: 0) }
            return NSRange(location: lines.prefix(line).reduce(0) { $0 + $1.utf16.count + 1 }, length: lines[line].utf16.count)
        }
        return controller.anchorMeasurer.range(forLine: line, in: text, width: rect.width)
    }
    func textFrame(range: NSRange) -> CGRect {
        guard let controller, let i = index, let snapshot = controller.snapshot, let window = controller.table.window,
              let primary = snapshot.metrics[i].primaryTextFrame, let text = primaryText() else { return frame() }
        let local = controller.anchorMeasurer.frame(for: range, in: text, width: primary.width)
        let rowRect = controller.table.rect(ofRow: i)
        let rect = local.offsetBy(dx: primary.minX, dy: rowRect.minY + primary.minY)
        return window.convertToScreen(controller.table.convert(rect, to: nil))
    }
}

@MainActor
final class AIChatAccessibilityRow: NSAccessibilityElement, NSAccessibilityRow {
    nonisolated private let state: AIChatAccessibilityState
    private let textElement: AIChatAccessibilityText
    private let actionElements: [AIChatAccessibilityAction]
    init(controller: AIChatNativeController, id: AIChatNativeRowID) {
        let state = AIChatAccessibilityState(controller: controller, id: id)
        self.state = state; self.textElement = AIChatAccessibilityText(state: state)
        self.actionElements = state.commands().map { AIChatAccessibilityAction(state: state, label: $0.0, command: $0.1) }
        super.init(); setAccessibilityRole(.row); setAccessibilityParent(controller.table)
        textElement.setAccessibilityParent(self)
        for action in actionElements { action.setAccessibilityParent(self) }
        setAccessibilityChildren([textElement] + actionElements)
        setAccessibilityCustomActions(state.commands().map { title, command in
            NSAccessibilityCustomAction(name: title) { AIChatAccessibilityMain { state.perform(command) } }
        })
    }
    required init?(coder: NSCoder) { nil }
    nonisolated override func accessibilityIdentifier() -> String { let state = state; return AIChatAccessibilityMain { "transcript-row-\(String(describing: state.id))" } }
    nonisolated override func accessibilityIndex() -> Int { let state = state; return AIChatAccessibilityMain { state.index ?? 0 } }
    nonisolated override func accessibilityFrame() -> NSRect { let state = state; return AIChatAccessibilityMain { state.frame() } }
    nonisolated override func accessibilityLabel() -> String? { let state = state; return AIChatAccessibilityMain { state.label() } }
    nonisolated override func accessibilityPerformPress() -> Bool { let state = state; return AIChatAccessibilityMain { state.focus() } }
}

@MainActor
private final class AIChatAccessibilityAction: NSAccessibilityElement {
    nonisolated private let state: AIChatAccessibilityState
    nonisolated private let command: AIChatNativeCommand
    init(state: AIChatAccessibilityState, label: String, command: AIChatNativeCommand) {
        self.state = state; self.command = command; super.init()
        setAccessibilityRole(.button); setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { nil }
    nonisolated override func accessibilityPerformPress() -> Bool { let state = state, command = command; return AIChatAccessibilityMain { state.perform(command) } }
}

@MainActor
private final class AIChatAccessibilityText: NSAccessibilityElement {
    nonisolated private let state: AIChatAccessibilityState
    init(state: AIChatAccessibilityState) { self.state = state; super.init(); setAccessibilityRole(.staticText) }
    required init?(coder: NSCoder) { nil }
    nonisolated override func accessibilityValue() -> Any? { let state = state; return AIChatAccessibilityMain { state.value() } }
    nonisolated override func accessibilityFrame() -> NSRect { let state = state; return AIChatAccessibilityMain { state.frame() } }
    nonisolated override func accessibilityNumberOfCharacters() -> Int { let state = state; return AIChatAccessibilityMain { state.value().utf16.count } }
    nonisolated override func accessibilityString(for range: NSRange) -> String? {
        let state = state
        return AIChatAccessibilityMain {
            let value = state.value() as NSString
            guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= value.length else { return nil }
            return value.substring(with: range)
        }
    }
    nonisolated override func accessibilityRange(for index: Int) -> NSRange {
        let state = state
        return AIChatAccessibilityMain {
            let value = state.value() as NSString
            guard index >= 0, index < value.length else { return NSRange(location: NSNotFound, length: 0) }
            return value.rangeOfComposedCharacterSequence(at: index)
        }
    }
    nonisolated override func accessibilityLine(for index: Int) -> Int { let state = state; return AIChatAccessibilityMain { state.line(for: index) } }
    nonisolated override func accessibilityRange(forLine line: Int) -> NSRange { let state = state; return AIChatAccessibilityMain { state.range(forLine: line) } }
    nonisolated override func accessibilityFrame(for range: NSRange) -> NSRect { let state = state; return AIChatAccessibilityMain { state.textFrame(range: range) } }
    nonisolated override func accessibilityPerformPress() -> Bool { let state = state; return AIChatAccessibilityMain { state.focus() } }
    nonisolated override func setAccessibilityFocused(_ focused: Bool) { let state = state; if focused { AIChatAccessibilityMain { _ = state.focus() } } }
    nonisolated override func isAccessibilityFocused() -> Bool { let state = state; return AIChatAccessibilityMain { state.isFocused() } }
    nonisolated override func accessibilitySelectedTextRange() -> NSRange { let state = state; return AIChatAccessibilityMain { state.selection() } }
    nonisolated override func setAccessibilitySelectedTextRange(_ range: NSRange) { let state = state; AIChatAccessibilityMain { state.setSelection(range) } }
    nonisolated override func accessibilitySelectedText() -> String? {
        let state = state
        return AIChatAccessibilityMain {
            let value = state.value() as NSString, range = state.selection()
            guard range.location != NSNotFound, range.location <= value.length, range.length <= value.length - range.location else { return nil }
            return value.substring(with: range)
        }
    }
}
