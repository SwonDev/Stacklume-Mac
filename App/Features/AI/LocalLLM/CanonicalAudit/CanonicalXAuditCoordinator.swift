import Foundation
import Observation

@MainActor protocol CanonicalXAuditRunner: AnyObject {
    var diagnosticState: CanonicalObservedRunnerState { get }
    var diagnosticModelAvailable: Bool { get }
    var diagnosticDeactivated: Bool { get }
    var diagnosticBackgroundIdle: Bool { get }
    func complete(system: String, prompt: String, maxTokens: Int, enableThinking: Bool,
                  observer: OneShotObserver?) async -> String?
}
struct CanonicalAuditOutcome: Codable, Sendable {
    struct Rejection: Codable, Sendable { let tone: String; let field: String; let reason: String }
    let version: Int
    let pid: Int32
    let start_abstime: UInt64
    let run_id: String
    let descriptorSHA256: String
    let sourceSHA256: String
    let candidatesSHA256: String
    let contextSHA256: String
    let systemSHA256: String
    let userSHA256: String
    let revision: String
    let calls: Int
    let protocolPassed: Bool
    let provenancePassed: Bool
    let failure: String?
    let rejectedFields: [String]
    let rejections: [Rejection]
    let rawCharacters: Int?
    let rawUTF8Bytes: Int?
    let jsonParsed: Bool?
    let elapsedMilliseconds: Int
    let traceWriteFailures: Int
    let rejectedTraceEvents: Int
    let completion: OneShotCompletionMetrics?
    let userDraftWrites: Int
    let publications: Int
    enum CodingKeys: String, CodingKey {
        case version, pid, start_abstime, run_id, descriptorSHA256, sourceSHA256, candidatesSHA256, contextSHA256
        case systemSHA256, userSHA256, revision, calls, protocolPassed, provenancePassed, failure, rejectedFields, rejections
        case rawCharacters, rawUTF8Bytes, jsonParsed, elapsedMilliseconds, traceWriteFailures, rejectedTraceEvents, completion, userDraftWrites, publications
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version); try values.encode(pid, forKey: .pid)
        try values.encode(start_abstime, forKey: .start_abstime); try values.encode(run_id, forKey: .run_id)
        try values.encode(descriptorSHA256, forKey: .descriptorSHA256)
        try values.encode(sourceSHA256, forKey: .sourceSHA256); try values.encode(candidatesSHA256, forKey: .candidatesSHA256)
        try values.encode(contextSHA256, forKey: .contextSHA256); try values.encode(systemSHA256, forKey: .systemSHA256)
        try values.encode(userSHA256, forKey: .userSHA256); try values.encode(revision, forKey: .revision)
        try values.encode(calls, forKey: .calls); try values.encode(protocolPassed, forKey: .protocolPassed)
        try values.encode(provenancePassed, forKey: .provenancePassed); try values.encode(failure, forKey: .failure)
        try values.encode(rejectedFields, forKey: .rejectedFields); try values.encode(rejections, forKey: .rejections)
        try values.encode(rawCharacters, forKey: .rawCharacters); try values.encode(rawUTF8Bytes, forKey: .rawUTF8Bytes)
        try values.encode(jsonParsed, forKey: .jsonParsed); try values.encode(elapsedMilliseconds, forKey: .elapsedMilliseconds)
        try values.encode(traceWriteFailures, forKey: .traceWriteFailures); try values.encode(rejectedTraceEvents, forKey: .rejectedTraceEvents)
        try values.encode(completion, forKey: .completion); try values.encode(userDraftWrites, forKey: .userDraftWrites)
        try values.encode(publications, forKey: .publications)
    }
}

@MainActor @Observable final class CanonicalXAuditCoordinator: CanonicalXAuditMenuEntry {
    private(set) var status = CanonicalXAuditStatus.disarmed
    private let arguments: [String]
    private let root: URL
    private let runner: any CanonicalXAuditRunner
    private let identity: @MainActor () throws -> CanonicalProcessIdentity
    private let installed: @MainActor () throws -> CanonicalInstalledIdentity
    private let fixture: @MainActor () throws -> CanonicalPreparedAudit
    private var consumption = CanonicalSingleConsumption()
    private var preparationAttempted = false
    private var ticket: CanonicalArmedTicket?
    private var prepared: CanonicalPreparedAudit?
    private var projection: CanonicalObservedPhaseProjection?
    private var phaseWriteFailed = false

    init(arguments: [String], root: URL, runner: any CanonicalXAuditRunner,
         identity: @escaping @MainActor () throws -> CanonicalProcessIdentity,
         installed: @escaping @MainActor () throws -> CanonicalInstalledIdentity,
         fixture: @escaping @MainActor () throws -> CanonicalPreparedAudit) {
        self.arguments = arguments; self.root = root; self.runner = runner
        self.identity = identity; self.installed = installed; self.fixture = fixture
    }
    var canRun: Bool {
        guard status == .armed, !phaseWriteFailed, runner.diagnosticModelAvailable,
              !runner.diagnosticDeactivated, runner.diagnosticBackgroundIdle,
              let ticket, prepared != nil else { return false }
        return (try? ticket.revalidate(current: identity(), installed: installed())) != nil
    }
    func prepareFromLaunchArguments() async {
        guard !preparationAttempted else { return }
        preparationAttempted = true
        guard arguments.contains("--stacklume-x91-diagnostic") || arguments.contains("--descriptor-sha256") else { return }
        do {
            guard let ticket = try CanonicalArmedTicket.prepare(arguments: arguments, allowedRoot: root,
                  installed: installed(), identity: identity()) else { return }
            self.ticket = ticket
            guard runner.diagnosticModelAvailable, !runner.diagnosticDeactivated,
                  runner.diagnosticBackgroundIdle else { throw CanonicalTicketError.identity }
            let prepared = try fixture()
            self.prepared = prepared
            try await waitForFile("grant.json", ticket: ticket)
            try ticket.validateGrant(current: identity())
            try ticket.files.create(CanonicalPhaseRecord(pid: ticket.identity.pid, run_id: ticket.descriptor.run_id,
                phase: "preparing", sequence: 0), name: "phase.json", maximum: 2_048)
            try await waitForFile("ack.json", ticket: ticket)
            try ticket.revalidate(current: identity(), installed: installed())
            guard runner.diagnosticBackgroundIdle, runner.diagnosticModelAvailable, !runner.diagnosticDeactivated,
                  let nonce = UUID(uuidString: ticket.descriptor.run_id), consumption.arm(runID: nonce) else { throw CanonicalTicketError.identity }
            status = .armed
        } catch { status = .failed }
    }
    func runArmedAudit() async {
        guard status == .armed, let ticket, let prepared, let nonce = UUID(uuidString: ticket.descriptor.run_id) else { return }
        // Consume antes de cualquier await; el fallo posterior conserva el consumo.
        guard consumption.consume(runID: nonce, identityValid: canRun,
                                  backgroundIdle: runner.diagnosticBackgroundIdle, ackValid: true) else {
            status = .failed; return
        }
        status = .running
        let started = DispatchTime.now().uptimeNanoseconds
        var calls = 0
        var raw: String?
        var audit: XPostCopyAuditResult?
        var failure: String?
        var writer: OneShotObservationWriter?
        do {
            try Task.checkCancellation()
            try ticket.revalidate(current: identity(), installed: installed())
            let current = try fixture()
            guard current.sourceSHA256 == prepared.sourceSHA256, current.candidatesSHA256 == prepared.candidatesSHA256,
                  current.contextSHA256 == prepared.contextSHA256, current.systemSHA256 == prepared.systemSHA256,
                  current.userSHA256 == prepared.userSHA256 else { throw CanonicalTicketError.changed }
            try ticket.files.create(CanonicalClaim(pid: ticket.identity.pid, run_id: ticket.descriptor.run_id,
                descriptorSHA256: ticket.descriptorSHA256, consumed: true), name: "claim.json", maximum: 2_048)
            let trace = try OneShotObservationWriter(destination: ticket.files.directory.appendingPathComponent("trace.json"),
                pid: ticket.identity.pid, runID: ticket.descriptor.run_id)
            writer = trace
            let loadingTrace = try LocalModelLoadStageWriter(directory: ticket.files.directory,
                pid: ticket.identity.pid, runID: ticket.descriptor.run_id)
            let milestones = try trace.observer(callID: UUID())
            let observer = OneShotObserver(record: milestones.record,
                recordLoading: { _ = loadingTrace.record($0) })
            let projection = CanonicalObservedPhaseProjection(readState: { [weak runner] in
                runner?.diagnosticState ?? .failed
            }, record: { [weak self] phase in
                do {
                    try ticket.files.update(CanonicalPhaseRecord(pid: ticket.identity.pid,
                        run_id: ticket.descriptor.run_id, phase: phase.rawValue, sequence: phase.sequence), name: "phase.json", maximum: 2_048)
                } catch { self?.phaseWriteFailed = true }
            })
            self.projection = projection
            projection.arm()
            guard !phaseWriteFailed, runner.diagnosticBackgroundIdle else { throw CanonicalTicketError.changed }
            try Task.checkCancellation()
            projection.callBegan()
            guard !phaseWriteFailed else { throw CanonicalTicketError.changed }
            calls = 1
            raw = await runner.complete(system: prepared.request.system, prompt: prepared.request.user,
                                        maxTokens: 4_096, enableThinking: false, observer: observer)
            projection.finish()
            self.projection = nil
            try Task.checkCancellation()
            guard !phaseWriteFailed else { throw CanonicalTicketError.changed }
            try ticket.revalidate(current: identity(), installed: installed())
            let final = try fixture()
            guard final.sourceSHA256 == prepared.sourceSHA256, final.candidatesSHA256 == prepared.candidatesSHA256,
                  final.contextSHA256 == prepared.contextSHA256, final.systemSHA256 == prepared.systemSHA256,
                  final.userSHA256 == prepared.userSHA256 else { throw CanonicalTicketError.changed }
            guard let raw else { throw CanonicalCoordinatorError.noResponse }
            audit = try XPostSemanticAuditPolicy.extract(raw, batch: prepared.batch)
            guard audit?.revision == prepared.batch.revision else { throw XPostSemanticAuditPolicy.AuditError.staleRevision }
            guard trace.writeFailures == 0, trace.rejectedEvents == 0,
                  loadingTrace.writeFailures == 0, loadingTrace.rejectedEvents == 0 else { throw CanonicalCoordinatorError.trace }
        } catch {
            projection?.finish(); projection = nil
            failure = Self.failureCode(error)
        }
        let diagnostic = raw.map { XPostBatchDiagnostic(call: max(1, calls), phase: .audit, raw: $0,
            candidate: prepared.batch, issues: audit?.issues ?? [], invalidProvenance: failure == "invalid-provenance") }
        let issues = audit?.issues ?? []
        let elapsed = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let outcome = CanonicalAuditOutcome(version: 1, pid: ticket.identity.pid, start_abstime: ticket.identity.start_abstime,
            run_id: ticket.descriptor.run_id, descriptorSHA256: ticket.descriptorSHA256,
            sourceSHA256: prepared.sourceSHA256, candidatesSHA256: prepared.candidatesSHA256, contextSHA256: prepared.contextSHA256,
            systemSHA256: prepared.systemSHA256, userSHA256: prepared.userSHA256, revision: prepared.batch.revision.uuidString,
            calls: calls, protocolPassed: audit != nil && failure == nil, provenancePassed: audit != nil && failure == nil,
            failure: failure, rejectedFields: issues.map { $0.tone.rawValue + "/" + $0.field.rawValue }.sorted(),
            rejections: issues.map { .init(tone: $0.tone.rawValue, field: $0.field.rawValue, reason: $0.reason.rawValue) },
            rawCharacters: diagnostic?.rawCharacters, rawUTF8Bytes: diagnostic?.rawUTF8Bytes, jsonParsed: diagnostic?.jsonParsed,
            elapsedMilliseconds: Int(min(UInt64(Int.max), elapsed)), traceWriteFailures: writer?.writeFailures ?? 0,
            rejectedTraceEvents: writer?.rejectedEvents ?? 0, completion: writer?.snapshot.calls.first?.completion,
            userDraftWrites: 0, publications: 0)
        raw = nil
        do { try ticket.files.create(outcome, name: "outcome.json", maximum: 8_192) }
        catch { failure = "outcome-write" }
        consumption.finish(succeeded: failure == nil)
        status = consumption.status
    }
    private func waitForFile(_ name: String, ticket: CanonicalArmedTicket) async throws {
        let started = DispatchTime.now().uptimeNanoseconds
        while true {
            try Task.checkCancellation()
            do { _ = try ticket.files.read(name, maximum: 2_048); return }
            catch let error as POSIXError where error.code == .ENOENT { }
            guard DispatchTime.now().uptimeNanoseconds - started < 2_000_000_000 else { throw CanonicalCoordinatorError.handshakeTimeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private enum CanonicalCoordinatorError: Error { case noResponse, trace, handshakeTimeout }
    private static func failureCode(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? XPostSemanticAuditPolicy.AuditError {
            switch error { case .malformed: return "malformed"; case .invalidProvenance: return "invalid-provenance"
            case .staleRevision: return "stale-revision"; case .notApproved: return "not-approved"; case .budget: return "budget" }
        }
        if let error = error as? CanonicalCoordinatorError {
            switch error { case .noResponse: return "no-response"; case .trace: return "trace"; case .handshakeTimeout: return "handshake-timeout" }
        }
        return "identity-or-files-invalid"
    }
}
