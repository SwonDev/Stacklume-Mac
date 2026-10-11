import Foundation

enum OneShotMilestone: String, Codable, CaseIterable, Sendable {
    case afterload, inputPrepared, firstStreamEvent, completionInfo, sessionSynchronized, leaseReturned
}
struct OneShotAllocatorMetrics: Codable, Equatable, Sendable {
    let active: Int
    let cache: Int
    let peak: Int
}
struct OneShotCompletionMetrics: Codable, Equatable, Sendable {
    enum Stop: String, Codable, Sendable { case stop, length, cancelled }
    let promptTokens: Int
    let generatedTokens: Int
    let promptTime: Double
    let generationTime: Double
    let stop: Stop
}
struct OneShotObservation: Sendable {
    let milestone: OneShotMilestone
    let memory: OneShotAllocatorMetrics
    let completion: OneShotCompletionMetrics?
}
struct OneShotObserver: Sendable {
    let record: @Sendable (OneShotObservation) -> Void
    let recordLoading: (@Sendable (LocalModelLoadStageObservation) -> Void)?

    init(record: @escaping @Sendable (OneShotObservation) -> Void,
         recordLoading: (@Sendable (LocalModelLoadStageObservation) -> Void)? = nil) {
        self.record = record
        self.recordLoading = recordLoading
    }
}
final class OneShotObservationWriter: @unchecked Sendable {
    enum WriterError: Error { case ownership, existingFile, budget, duplicateCall, serialization }
    struct Event: Codable, Sendable {
        let milestone: OneShotMilestone
        let elapsedNanoseconds: UInt64
        let memory: OneShotAllocatorMetrics
    }
    struct Call: Codable, Sendable {
        let id: UUID
        let ordinal: Int
        var events: [Event]
        var completion: OneShotCompletionMetrics?
        enum CodingKeys: String, CodingKey { case id, ordinal, events, completion }
        func encode(to encoder: Encoder) throws {
            var value = encoder.container(keyedBy: CodingKeys.self)
            try value.encode(id, forKey: .id)
            try value.encode(ordinal, forKey: .ordinal)
            try value.encode(events, forKey: .events)
            try value.encode(completion, forKey: .completion)
        }
        init(id: UUID, ordinal: Int, events: [Event], completion: OneShotCompletionMetrics?) {
            self.id = id; self.ordinal = ordinal; self.events = events; self.completion = completion
        }
    }
    struct Record: Codable, Sendable {
        let version: Int
        let pid: Int32
        let runID: String
        let calls: [Call]
    }
    // El lock protege llamadas, bytes esperados y contadores; el observer conserva
    // únicamente este escritor Foundation, nunca pesos, sesiones ni arrays MLX.
    private let lock = NSLock()
    private let destination: URL
    private let pid: Int32
    private let runID: String
    private let started = DispatchTime.now().uptimeNanoseconds
    private var calls: [Call] = []
    private var lastData: Data
    private var failures = 0
    private var rejected = 0

    init(destination: URL, pid: Int32, runID: String) throws {
        guard destination.isFileURL, pid == ProcessInfo.processInfo.processIdentifier,
              let nonce = UUID(uuidString: runID), nonce.uuidString == runID else { throw WriterError.ownership }
        self.destination = destination; self.pid = pid; self.runID = runID
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let bytes = try Self.encoded(.init(version: 1, pid: pid, runID: runID, calls: []))
        do { try bytes.write(to: destination, options: .withoutOverwriting) }
        catch {
            if FileManager.default.fileExists(atPath: destination.path) { throw WriterError.existingFile }
            throw error
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        self.lastData = bytes
    }

    func observer(callID: UUID) throws -> OneShotObserver {
        try lock.withLock {
            guard calls.count < 7 else { throw WriterError.budget }
            guard !calls.contains(where: { $0.id == callID }) else { throw WriterError.duplicateCall }
            let candidate = calls + [.init(id: callID, ordinal: calls.count + 1, events: [], completion: nil)]
            try persist(candidate)
            calls = candidate
        }
        return .init(record: { _ = self.record($0, callID: callID) })
    }

    @discardableResult func record(_ observation: OneShotObservation, callID: UUID) -> Bool {
        lock.withLock {
            guard let index = calls.firstIndex(where: { $0.id == callID }),
                  observation.memory.active >= 0, observation.memory.cache >= 0,
                  observation.memory.peak >= observation.memory.active,
                  let next = OneShotMilestone.allCases.firstIndex(of: observation.milestone),
                  calls[index].events.last.map({ OneShotMilestone.allCases.firstIndex(of: $0.milestone)! < next }) ?? true,
                  (observation.milestone == .completionInfo) == (observation.completion != nil) else {
                rejected += 1; return false
            }
            if let info = observation.completion {
                guard info.promptTokens >= 0, info.generatedTokens >= 0,
                      info.promptTime.isFinite, info.generationTime.isFinite,
                      info.promptTime >= 0, info.generationTime >= 0 else { rejected += 1; return false }
            }
            var candidate = calls
            candidate[index].events.append(.init(milestone: observation.milestone,
                elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - started, memory: observation.memory))
            if let info = observation.completion { candidate[index].completion = info }
            do {
                try persist(candidate)
                calls = candidate
                return true
            } catch { failures += 1; return false }
        }
    }

    private func persist(_ candidate: [Call]) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              attributes[.size] as? Int == lastData.count,
              try Data(contentsOf: destination) == lastData else { throw WriterError.ownership }
        let bytes = try Self.encoded(.init(version: 1, pid: pid, runID: runID, calls: candidate))
        try bytes.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        lastData = bytes
    }
    private static func encoded(_ record: Record) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(record)
        guard bytes.count <= 8_192 else { throw WriterError.serialization }
        return bytes
    }
    var snapshot: Record { lock.withLock { .init(version: 1, pid: pid, runID: runID, calls: calls) } }
    var writeFailures: Int { lock.withLock { failures } }
    var rejectedEvents: Int { lock.withLock { rejected } }
}
