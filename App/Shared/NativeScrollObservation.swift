import Foundation
import AppKit

enum ScrollObservationStatusCode: String, Codable, Sendable { case unresolvedAnchor, surfaceExhausted, stopped }
struct ScrollObservationStatusRecord: Codable, Sendable {
    var surface: ScrollSurface?
    var code: ScrollObservationStatusCode
    var stop: ScrollObservationStop?
}
struct ScrollObservationRecord: Codable, Sendable {
    var sample: NativeScrollGeometrySample
    var changes: [ScrollGeometryDelta]
}

/// Geometría opt-in y acotada; nunca lee el contenido del documento.
@MainActor final class NativeScrollObservation {
    typealias Sink = @MainActor (ScrollObservationRecord) -> Void
    typealias Status = @MainActor (ScrollObservationStatusRecord) -> Void
    private var budget: ScrollObservationBudget
    private let sink: Sink
    private let status: Status
    private let capturesSidebarTable: Bool
    private let started = ProcessInfo.processInfo.systemUptime
    private var bindings: [ScrollSurface: ScrollObservationBinding] = [:]
    private var previous: [ScrollSurface: NativeScrollGeometrySample] = [:]
    private var nextOrdinal = 1
    private var flushTask: Task<Void, Never>?
    private var scheduledFor: TimeInterval?
    private var deadlineTask: Task<Void, Never>?

    static func make(environment: [String: String], makeSink: @MainActor () -> Sink,
                     status: @escaping Status) -> NativeScrollObservation? {
        ScrollObservationConfiguration.activate(environment: environment) { configuration in
            NativeScrollObservation(configuration: configuration, sink: makeSink(), status: status,
                capturesSidebarTable: environment["STACKLUME_SCROLL_TABLE_DIAGNOSTICS"] == "1")
        }
    }
    private init(configuration: ScrollObservationConfiguration, sink: @escaping Sink, status: @escaping Status,
                 capturesSidebarTable: Bool) {
        budget = ScrollObservationBudget(configuration: configuration)
        self.sink = sink
        self.status = status
        self.capturesSidebarTable = capturesSidebarTable
        deadlineTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(configuration.duration)) } catch { return }
            self?.invalidate(.deadline)
        }
    }
    deinit { flushTask?.cancel(); deadlineTask?.cancel() }
    private var elapsed: TimeInterval { ProcessInfo.processInfo.systemUptime - started }
    func observes(_ surface: ScrollSurface) -> Bool { budget.stopped == nil && budget.configuration.surfaces.contains(surface) }

    @discardableResult func attach(_ surface: ScrollSurface, anchor: NSView) -> Bool {
        guard budget.permitBinding(surface, at: elapsed) else {
            if let stopped = budget.stopped { invalidate(stopped) }
            return false
        }
        guard anchor.window != nil, let scroll = anchor.enclosingScrollView,
              let document = scroll.documentView else {
            status(ScrollObservationStatusRecord(surface: surface, code: .unresolvedAnchor)); return false
        }
        // No recorrer subviews ni buscar otra ventana. La pertenencia es obligatoria.
        var cursor: NSView? = anchor
        var containsDocument = false
        for _ in 0..<32 {
            guard let view = cursor else { break }
            if view === document { containsDocument = true; break }
            cursor = view.superview
        }
        guard containsDocument else { status(ScrollObservationStatusRecord(surface: surface, code: .unresolvedAnchor)); return false }
        if let old = bindings[surface], old.scroll === scroll {
            old.anchor = anchor
            request(surface, reason: .attached)
            return true
        }
        detach(surface)
        guard budget.attach(surface) else {
            status(ScrollObservationStatusRecord(surface: surface, code: .surfaceExhausted)); return false
        }
        let binding = ScrollObservationBinding(owner: self, surface: surface, ordinal: nextOrdinal, scroll: scroll, anchor: anchor)
        nextOrdinal += 1
        bindings[surface] = binding
        binding.refreshObservers()
        request(surface, reason: .attached)
        return true
    }
    func detach(_ surface: ScrollSurface, anchor: NSView? = nil) {
        if let anchor, bindings[surface]?.anchor !== anchor { return }
        bindings.removeValue(forKey: surface)?.invalidate()
        budget.detach(surface)
        previous.removeValue(forKey: surface)
        reschedule()
    }
    func request(_ surface: ScrollSurface, reason: ScrollObservationReason) {
        budget.request(surface, at: elapsed, reason: reason)
        if let stopped = budget.stopped { invalidate(stopped); return }
        reschedule()
    }
    private func reschedule() {
        guard budget.stopped == nil, let due = budget.nextDue else {
            flushTask?.cancel(); flushTask = nil; scheduledFor = nil
            return
        }
        if let scheduledFor, scheduledFor <= due { return }
        flushTask?.cancel()
        scheduledFor = due
        let delay = max(0, due - elapsed)
        flushTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.flushTask = nil
            self.scheduledFor = nil
            self.flush()
        }
    }
    private func flush() {
        let now = elapsed
        let admitted = budget.drain(at: now)
        for item in admitted {
            guard let binding = bindings[item.surface], let scroll = binding.scroll, scroll.window != nil else {
                detach(item.surface); continue
            }
            let before = ProcessInfo.processInfo.systemUptime
            binding.refreshObservers()
            var sample = capture(scroll: scroll, surface: item.surface, ordinal: binding.ordinal, reasons: item.reasons, at: now)
            sample.collectionMilliseconds = (ProcessInfo.processInfo.systemUptime - before) * 1_000
            guard sample.finite else { invalidate(.invalidGeometry); return }
            let changes = previous[item.surface].map { ScrollGeometryDelta.between($0, sample) } ?? []
            previous[item.surface] = sample
            sink(ScrollObservationRecord(sample: sample, changes: changes))
        }
        if let stopped = budget.stopped { invalidate(stopped); return }
        for surface in ScrollSurface.allCases where !budget.isAttached(surface) {
            bindings.removeValue(forKey: surface)?.invalidate()
            previous.removeValue(forKey: surface)
        }
        reschedule()
    }
    func invalidate(_ reason: ScrollObservationStop = .invalidated) {
        let wasActive = !bindings.isEmpty || deadlineTask != nil
        budget.stop(reason)
        flushTask?.cancel(); flushTask = nil; scheduledFor = nil
        deadlineTask?.cancel(); deadlineTask = nil
        for binding in bindings.values { binding.invalidate() }
        bindings.removeAll()
        previous.removeAll()
        if wasActive { status(ScrollObservationStatusRecord(code: .stopped, stop: budget.stopped)) }
    }
    private func capture(scroll: NSScrollView, surface: ScrollSurface, ordinal: Int,
                         reasons: [ScrollObservationReason], at time: TimeInterval) -> NativeScrollGeometrySample {
        let axes: [(ScrollAxisGeometry.Axis, NSScroller?)] = [(.vertical, scroll.verticalScroller), (.horizontal, scroll.horizontalScroller)]
        let inspectTable = capturesSidebarTable && surface == .sidebar
        let table = inspectTable ? (scroll.documentView as? NSTableView).map(tableGeometry) : nil
        return NativeScrollGeometrySample(elapsed: time, collectionMilliseconds: 0, surface: surface, bindingOrdinal: ordinal, reasons: reasons,
            scroll: geometry(scroll), clip: geometry(scroll.contentView), document: scroll.documentView.map(geometry),
            documentVisible: rect(scroll.documentVisibleRect), contentInsets: insets(scroll.contentInsets), scrollerInsets: insets(scroll.scrollerInsets),
            axes: axes.compactMap { axis, scroller in
                guard let scroller else { return nil }
                let knob = scroller.rect(for: .knob)
                var chain: [ScrollAncestorGeometry] = []
                var cursor = scroller.superview
                for depth in 0..<budget.configuration.maximumAncestors {
                    guard let view = cursor else { break }
                    let kind: ScrollAncestorGeometry.Kind = view is NSScrollView ? .scroll : view is NSClipView ? .clip : view is NSScroller ? .scroller : .view
                    chain.append(ScrollAncestorGeometry(depth: depth, kind: kind, geometry: geometry(view),
                                                       knobInAncestor: rect(view.convert(knob, from: scroller))))
                    cursor = view.superview
                }
                return ScrollAxisGeometry(axis: axis, geometry: geometry(scroller), hidden: scroller.isHidden,
                    value: scroller.doubleValue, knobProportion: Double(scroller.knobProportion), knob: rect(knob), knobSlot: rect(scroller.rect(for: .knobSlot)),
                    style: scroller.scrollerStyle.rawValue, controlSize: Int(scroller.controlSize.rawValue), ancestors: chain, ancestorsTruncated: cursor != nil)
            }, documentClass: inspectTable ? scroll.documentView.map { String(describing: type(of: $0)) } : nil,
            table: table)
    }
    private func tableGeometry(_ table: NSTableView) -> ScrollTableGeometry {
        let before = table.bounds.height
        let count = table.numberOfRows
        let indexes = ScrollTableGeometry.sampledRowIndexes(count: count)
        // Consultar rectOfRow puede resolver alturas estimadas; registrar también su efecto inmediato.
        let rows = indexes.map {
            ScrollTableRowGeometry(index: $0, rect: rect(table.rect(ofRow: $0)),
                rowViewHeight: table.rowView(atRow: $0, makeIfNecessary: false).map { Double($0.bounds.height) })
        }
        return ScrollTableGeometry(numberOfRows: count, usesAutomaticRowHeights: table.usesAutomaticRowHeights,
            rowHeight: table.rowHeight, intercellSpacingHeight: table.intercellSpacing.height,
            rowSizeStyle: table.rowSizeStyle.rawValue, documentHeightBeforeRows: before,
            documentHeightAfterRows: table.bounds.height, rows: rows, rowsTruncated: count > indexes.count)
    }
    private func rect(_ r: NSRect) -> ScrollRect { ScrollRect(x: r.origin.x, y: r.origin.y, width: r.width, height: r.height) }
    private func insets(_ i: NSEdgeInsets) -> ScrollInsets { ScrollInsets(top: i.top, left: i.left, bottom: i.bottom, right: i.right) }
    private func geometry(_ view: NSView) -> ScrollViewGeometry {
        ScrollViewGeometry(frame: rect(view.frame), bounds: rect(view.bounds), visible: rect(view.visibleRect), flipped: view.isFlipped,
                           clipsToBounds: view.clipsToBounds, postsFrame: view.postsFrameChangedNotifications, postsBounds: view.postsBoundsChangedNotifications)
    }
}

@MainActor private final class ScrollObservationBinding: NSObject {
    weak var owner: NativeScrollObservation?
    weak var scroll: NSScrollView?
    weak var anchor: NSView?
    private weak var document: NSView?
    private weak var clip: NSClipView?
    private weak var window: NSWindow?
    private weak var vertical: NSScroller?
    private weak var horizontal: NSScroller?
    let surface: ScrollSurface
    let ordinal: Int
    init(owner: NativeScrollObservation, surface: ScrollSurface, ordinal: Int, scroll: NSScrollView, anchor: NSView) {
        self.owner = owner; self.surface = surface; self.ordinal = ordinal; self.scroll = scroll; self.anchor = anchor
    }
    func refreshObservers() {
        guard let scroll else { return }
        if clip === scroll.contentView, document === scroll.documentView, window === scroll.window,
           vertical === scroll.verticalScroller, horizontal === scroll.horizontalScroller { return }
        invalidate()
        clip = scroll.contentView; document = scroll.documentView; window = scroll.window
        vertical = scroll.verticalScroller; horizontal = scroll.horizontalScroller
        let center = NotificationCenter.default
        for view in [scroll as NSView, clip, document, vertical, horizontal].compactMap({ $0 }) {
            center.addObserver(self, selector: #selector(changed), name: NSView.frameDidChangeNotification, object: view)
            center.addObserver(self, selector: #selector(changed), name: NSView.boundsDidChangeNotification, object: view)
        }
        for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
            center.addObserver(self, selector: #selector(changed), name: name, object: scroll)
        }
        if let window {
            center.addObserver(self, selector: #selector(changed), name: NSWindow.didEndLiveResizeNotification, object: window)
            center.addObserver(self, selector: #selector(windowClosed), name: NSWindow.willCloseNotification, object: window)
        }
    }
    @objc private func changed(_ notification: Notification) {
        let reason: ScrollObservationReason
        switch notification.name {
        case NSView.frameDidChangeNotification: reason = .frame
        case NSView.boundsDidChangeNotification: reason = .bounds
        case NSScrollView.willStartLiveScrollNotification: reason = .liveStart
        case NSScrollView.didLiveScrollNotification: reason = .liveScroll
        case NSScrollView.didEndLiveScrollNotification: reason = .liveEnd
        default: reason = .resizeEnd
        }
        owner?.request(surface, reason: reason)
    }
    @objc private func windowClosed(_ notification: Notification) { owner?.detach(surface) }
    func invalidate() { NotificationCenter.default.removeObserver(self) }
    deinit { NotificationCenter.default.removeObserver(self) }
}
