import Foundation
import Observation

enum CanonicalObservedRunnerState: Equatable, Sendable {
    case notLoaded, downloading, loading, ready, failed
}
enum CanonicalObservedPhase: String, CaseIterable, Sendable {
    case preparing, loading, ready, generating
    var sequence: Int { Self.allCases.firstIndex(of: self)! }
}

@MainActor final class CanonicalObservedPhaseProjection {
    private let readState: @MainActor () -> CanonicalObservedRunnerState
    private let record: @MainActor (CanonicalObservedPhase) -> Void
    private var armed = false
    private var callActive = false
    private(set) var phase = CanonicalObservedPhase.preparing
    private(set) var observedStates: [CanonicalObservedRunnerState] = []
    private(set) var deliveredRecords = 0
    private var generation: UInt64 = 0

    init(readState: @escaping @MainActor () -> CanonicalObservedRunnerState,
         record: @escaping @MainActor (CanonicalObservedPhase) -> Void) {
        self.readState = readState; self.record = record
    }
    func arm() {
        guard !armed else { return }
        armed = true
        generation += 1
        track(generation)
    }
    func callBegan() {
        guard armed, !callActive else { return }
        callActive = true
        sample(readState())
    }
    func finish() {
        callActive = false
        armed = false
        generation += 1
    }
    private func track(_ ticket: UInt64) {
        guard armed, ticket == generation else { return }
        let state = withObservationTracking {
            readState()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.armed, ticket == self.generation else { return }
                self.track(ticket)
            }
        }
        sample(state)
    }
    private func sample(_ state: CanonicalObservedRunnerState) {
        guard armed else { return }
        // El registro de estados se acota; no conserva los textos de errores del Runner.
        if observedStates.last != state, observedStates.count < 16 { observedStates.append(state) }
        if state == .loading { advance(.loading) }
        if state == .ready {
            advance(.ready)
            if callActive { advance(.generating) }
        }
    }
    private func advance(_ candidate: CanonicalObservedPhase) {
        guard candidate.sequence > phase.sequence else { return }
        phase = candidate
        deliveredRecords += 1
        record(candidate)
    }
}

@MainActor struct CanonicalSingleConsumption {
    private(set) var status = CanonicalXAuditStatus.disarmed
    private(set) var consumed = false
    private var runID: UUID?
    mutating func arm(runID: UUID) -> Bool {
        guard status == .disarmed, !consumed else { return false }
        self.runID = runID; status = .armed; return true
    }
    mutating func consume(runID: UUID, identityValid: Bool, backgroundIdle: Bool, ackValid: Bool) -> Bool {
        guard status == .armed, !consumed, self.runID == runID,
              identityValid, backgroundIdle, ackValid else { return false }
        consumed = true; status = .running; return true
    }
    mutating func finish(succeeded: Bool) {
        guard status == .running, consumed else { return }
        status = succeeded ? .finished : .failed
    }
}
