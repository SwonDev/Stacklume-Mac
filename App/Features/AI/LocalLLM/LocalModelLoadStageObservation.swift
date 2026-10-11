import Foundation
import Darwin

struct LocalModelLoadStageObservation: Codable, Equatable, Sendable {
    let loadID: UUID
    let sequence: Int
    let stage: String
    let groupIndex: Int?
    let groupCount: Int?
}

/// Se construye únicamente con el directorio validado del ticket canónico.
/// El lock protege bytes y eventos; el callback conserva solo metadata Foundation.
final class LocalModelLoadStageWriter: @unchecked Sendable {
    enum WriterError: Error { case ownership, invalidEvent, budget }
    struct Event: Codable, Sendable {
        let observation: LocalModelLoadStageObservation
        let elapsedNanoseconds: UInt64
    }
    struct Record: Codable, Sendable {
        let version: Int
        let pid: Int32
        let runID: String
        let events: [Event]
        let omittedEvents: Int
    }
    private static let stages: Set<String> = [
        "load-started", "load-returned", "config-started", "config-ready", "architecture-ready",
        "tokenizer-started", "tokenizer-ready", "weights-selecting", "weights-ready",
        "group-started", "group-ready", "sanitize-started", "sanitized", "quantization-started",
        "quantized", "verification-started", "verified", "materialization-started", "materialization-ready"
    ]
    private let lock = NSLock()
    private let destination: URL
    private let pid: Int32
    private let runID: String
    private let started = DispatchTime.now().uptimeNanoseconds
    private var events: [Event] = []
    private var loadID: UUID?
    private var acceptedEvents = 0
    private var failures = 0
    private var rejected = 0
    private var lastData: Data

    init(directory: URL, pid: Int32, runID: String) throws {
        guard directory.isFileURL, pid == ProcessInfo.processInfo.processIdentifier,
              UUID(uuidString: runID)?.uuidString == runID else { throw WriterError.ownership }
        var attributes = stat()
        guard lstat(directory.path, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFDIR,
              attributes.st_uid == getuid(), attributes.st_mode & 0o777 == 0o700,
              directory.resolvingSymlinksInPath().path == directory.path else { throw WriterError.ownership }
        self.destination = directory.appendingPathComponent("loading-trace.json")
        self.pid = pid; self.runID = runID
        let data = try Self.encoded(.init(version: 1, pid: pid, runID: runID, events: [], omittedEvents: 0))
        try data.write(to: destination, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        lastData = data
    }

    @discardableResult func record(_ observation: LocalModelLoadStageObservation) -> Bool {
        lock.withLock {
            let group = observation.stage == "group-started" || observation.stage == "group-ready"
            guard observation.sequence > 0, Self.stages.contains(observation.stage),
                  loadID == nil || loadID == observation.loadID,
                  !events.contains(where: { $0.observation.sequence == observation.sequence }),
                  group ? (observation.groupIndex != nil && observation.groupCount != nil
                    && observation.groupIndex! >= 0 && observation.groupIndex! < observation.groupCount!)
                    : (observation.groupIndex == nil && observation.groupCount == nil) else {
                rejected += 1; return false
            }
            var candidate = events + [.init(observation: observation,
                elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - started)]
            candidate.sort { $0.observation.sequence < $1.observation.sequence }
            // Conserva las primeras 16 y últimas 16 etapas; declara las omitidas.
            if candidate.count > 32 { candidate.remove(at: 16) }
            do {
                try persist(candidate, acceptedEvents: acceptedEvents + 1)
                events = candidate; acceptedEvents += 1; loadID = observation.loadID
                return true
            } catch { failures += 1; return false }
        }
    }

    private func persist(_ candidate: [Event], acceptedEvents: Int) throws {
        var attributes = stat()
        guard lstat(destination.path, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_uid == getuid(), attributes.st_mode & 0o777 == 0o600,
              attributes.st_nlink == 1, attributes.st_size == lastData.count,
              try Data(contentsOf: destination) == lastData else { throw WriterError.ownership }
        let data = try Self.encoded(.init(version: 1, pid: pid, runID: runID,
            events: candidate, omittedEvents: acceptedEvents - candidate.count))
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        lastData = data
    }

    private static func encoded(_ value: Record) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 8_192 else { throw WriterError.budget }
        return data
    }

    var writeFailures: Int { lock.withLock { failures } }
    var rejectedEvents: Int { lock.withLock { rejected } }
    var snapshot: Record { lock.withLock { .init(version: 1, pid: pid, runID: runID,
        events: events, omittedEvents: acceptedEvents - events.count) } }
}
