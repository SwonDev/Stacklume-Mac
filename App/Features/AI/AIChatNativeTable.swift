import AppKit
import SwiftUI
import OSLog

struct AIChatNativeTooltip: Equatable {
    let text: String
    let rect: CGRect
}

@MainActor
struct AIChatNativeTranscriptInput {
    let sessionID: UUID
    let messages: [AIChatNativeMessage]
    let rows: [AIChatNativeRow]
    let style: AIChatNativeStyle
    let addedURLs: Set<String>
    let expandedDecks: Set<UUID>
    let containerWidth: CGFloat
    var latestUserID: UUID? { messages.last(where: \.isUser)?.id }
    var latestMessageID: UUID? { messages.last?.id }
    var tokenBlock: Int { (messages.last?.text.count ?? 0) / 180 }
}

@MainActor
struct AIChatNativeTranscriptRepresentable: NSViewRepresentable {
    let input: AIChatNativeTranscriptInput
    let scrollState: TranscriptScrollState
    let callbacks: AIChatTranscriptCallbacks
    let onWidthChange: @MainActor (CGFloat, CGFloat) -> Void
    let onToggleReference: @MainActor (String) -> Void
    let onToggleDeck: @MainActor (UUID) -> Void
    let onTooltipChange: @MainActor (AIChatNativeTooltip?) -> Void
    func makeCoordinator() -> AIChatNativeController { AIChatNativeController(scrollState: scrollState) }
    func makeNSView(context: Context) -> AIChatNativeScrollView {
        let view = AIChatNativeScrollView()
        context.coordinator.install(in: view)
        return view
    }
    func updateNSView(_ view: AIChatNativeScrollView, context: Context) {
        context.coordinator.callbacks = callbacks
        context.coordinator.onWidthChange = onWidthChange
        context.coordinator.onToggleReference = onToggleReference
        context.coordinator.onToggleDeck = onToggleDeck
        context.coordinator.onTooltipChange = onTooltipChange
        context.coordinator.update(input)
    }
    static func dismantleNSView(_ view: AIChatNativeScrollView, coordinator: AIChatNativeController) { coordinator.invalidate() }
}

@MainActor
final class AIChatNativeScrollView: NSScrollView {
    var onLayout: (() -> Void)?
    var onInteraction: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
    override func scrollWheel(with event: NSEvent) { onInteraction?(); super.scrollWheel(with: event) }
}

@MainActor
final class AIChatNativeController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = AIChatNativeTableView()
    let engine = AIChatSnapshotEngine()
    private(set) var snapshot: AIChatNativeSnapshot?
    private var input: AIChatNativeTranscriptInput?
    private weak var scroll: AIChatNativeScrollView?
    private var requestedWidth: CGFloat = 0
    private var requestedInput: AIChatNativeTranscriptInput?
    private var boundsObserver: NSObjectProtocol?
    private var liveScrollObservers: [NSObjectProtocol] = []
    private var liveScrollTracking = false
    private var idleTask: Task<Void, Never>?
    private var tooltipTask: Task<Void, Never>?
    private var tooltipGeneration: UInt64 = 0
    private var widthCallbackPending = false
    private let loadingIndicator = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "Preparando historial…")
    private var pendingFollow = false
    private var pendingDeliberate = false
    private var geometryAnchor: AIChatReadingAnchor?
    private var focusedRowID: AIChatNativeRowID?
    private var selectedRange = NSRange(location: 0, length: 0)
    private var focusedPartIndex: Int?
    private var focusedControlIndex: Int?
    let anchorMeasurer = AIChatTextKitMeasurer()
    private let cellRegistry = NSHashTable<AIChatNativeCell>.weakObjects()
    private let scrollState: TranscriptScrollState
    var callbacks: AIChatTranscriptCallbacks?
    var onWidthChange: (@MainActor (CGFloat, CGFloat) -> Void)?
    var onToggleReference: (@MainActor (String) -> Void)?
    var onToggleDeck: (@MainActor (UUID) -> Void)?
    var onTooltipChange: (@MainActor (AIChatNativeTooltip?) -> Void)?
    private static let diagnosticsEnabled = ProcessInfo.processInfo.environment["STACKLUME_CHAT_MEMORY_DIAGNOSTICS"] == "1"
    private static let logger = Logger(subsystem: "com.swondev.stacklume", category: "ChatMemory")
    private var reports = 0
    private let diagnosticsStarted = ProcessInfo.processInfo.systemUptime
    init(scrollState: TranscriptScrollState) { self.scrollState = scrollState; super.init() }

    func install(in scroll: AIChatNativeScrollView) {
        self.scroll = scroll
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.contentView.postsBoundsChangedNotifications = true
        table.controller = self
        table.delegate = self; table.dataSource = self
        table.style = .plain
        table.allowsColumnReordering = false; table.allowsColumnResizing = false
        table.headerView = nil; table.backgroundColor = .clear
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = .zero
        table.autoresizingMask = [.width]
        table.rowSizeStyle = .custom
        table.gridStyleMask = []
        table.selectionHighlightStyle = .none
        table.allowsMultipleSelection = false; table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transcript"))
        column.minWidth = 1; column.maxWidth = .greatestFiniteMagnitude
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        scroll.documentView = table
        loadingIndicator.style = .spinning; loadingIndicator.isIndeterminate = true; loadingIndicator.controlSize = .small
        loadingIndicator.startAnimation(nil)
        scroll.addSubview(loadingIndicator); scroll.addSubview(loadingLabel)
        loadingIndicator.setAccessibilityLabel("Preparando historial")
        scroll.onLayout = { [weak self] in self?.layoutChanged() }
        scroll.onInteraction = { [weak self] in self?.beginInteraction() }
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.boundsChanged() }
            }
        for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
            liveScrollObservers.append(NotificationCenter.default.addObserver(forName: name, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSScrollView.willStartLiveScrollNotification { self.liveScrollTracking = true }
                    if name == NSScrollView.didEndLiveScrollNotification { self.liveScrollTracking = false }
                    self.beginInteraction()
                }
            })
        }
        table.setAccessibilityLabel("Conversación")
    }
    func update(_ next: AIChatNativeTranscriptInput) {
        let previous = input
        let deliberate = previous.map { $0.sessionID != next.sessionID || (next.latestUserID != nil && $0.latestUserID != next.latestUserID) } ?? false
        if deliberate { geometryAnchor = nil; scrollState.followsResponse = true; scrollState.isExploring = false; pendingDeliberate = true }
        if let previous, previous.sessionID != next.sessionID {
            // Un cambio de chat no deja visible el documento de otra sesión mientras se mide.
            saveFocus(); snapshot = nil; table.logicalRows = []; table.reloadData()
            focusedRowID = nil; selectedRange = NSRange(location: 0, length: 0); focusedPartIndex = nil
        }
        let notRemoval = previous.map { next.messages.count >= $0.messages.count } ?? true
        if scrollState.followsResponse && (deliberate || notRemoval) {
            if deliberate || previous?.latestMessageID != next.latestMessageID || previous?.tokenBlock != next.tokenBlock { pendingFollow = true }
        }
        input = next
        loadingIndicator.isHidden = snapshot != nil; loadingLabel.isHidden = snapshot != nil
        loadingLabel.font = next.style.fonts.caption; loadingLabel.textColor = next.style.secondary
        layoutChanged()
    }
    private func layoutChanged() {
        guard let input, let scroll else { return }
        let insets = scroll.contentInsets
        let width = max(1, scroll.contentView.bounds.width - max(0, insets.left) - max(0, insets.right))
        guard width.isFinite, width > 1 else { return }
        if !widthCallbackPending && (abs(width - requestedWidth) >= 0.5 || requestedInput?.containerWidth != input.containerWidth) {
            widthCallbackPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let current = self.input else { return }
                self.widthCallbackPending = false
                guard let scroll = self.scroll else { return }
                let insets = scroll.contentInsets
                let actual = max(1, scroll.contentView.bounds.width - max(0, insets.left) - max(0, insets.right))
                self.onWidthChange?(actual, current.containerWidth)
            }
        }
        let unchanged = requestedWidth == width && requestedInput.map { equivalent($0, input) } == true
        loadingIndicator.frame = CGRect(x: 16, y: max(16, scroll.bounds.height - 40), width: 16, height: 16)
        loadingLabel.frame = CGRect(x: 38, y: max(16, scroll.bounds.height - 42), width: max(1, width - 54), height: 22)
        guard !unchanged else { requestedInput = input; return }
        requestedWidth = width; requestedInput = input
        table.frame.size.width = width
        if let column = table.tableColumns.first { column.width = width }
        engine.request(sessionID: input.sessionID, rows: input.rows, width: width, style: input.style,
                       addedURLs: input.addedURLs) { [weak self] in self?.commit($0) }
    }
    private func equivalent(_ a: AIChatNativeTranscriptInput, _ b: AIChatNativeTranscriptInput) -> Bool {
        a.sessionID == b.sessionID && a.style.equivalent(to: b.style) && a.addedURLs == b.addedURLs
            && a.rows.count == b.rows.count && zip(a.rows, b.rows).allSatisfy { $0.equivalent(to: $1) }
    }
    private func commit(_ next: AIChatNativeSnapshot) {
        guard input?.sessionID == next.sessionID, engine.generation == next.generation, let scroll else { return }
        let previous = snapshot
        clearTooltip()
        let geometryChanged = previous.map { $0.width != next.width || !$0.style.equivalent(to: next.style) } ?? false
        let anchor = geometryChanged ? (geometryAnchor ?? readingAnchor()) : readingAnchor()
        if geometryChanged { geometryAnchor = anchor }
        saveFocus()
        snapshot = next
        if pendingFollow { geometryAnchor = nil }
        loadingIndicator.isHidden = true; loadingLabel.isHidden = true
        table.logicalRows = next.rows.indices.map { AIChatAccessibilityRow(controller: self, id: next.rows[$0].id) }
        let sameIDs = previous.map { $0.rows.map(\.id) == next.rows.map(\.id) } ?? false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0; context.allowsImplicitAnimation = false
            if sameIDs, let previous {
                var changes = IndexSet()
                for i in next.rows.indices where !next.rows[i].equivalent(to: previous.rows[i]) || next.metrics[i].height != previous.metrics[i].height
                    || !next.style.equivalent(to: previous.style) || next.width != previous.width || next.addedURLs != previous.addedURLs {
                    changes.insert(i)
                }
                if !changes.isEmpty {
                    table.noteHeightOfRows(withIndexesChanged: changes)
                    table.reloadData(forRowIndexes: changes, columnIndexes: IndexSet(integer: 0))
                }
            } else { table.reloadData() }
            table.tile()
            // Las consultas públicas rellenan la geometría nativa con las alturas ya publicadas,
            // sin materializar vistas ocultas ni usar estimaciones del documento.
            for index in next.rows.indices { _ = table.rect(ofRow: index) }
            table.layoutSubtreeIfNeeded()
        }
        if pendingFollow && scrollState.followsResponse, let id = input?.latestMessageID, let index = next.index(of: .message(id)) {
            if ScrollDiagnostics.recordsChatEvents {
                ScrollDiagnostics.beforeScrollTo(pendingDeliberate ? .navigation : .tokenBlock, state: diagnosticState,
                    deliberate: pendingDeliberate ? true : nil, target: AnyHashable(AIChatNativeRowID.message(id)))
            }
            scrollToY(max(0, next.origin(of: index) + next.metrics[index].height - scroll.contentView.bounds.height))
        } else if let anchor, let index = next.index(of: anchor.rowID) {
            var offset = min(anchor.rowOffset, max(0, next.metrics[index].height - 1))
            if let character = anchor.character, let rect = next.metrics[index].primaryTextFrame {
                let content = AIChatNativeRowLayout(style: next.style, width: next.width, measurer: anchorMeasurer, addedURLs: next.addedURLs).content(for: next.rows[index])
                if let attributed = primaryAttributedText(content) {
                    offset = rect.minY + anchorMeasurer.verticalPosition(of: character, lineOffset: anchor.lineOffset, in: attributed, width: rect.width)
                }
            }
            scrollToY(next.origin(of: index) + offset)
        }
        pendingFollow = false; pendingDeliberate = false
        restoreFocus()
        boundsChanged()
        ScrollDiagnostics.observation?.attach(.chat, anchor: table)
        reportCounters()
    }
    private func scrollToY(_ y: CGFloat) {
        guard let scroll else { return }
        let maximum = max(0, table.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maximum, max(0, y))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    var diagnosticState: ScrollDiagnosticChatState {
        .init(followsResponse: scrollState.followsResponse, exploring: scrollState.isExploring,
              nearBottom: scrollState.isNearBottom, messageCount: input?.messages.count ?? 0, tokenBlock: input?.tokenBlock ?? 0)
    }
    private func boundsChanged() {
        guard let scroll else { return }
        let near = table.bounds.height - scroll.contentView.bounds.maxY < 80
        if near != scrollState.isNearBottom, ScrollDiagnostics.recordsChatEvents {
            ScrollDiagnostics.chatNearBottomChanged(from: scrollState.isNearBottom, to: near, state: diagnosticState)
        }
        scrollState.isNearBottom = near
        if ScrollDiagnostics.recordsChatEvents, let snapshot {
            let visible = table.rows(in: table.visibleRect)
            if visible.location != NSNotFound {
                for i in visible.location..<min(snapshot.rows.count, NSMaxRange(visible)) {
                    let r = table.rect(ofRow: i)
                    ScrollDiagnostics.chatRowFrame(key: AnyHashable(snapshot.rows[i].id), kind: snapshot.rows[i].diagnosticKind,
                        previous: .init(x: Double(r.minX), y: Double(r.minY), width: Double(r.width), height: Double(r.height)),
                        current: .init(x: Double(r.minX), y: Double(r.minY), width: Double(r.width), height: Double(r.height)))
                }
            }
        }
        ScrollDiagnostics.observation?.request(.chat, reason: .bounds)
    }
    func beginInteraction() {
        geometryAnchor = nil
        clearTooltip()
        if !scrollState.isExploring, ScrollDiagnostics.recordsChatEvents {
            ScrollDiagnostics.chatPhaseChanged(from: .idle, to: .interacting, state: diagnosticState)
        }
        scrollState.isExploring = true; scrollState.followsResponse = false
        idleTask?.cancel()
        idleTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            guard let self, !self.liveScrollTracking else { return }
            self.scrollState.isExploring = false
            self.scrollState.followsResponse = self.scrollState.isNearBottom
                && !(self.input?.latestMessageID.map { self.input?.expandedDecks.contains($0) == true } ?? false)
            if ScrollDiagnostics.recordsChatEvents { ScrollDiagnostics.chatPhaseChanged(from: .interacting, to: .idle, state: self.diagnosticState) }
        }
    }
    func navigate(_ key: NSEvent.SpecialKey, command: Bool = false) -> Bool {
        guard let scroll, let snapshot else { return false }
        let current = scroll.contentView.bounds.minY
        let line = ceil(snapshot.style.fonts.body.ascender - snapshot.style.fonts.body.descender + snapshot.style.fonts.body.leading)
        let target: CGFloat
        switch key {
        case .pageUp: target = current - scroll.contentView.bounds.height
        case .pageDown: target = current + scroll.contentView.bounds.height
        case .home: target = 0
        case .end: target = snapshot.height
        case .upArrow: target = command ? 0 : current - line
        case .downArrow: target = command ? snapshot.height : current + line
        default: return false
        }
        beginInteraction(); scrollToY(target); boundsChanged(); return true
    }
    func readingAnchor() -> AIChatReadingAnchor? {
        guard let snapshot, let scroll, !snapshot.rows.isEmpty else { return nil }
        let y = max(0, scroll.contentView.bounds.minY)
        let index = snapshot.index(at: y)
        let rowOffset = y - snapshot.origin(of: index)
        if let rect = snapshot.metrics[index].primaryTextFrame, rowOffset >= rect.minY {
            let c = AIChatNativeRowLayout(style: snapshot.style, width: snapshot.width, measurer: anchorMeasurer, addedURLs: snapshot.addedURLs).content(for: snapshot.rows[index])
            if let attributed = primaryAttributedText(c) {
                let anchor = anchorMeasurer.character(at: CGPoint(x: 1, y: min(max(0, rowOffset - rect.minY), max(0, rect.height - 1))), in: attributed, width: rect.width)
                return .init(rowID: snapshot.rows[index].id, character: anchor.index, lineOffset: anchor.lineOffset, rowOffset: rowOffset)
            }
        }
        return .init(rowID: snapshot.rows[index].id, character: nil, lineOffset: 0, rowOffset: max(0, rowOffset))
    }
    private func primaryAttributedText(_ c: AIChatNativeContent) -> NSAttributedString? {
        for p in c.parts { if case .text(let text, let selectable, _) = p.kind, selectable { return text } }
        return nil
    }
    func numberOfRows(in tableView: NSTableView) -> Int { snapshot?.rows.count ?? 0 }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { snapshot?.metrics[row].height ?? 1 }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard let snapshot, snapshot.rows.indices.contains(index) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("chat-content")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? AIChatNativeCell ?? AIChatNativeCell()
        cellRegistry.add(cell)
        cell.identifier = identifier
        let layout = AIChatNativeRowLayout(style: snapshot.style, width: snapshot.width, measurer: anchorMeasurer, addedURLs: snapshot.addedURLs)
        let ownerSession = snapshot.sessionID, ownerID = snapshot.rows[index].id
        cell.configure(id: snapshot.rows[index].id, content: layout.content(for: snapshot.rows[index]), style: snapshot.style,
                       command: { [weak self] command in
                           guard let self, self.input?.sessionID == ownerSession, self.snapshot?.index(of: ownerID) != nil else { return }
                           self.perform(command)
                       },
                       hover: { [weak self, weak cell] text, rect in
                           guard let self, let cell else { return }; self.hover(text, rect: rect, cell: cell)
                       })
        cell.onWillDetach = { [weak self] cell in
            guard let self, cell.window?.firstResponder.map({ cell.contains($0) }) == true else { return }
            self.saveFocus(cell)
        }
        if focusedRowID == cell.rowID, focusedPartIndex != nil, let primary = cell.primarySelectableText {
            focusedPartIndex = primary.index
            let text = primary.view, location = min(selectedRange.location, primary.view.string.utf16.count)
            text.setSelectedRange(NSRange(location: location, length: min(selectedRange.length, text.string.utf16.count - location)))
        }
        cell.setAccessibilityElement(false)
        return cell
    }
    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        for cell in rowView.subviews.compactMap({ $0 as? AIChatNativeCell }) {
            if cell.window?.firstResponder.map({ cell.contains($0) }) == true {
                saveFocus(cell); cell.window?.makeFirstResponder(table)
            }
            cell.clear()
        }
        reportCounters()
    }
    func perform(_ command: AIChatNativeCommand) {
        guard let callbacks else { return }
        switch command {
        case .copyMessage(let id): if let m = input?.messages.first(where: { $0.id == id }) { callbacks.copy(m.text) }
        case .regenerate: callbacks.regenerate()
        case .send(let value): callbacks.send(value)
        case .preview(let reference): callbacks.preview(reference)
        case .open(let reference): if URL(string: reference.url) != nil { callbacks.open(reference) }
        case .add(let references): callbacks.add(references)
        case .copyURL(let reference): callbacks.copy(reference.url)
        case .toggleReference(let id): scrollState.followsResponse = false; onToggleReference?(id)
        case .toggleDeck(let id): scrollState.followsResponse = false; onToggleDeck?(id)
        }
    }
    private func saveFocus() {
        guard let responder = table.window?.firstResponder else { return }
        for cell in visibleCells where cell.contains(responder) { saveFocus(cell); return }
    }
    private func saveFocus(_ cell: AIChatNativeCell) {
        focusedRowID = cell.rowID
        if let primary = cell.primarySelectableText, primary.view === cell.window?.firstResponder {
            selectedRange = primary.view.selectedRange(); focusedPartIndex = primary.index; focusedControlIndex = nil
        }
        else {
            focusedPartIndex = nil
            focusedControlIndex = cell.controls.firstIndex { $0 === cell.window?.firstResponder }
        }
    }
    private func restoreFocus() {
        guard let focusedRowID, let cell = visibleCells.first(where: { $0.rowID == focusedRowID }) else { return }
        if focusedPartIndex != nil, let primary = cell.primarySelectableText {
            focusedPartIndex = primary.index
            let text = primary.view
            let count = text.string.utf16.count
            let location = min(max(0, selectedRange.location), count)
            let range = NSRange(location: location, length: min(selectedRange.length, count - location))
            text.setSelectedRange(range); table.window?.makeFirstResponder(text)
        } else if let index = focusedControlIndex, cell.controls.indices.contains(index) {
            table.window?.makeFirstResponder(cell.controls[index])
        }
    }
    var visibleCells: [AIChatNativeCell] {
        let range = table.rows(in: table.visibleRect)
        guard range.location != NSNotFound else { return [] }
        return (range.location..<min(table.numberOfRows, NSMaxRange(range))).compactMap {
            table.view(atColumn: 0, row: $0, makeIfNecessary: false) as? AIChatNativeCell
        }
    }
    func materialize(_ id: AIChatNativeRowID) -> AIChatNativeCell? {
        guard let index = snapshot?.index(of: id) else { return nil }
        scrollState.followsResponse = false
        table.scrollRowToVisible(index); table.layoutSubtreeIfNeeded()
        return table.view(atColumn: 0, row: index, makeIfNecessary: true) as? AIChatNativeCell
    }
    func selection(for id: AIChatNativeRowID) -> NSRange {
        if let cell = visibleCells.first(where: { $0.rowID == id }), let primary = cell.primarySelectableText { return primary.view.selectedRange() }
        return focusedRowID == id ? selectedRange : NSRange(location: 0, length: 0)
    }
    func setSelection(_ range: NSRange, for id: AIChatNativeRowID) {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              let cell = materialize(id), let primary = cell.primarySelectableText else { return }
        let text = primary.view
        let count = text.string.utf16.count, location = min(range.location, text.string.utf16.count)
        let clamped = NSRange(location: location, length: min(range.length, count - location))
        text.setSelectedRange(clamped)
        focusedRowID = id; selectedRange = clamped; focusedPartIndex = primary.index; focusedControlIndex = nil
        table.window?.makeFirstResponder(text)
    }
    func isFocused(_ id: AIChatNativeRowID) -> Bool {
        guard let responder = table.window?.firstResponder else { return false }
        return visibleCells.contains { $0.rowID == id && $0.contains(responder) }
    }
    private func hover(_ text: String?, rect: CGRect, cell: AIChatNativeCell) {
        clearTooltip()
        guard let text, !text.isEmpty, let scroll else { return }
        let converted = cell.convert(rect, to: scroll)
        let geometry = scroll.isFlipped ? converted : CGRect(x: converted.minX, y: scroll.bounds.height - converted.maxY,
                                                              width: converted.width, height: converted.height)
        let expected = tooltipGeneration
        tooltipTask = Task { @MainActor [weak self, weak cell] in
            do { try await Task.sleep(for: .milliseconds(480)) } catch { return }
            guard let self, cell?.rowID != nil, self.tooltipGeneration == expected else { return }
            self.onTooltipChange?(.init(text: text, rect: geometry))
        }
    }
    private func clearTooltip() {
        tooltipGeneration &+= 1; tooltipTask?.cancel(); tooltipTask = nil
        DispatchQueue.main.async { [weak self] in self?.onTooltipChange?(nil) }
    }
    func counters() -> AIChatNativeMemoryCounters {
        let cells = cellRegistry.allObjects.filter { $0.rowID != nil }
        return .init(generation: engine.generation, logicalRows: snapshot?.rows.count ?? 0, metricEntries: engine.cacheEntries,
                     liveCells: cells.count, liveTextSystems: cells.reduce(0) { $0 + $1.textViews.count }, measurementCount: engine.measurements,
                     cacheHits: engine.cacheHits, cancelledGenerations: engine.cancelledGenerations,
                     retainedMeasurementUTF16: engine.retainedMeasurementUTF16, maximumMeasurementUTF16: engine.maximumMeasurementUTF16,
                     presentedUTF16: cells.reduce(0) { count, cell in count + cell.textViews.reduce(0) { $0 + $1.string.utf16.count } })
    }
    private func reportCounters() {
        guard Self.diagnosticsEnabled, reports < 128, ProcessInfo.processInfo.systemUptime - diagnosticsStarted < 120 else { return }
        reports += 1
        if let data = try? JSONEncoder().encode(counters()), let value = String(data: data, encoding: .utf8) {
            Self.logger.info("Representación del chat: \(value, privacy: .public)")
        }
    }
    func invalidate() {
        clearTooltip(); engine.invalidate(); idleTask?.cancel(); idleTask = nil
        loadingIndicator.stopAnimation(nil); loadingIndicator.removeFromSuperview(); loadingLabel.removeFromSuperview()
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }; boundsObserver = nil
        for observer in liveScrollObservers { NotificationCenter.default.removeObserver(observer) }; liveScrollObservers.removeAll()
        liveScrollTracking = false
        ScrollDiagnostics.observation?.detach(.chat, anchor: table)
        for cell in cellRegistry.allObjects { cell.clear() }; cellRegistry.removeAllObjects()
        table.logicalRows = []; snapshot = nil; input = nil; requestedInput = nil; geometryAnchor = nil
        callbacks = nil; onWidthChange = nil; onToggleReference = nil; onToggleDeck = nil; onTooltipChange = nil
        table.delegate = nil; table.dataSource = nil; table.controller = nil
        scroll?.onLayout = nil; scroll?.onInteraction = nil
    }
}
