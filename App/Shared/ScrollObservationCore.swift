import Foundation

public enum ScrollSurface: String, CaseIterable, Codable, Sendable { case sidebar, library, chat }
public enum ScrollObservationReason: String, Codable, Sendable, Hashable {
    case attached, frame, bounds, liveStart, liveScroll, liveEnd, contentChanged, resizeEnd
}
public enum ScrollObservationStop: String, Codable, Sendable {
    case deadline, sampleLimit, callbackLimit, invalidGeometry, invalidated
}

public struct ScrollObservationConfiguration: Sendable {
    public let surfaces: Set<ScrollSurface>
    public let interval: TimeInterval = 0.1
    public let duration: TimeInterval = 120
    public let maximumSamples = 512
    public let maximumSamplesPerSurface = 192
    public let maximumCallbacks = 5_000
    public let maximumAncestors = 16

    public static func activate<T>(environment: [String: String], make: (Self) -> T) -> T? {
        guard environment["STACKLUME_SCROLL_OBSERVATION"] == "1" else { return nil }
        let surfaces: Set<ScrollSurface>
        if let raw = environment["STACKLUME_SCROLL_SURFACES"] {
            let names = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let parsed = names.compactMap(ScrollSurface.init(rawValue:))
            guard !names.isEmpty, parsed.count == names.count, Set(parsed).count == names.count else { return nil }
            surfaces = Set(parsed)
        } else { surfaces = Set(ScrollSurface.allCases) }
        return make(Self(surfaces: surfaces))
    }
}

/// La puerta consume presupuesto antes de que el adapter lea una vista.
public struct ScrollObservationBudget: Sendable {
    private struct Slot: Sendable {
        var attached = false
        var samples = 0
        var lastSample: TimeInterval?
        var pending: Set<ScrollObservationReason> = []
        var due: TimeInterval?
    }
    public let configuration: ScrollObservationConfiguration
    public private(set) var stopped: ScrollObservationStop?
    public private(set) var callbackCount = 0
    public private(set) var sampleCount = 0
    private var slots: [ScrollSurface: Slot] = [:]

    public init(configuration: ScrollObservationConfiguration) { self.configuration = configuration }

    @discardableResult public mutating func attach(_ surface: ScrollSurface) -> Bool {
        guard stopped == nil, configuration.surfaces.contains(surface) else { return false }
        var slot = slots[surface] ?? Slot()
        guard slot.samples < configuration.maximumSamplesPerSurface else { return false }
        slot.attached = true
        slots[surface] = slot
        return true
    }
    public mutating func detach(_ surface: ScrollSurface) {
        guard var slot = slots[surface] else { return }
        slot.attached = false
        slot.pending = []
        slot.due = nil
        slots[surface] = slot
    }
    public func isAttached(_ surface: ScrollSurface) -> Bool { slots[surface]?.attached == true }

    public mutating func permitBinding(_ surface: ScrollSurface, at time: TimeInterval) -> Bool {
        acceptCallback(surface, at: time)
    }
    private mutating func acceptCallback(_ surface: ScrollSurface, at time: TimeInterval) -> Bool {
        guard stopped == nil, configuration.surfaces.contains(surface) else { return false }
        guard time.isFinite, time >= 0 else { stop(.invalidGeometry); return false }
        guard time < configuration.duration else { stop(.deadline); return false }
        guard callbackCount < configuration.maximumCallbacks else { stop(.callbackLimit); return false }
        callbackCount += 1
        return true
    }
    public mutating func request(_ surface: ScrollSurface, at time: TimeInterval, reason: ScrollObservationReason) {
        guard var slot = slots[surface], slot.attached else { return }
        guard acceptCallback(surface, at: time) else { return }
        slot.pending.insert(reason)
        if slot.due == nil { slot.due = max(time, (slot.lastSample ?? -configuration.interval) + configuration.interval) }
        slots[surface] = slot
    }
    public var nextDue: TimeInterval? { slots.values.compactMap(\.due).min() }

    public mutating func drain(at time: TimeInterval) -> [(surface: ScrollSurface, reasons: [ScrollObservationReason])] {
        guard stopped == nil else { return [] }
        guard time.isFinite, time >= 0 else { stop(.invalidGeometry); return [] }
        guard time < configuration.duration else { stop(.deadline); return [] }
        var result: [(ScrollSurface, [ScrollObservationReason])] = []
        for surface in ScrollSurface.allCases {
            guard var slot = slots[surface], slot.attached, let due = slot.due, due <= time else { continue }
            guard sampleCount < configuration.maximumSamples else { stop(.sampleLimit); break }
            result.append((surface, slot.pending.sorted { $0.rawValue < $1.rawValue }))
            slot.pending = []
            slot.due = nil
            slot.samples += 1
            sampleCount += 1
            slot.lastSample = time
            if slot.samples == configuration.maximumSamplesPerSurface { slot.attached = false }
            slots[surface] = slot
        }
        if sampleCount == configuration.maximumSamples { stop(.sampleLimit) }
        return result
    }
    public mutating func stop(_ reason: ScrollObservationStop) {
        guard stopped == nil else { return }
        stopped = reason
        for surface in ScrollSurface.allCases { detach(surface) }
    }
}

public struct ScrollRect: Codable, Sendable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double = 0, y: Double = 0, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var finite: Bool { [x, y, width, height].allSatisfy(\.isFinite) }
}
public struct ScrollInsets: Codable, Sendable, Equatable {
    public var top: Double, left: Double, bottom: Double, right: Double
    public init(top: Double = 0, left: Double = 0, bottom: Double = 0, right: Double = 0) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }
    public var finite: Bool { [top, left, bottom, right].allSatisfy(\.isFinite) }
}
public struct ScrollViewGeometry: Codable, Sendable, Equatable {
    public var frame, bounds, visible: ScrollRect
    public var flipped, clipsToBounds, postsFrame, postsBounds: Bool
    public var finite: Bool { frame.finite && bounds.finite && visible.finite }
}
public struct ScrollAncestorGeometry: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case view, clip, scroll, scroller }
    public var depth: Int
    public var kind: Kind
    public var geometry: ScrollViewGeometry
    public var knobInAncestor: ScrollRect
    public var finite: Bool { geometry.finite && knobInAncestor.finite }
}
public struct ScrollAxisGeometry: Codable, Sendable, Equatable {
    public enum Axis: String, Codable, Sendable { case vertical, horizontal }
    public var axis: Axis
    public var geometry: ScrollViewGeometry
    public var hidden: Bool
    public var value, knobProportion: Double
    public var knob, knobSlot: ScrollRect
    public var style, controlSize: Int
    public var ancestors: [ScrollAncestorGeometry]
    public var ancestorsTruncated: Bool
    public var finite: Bool {
        geometry.finite && value.isFinite && knobProportion.isFinite && knob.finite && knobSlot.finite
            && ancestors.allSatisfy(\.finite)
    }
}
public struct ScrollTableRowGeometry: Codable, Sendable, Equatable {
    public var index: Int
    public var rect: ScrollRect
    public var rowViewHeight: Double? = nil
}
public struct ScrollTableGeometry: Codable, Sendable, Equatable {
    public var numberOfRows: Int
    public var usesAutomaticRowHeights: Bool
    public var rowHeight, intercellSpacingHeight: Double
    public var rowSizeStyle: Int
    public var documentHeightBeforeRows, documentHeightAfterRows: Double
    public var rows: [ScrollTableRowGeometry]
    public var rowsTruncated: Bool
    public var finite: Bool {
        numberOfRows >= 0 && rows.count <= 32
            && [rowHeight, intercellSpacingHeight, documentHeightBeforeRows, documentHeightAfterRows].allSatisfy(\.isFinite)
            && rows.allSatisfy { $0.index >= 0 && $0.index < numberOfRows && $0.rect.finite && ($0.rowViewHeight?.isFinite ?? true) }
    }
    public static func sampledRowIndexes(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        if count <= 32 { return Array(0..<count) }
        return Array(0..<16) + Array((count - 16)..<count)
    }
}
public struct NativeScrollGeometrySample: Codable, Sendable, Equatable {
    public var elapsed: TimeInterval
    public var collectionMilliseconds: Double
    public var surface: ScrollSurface
    public var bindingOrdinal: Int
    public var reasons: [ScrollObservationReason]
    public var scroll, clip: ScrollViewGeometry
    public var document: ScrollViewGeometry?
    public var documentVisible: ScrollRect
    public var contentInsets, scrollerInsets: ScrollInsets
    public var axes: [ScrollAxisGeometry]
    public var documentClass: String? = nil
    public var table: ScrollTableGeometry? = nil
    public var finite: Bool {
        elapsed.isFinite && collectionMilliseconds.isFinite && scroll.finite && clip.finite
            && (document?.finite ?? true) && documentVisible.finite && contentInsets.finite && scrollerInsets.finite
            && axes.allSatisfy(\.finite) && (table?.finite ?? true)
    }
}

/// No juzga si hay defecto: conserva las dimensiones que cambiaron junto al pulgar.
public enum ScrollGeometryDelta: String, Codable, Sendable {
    case bindingChanged, documentExtentChanged, viewportChanged, knobChanged, scrollerVisibilityChanged
    public static func between(_ previous: NativeScrollGeometrySample, _ next: NativeScrollGeometrySample) -> [Self] {
        if previous.bindingOrdinal != next.bindingOrdinal { return [.bindingChanged] }
        var result: [Self] = []
        if previous.document?.frame.width != next.document?.frame.width || previous.document?.frame.height != next.document?.frame.height
            || previous.document?.bounds.width != next.document?.bounds.width || previous.document?.bounds.height != next.document?.bounds.height {
            result.append(.documentExtentChanged)
        }
        if previous.clip.bounds.width != next.clip.bounds.width || previous.clip.bounds.height != next.clip.bounds.height
            || previous.scroll.frame.width != next.scroll.frame.width || previous.scroll.frame.height != next.scroll.frame.height
            || previous.contentInsets != next.contentInsets || previous.scrollerInsets != next.scrollerInsets {
            result.append(.viewportChanged)
        }
        for axis in ScrollAxisGeometry.Axis.all {
            let a = previous.axes.first { $0.axis == axis }, b = next.axes.first { $0.axis == axis }
            if a?.hidden != b?.hidden { result.append(.scrollerVisibilityChanged) }
            guard let a, let b, !a.hidden, !b.hidden else { continue }
            if a.knobProportion != b.knobProportion || a.knob != b.knob { result.append(.knobChanged) }
        }
        return Array(Set(result.map(\.rawValue))).sorted().compactMap(Self.init(rawValue:))
    }
}
private extension ScrollAxisGeometry.Axis { static var all: [Self] { [.vertical, .horizontal] } }
