import Foundation
import OSLog
import Darwin

/// Observación geométrica opt-in, sin contenido de la biblioteca ni preferencias persistentes.
@MainActor
enum ScrollDiagnostics {
    private(set) static var observation: NativeScrollObservation?
    private static var writer: ScrollDiagnosticWriter?
    private static var configured = false
    private static let logger = Logger(subsystem: "com.swondev.stacklume", category: "ScrollDiagnostics")

    static func configure(environment: [String: String]) {
        guard !configured else { return }
        configured = true
        guard ScrollObservationConfiguration.activate(environment: environment, make: { _ in true }) == true else { return }
        guard let path = environment["STACKLUME_SCROLL_OUTPUT"], path.hasPrefix("/"),
              let writer = ScrollDiagnosticWriter(path: path) else {
            logger.error("No se pudo iniciar la observación geométrica de QA.")
            return
        }
        self.writer = writer
        observation = NativeScrollObservation.make(environment: environment,
            makeSink: { { record in writer.appendGeometry(record) } },
            status: { status in writer.appendStatus(status) })
    }

    static var recordsChatEvents: Bool {
        guard let writer, let observation, observation.observes(.chat) else { return false }
        return writer.acceptsChatEvents
    }

    static func beforeScrollTo(_ reason: ScrollDiagnosticScrollToReason, state: ScrollDiagnosticChatState,
                               deliberate: Bool?, target: AnyHashable? = nil) {
        guard recordsChatEvents else { return }
        writer?.appendEvent(.beforeScrollTo, state: state, reason: reason, deliberate: deliberate,
                            targetRowOrdinal: target.flatMap { writer?.ordinal(for: $0) })
    }

    static func chatPhaseChanged(from previous: ScrollDiagnosticChatPhase, to current: ScrollDiagnosticChatPhase,
                                 state: ScrollDiagnosticChatState) {
        guard recordsChatEvents else { return }
        writer?.phase = current
        writer?.appendEvent(.phaseChanged, state: state, previousPhase: previous)
    }

    static func chatNearBottomChanged(from previous: Bool, to current: Bool, state: ScrollDiagnosticChatState) {
        guard recordsChatEvents else { return }
        writer?.appendEvent(.nearBottomChanged, state: state, previousNearBottom: previous, currentNearBottom: current)
    }

    static func chatViewportCallback(width: Double, previousWidth: Double, containerWidth: Double,
                                     previousContainerWidth: Double, state: ScrollDiagnosticChatState) {
        guard recordsChatEvents, width.isFinite, previousWidth.isFinite,
              containerWidth.isFinite, previousContainerWidth.isFinite else { return }
        writer?.appendEvent(.viewportCallback, state: state, width: width, previousWidth: previousWidth,
                            containerWidth: containerWidth, previousContainerWidth: previousContainerWidth)
    }

    static func chatRowFrame(key: AnyHashable, kind: ScrollDiagnosticRowKind,
                             previous: ScrollRect, current: ScrollRect) {
        guard recordsChatEvents, previous.finite, current.finite,
              let ordinal = writer?.ordinal(for: key) else { return }
        writer?.appendRow(ordinal: ordinal, kind: kind, previous: previous, current: current)
    }
}

enum ScrollDiagnosticScrollToReason: String, Codable, Sendable { case navigation, tokenBlock }
enum ScrollDiagnosticChatPhase: String, Codable, Sendable { case idle, tracking, interacting, decelerating, animating, unknown }
enum ScrollDiagnosticChatEvent: String, Codable, Sendable { case beforeScrollTo, phaseChanged, nearBottomChanged, viewportCallback }
enum ScrollDiagnosticRowKind: String, Codable, Sendable { case message, header, reference, footer, actions, progress }

struct ScrollDiagnosticChatState: Codable, Sendable {
    var followsResponse: Bool
    var exploring: Bool
    var nearBottom: Bool
    var messageCount: Int
    var tokenBlock: Int
}

private enum ScrollDiagnosticRecordKind: String, Codable { case geometry, status, chatEvent, rowGeometry }
private struct ScrollDiagnosticRowRecord: Encodable {
    let kind = ScrollDiagnosticRecordKind.rowGeometry
    let surface = ScrollSurface.chat
    var uptime: TimeInterval
    var diagnosticElapsed: TimeInterval
    var rowOrdinal: Int
    var rowKind: ScrollDiagnosticRowKind
    var previous: ScrollRect
    var current: ScrollRect
}
private struct ScrollDiagnosticGeometryRecord: Encodable {
    let kind = ScrollDiagnosticRecordKind.geometry
    var uptime: TimeInterval
    var diagnosticElapsed: TimeInterval
    var sample: NativeScrollGeometrySample
    var changes: [ScrollGeometryDelta]
}
private struct ScrollDiagnosticStatusRecord: Encodable {
    let kind = ScrollDiagnosticRecordKind.status
    var uptime: TimeInterval
    var diagnosticElapsed: TimeInterval
    var surface: ScrollSurface?
    var code: ScrollObservationStatusCode
    var stop: ScrollObservationStop?
}
private struct ScrollDiagnosticChatRecord: Encodable {
    let kind = ScrollDiagnosticRecordKind.chatEvent
    let surface = ScrollSurface.chat
    var uptime: TimeInterval
    var diagnosticElapsed: TimeInterval
    var event: ScrollDiagnosticChatEvent
    var state: ScrollDiagnosticChatState
    var phase: ScrollDiagnosticChatPhase
    var reason: ScrollDiagnosticScrollToReason?
    var deliberate: Bool?
    var targetMessageOrdinal: Int?
    var targetRowOrdinal: Int?
    var previousPhase: ScrollDiagnosticChatPhase?
    var previousNearBottom: Bool?
    var currentNearBottom: Bool?
    var width: Double?
    var previousWidth: Double?
    var containerWidth: Double?
    var previousContainerWidth: Double?
}

@MainActor
private final class ScrollDiagnosticWriter {
    private let handle: FileHandle
    private let started = ProcessInfo.processInfo.systemUptime
    private var stopped = false
    private var rowOrdinals: [AnyHashable: Int] = [:]
    var phase = ScrollDiagnosticChatPhase.unknown
    private var count = 0
    private var statuses = Set<String>()
    private let encoder = JSONEncoder()
    private static let logger = Logger(subsystem: "com.swondev.stacklume", category: "ScrollDiagnostics")

    init?(path: String) {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    var acceptsChatEvents: Bool {
        acceptsRecords(at: ProcessInfo.processInfo.systemUptime)
    }

    private func acceptsRecords(at time: TimeInterval) -> Bool {
        !stopped && count < 512 && time - started < 120
    }

    func ordinal(for key: AnyHashable) -> Int? {
        guard acceptsChatEvents else { return nil }
        if let ordinal = rowOrdinals[key] { return ordinal }
        guard rowOrdinals.count < 128 else { return nil }
        let ordinal = rowOrdinals.count
        rowOrdinals[key] = ordinal
        return ordinal
    }

    func appendRow(ordinal: Int, kind: ScrollDiagnosticRowKind, previous: ScrollRect, current: ScrollRect) {
        let now = ProcessInfo.processInfo.systemUptime
        guard acceptsRecords(at: now) else { return }
        append(ScrollDiagnosticRowRecord(uptime: now, diagnosticElapsed: now - started,
                                         rowOrdinal: ordinal, rowKind: kind, previous: previous, current: current))
    }

    func appendGeometry(_ record: ScrollObservationRecord) {
        let now = ProcessInfo.processInfo.systemUptime
        guard acceptsRecords(at: now) else { return }
        append(ScrollDiagnosticGeometryRecord(uptime: now, diagnosticElapsed: now - started,
                                              sample: record.sample, changes: record.changes))
    }

    func appendEvent(_ event: ScrollDiagnosticChatEvent, state: ScrollDiagnosticChatState,
                     reason: ScrollDiagnosticScrollToReason? = nil, deliberate: Bool? = nil,
                     targetRowOrdinal: Int? = nil,
                     previousPhase: ScrollDiagnosticChatPhase? = nil, previousNearBottom: Bool? = nil,
                     currentNearBottom: Bool? = nil, width: Double? = nil, previousWidth: Double? = nil,
                     containerWidth: Double? = nil, previousContainerWidth: Double? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        guard acceptsRecords(at: now), state.messageCount >= 0, state.tokenBlock >= 0 else { return }
        append(ScrollDiagnosticChatRecord(uptime: now, diagnosticElapsed: now - started,
            event: event, state: state, phase: phase, reason: reason, deliberate: deliberate,
            targetMessageOrdinal: event == .beforeScrollTo && state.messageCount > 0 ? state.messageCount - 1 : nil,
            targetRowOrdinal: targetRowOrdinal,
            previousPhase: previousPhase, previousNearBottom: previousNearBottom, currentNearBottom: currentNearBottom,
            width: width, previousWidth: previousWidth, containerWidth: containerWidth,
            previousContainerWidth: previousContainerWidth))
    }

    func appendStatus(_ record: ScrollObservationStatusRecord) {
        if record.code == .stopped { stopped = true; rowOrdinals.removeAll() }
        let key = (record.surface?.rawValue ?? "session") + ":" + record.code.rawValue
        guard statuses.insert(key).inserted else { return }
        let now = ProcessInfo.processInfo.systemUptime
        append(ScrollDiagnosticStatusRecord(uptime: now, diagnosticElapsed: now - started,
                                            surface: record.surface, code: record.code, stop: record.stop))
    }

    func append<T: Encodable>(_ record: T) {
        guard count < 512 else { return }
        count += 1
        do {
            var data = try encoder.encode(record)
            data.append(0x0a)
            try handle.write(contentsOf: data)
        } catch {
            count = 512
            Self.logger.error("No se pudo guardar la observación geométrica de QA.")
        }
    }
}
