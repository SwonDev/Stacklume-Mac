import Foundation

public struct ModelLoadingEvent: Sendable {
    public let sequence: Int
    public let stage: String
    public let groupIndex: Int?
    public let groupCount: Int?
}

public enum ModelLoadingPolicyError: Error {
    case invalidBounds
}

/// Una instancia por intento; conserva la primera causa terminal hasta que termina.
/// El lock protege causa y secuencia; guarda y observador se ejecutan fuera de él.
public final class ModelLoadingPolicy: @unchecked Sendable {
    public let maximumConcurrentGroups: Int
    public let targetBytesPerGroup: Int64
    private let lock = NSLock()
    private var terminalCause: (any Error)?
    private var sequence = 0
    private let guardOperation: @Sendable () throws -> Void
    private let observer: @Sendable (ModelLoadingEvent) -> Void

    public init(maximumConcurrentGroups: Int, targetBytesPerGroup: Int64,
                guardOperation: @escaping @Sendable () throws -> Void,
                observer: @escaping @Sendable (ModelLoadingEvent) -> Void) throws {
        guard (1...16).contains(maximumConcurrentGroups),
              targetBytesPerGroup >= 256 * 1024 * 1024 else {
            throw ModelLoadingPolicyError.invalidBounds
        }
        self.maximumConcurrentGroups = maximumConcurrentGroups
        self.targetBytesPerGroup = targetBytesPerGroup
        self.guardOperation = guardOperation
        self.observer = observer
    }

    public var isCancelled: Bool { lock.withLock { terminalCause != nil } }

    public func cancel() { _ = latch(CancellationError()) }

    fileprivate func latch(_ cause: any Error) -> any Error {
        lock.withLock {
            if let terminalCause { return terminalCause }
            terminalCause = cause
            return cause
        }
    }

    private func checkStopped() throws {
        if let cause = lock.withLock({ terminalCause }) { throw cause }
    }

    package func checkpoint(stage: String, groupIndex: Int? = nil,
                            groupCount: Int? = nil) throws {
        try checkStopped()
        do { try guardOperation() } catch { throw latch(error) }
        let event = try lock.withLock { () throws -> ModelLoadingEvent in
            if let terminalCause { throw terminalCause }
            sequence += 1
            return .init(sequence: sequence, stage: stage,
                         groupIndex: groupIndex, groupCount: groupCount)
        }
        observer(event)
        try checkStopped()
    }

    public static func withPolicy<R: Sendable>(
        _ policy: ModelLoadingPolicy,
        operation: @Sendable () async throws -> R
    ) async throws -> R {
        try await withTaskCancellationHandler {
            try await ModelLoadingScope.$current.withValue(policy) {
                do {
                    try policy.checkpoint(stage: "load-started")
                    let result = try await operation()
                    try policy.checkpoint(stage: "load-returned")
                    return result
                } catch {
                    if error is CancellationError { _ = policy.latch(error) }
                    try policy.checkStopped()
                    throw error
                }
            }
        } onCancel: {
            policy.cancel()
        }
    }
}

package enum ModelLoadingScope {
    @TaskLocal package static var current: ModelLoadingPolicy?
}

/// Una pareja concreta tokenizer/pesos; solo el padre marca su fallo ordinario
/// antes de salir del scope async let y empezar el drenaje estructurado.
package final class ModelLoadingTokenizerAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private let policy: ModelLoadingPolicy
    private var drainingOrdinaryParentFailure = false

    package init(policy: ModelLoadingPolicy) { self.policy = policy }

    package func parentFailed(_ error: any Error) {
        guard !(error is CancellationError), !policy.isCancelled else { return }
        lock.withLock { drainingOrdinaryParentFailure = true }
    }

    fileprivate func permitsCleanup(for current: ModelLoadingPolicy) -> Bool {
        current === policy && lock.withLock { drainingOrdinaryParentFailure }
    }
}

package func loadTokenizerWithPolicy(
    _ loader: any TokenizerLoader, from directory: URL,
    attempt: ModelLoadingTokenizerAttempt? = nil
) async throws -> any Tokenizer {
    let policy = ModelLoadingScope.current
    do {
        try policy?.checkpoint(stage: "tokenizer-started")
        let tokenizer = try await loader.load(from: directory)
        try policy?.checkpoint(stage: "tokenizer-ready")
        return tokenizer
    } catch let error as CancellationError {
        if let policy {
            // El flag de la hija no demuestra por sí solo limpieza del padre:
            // también puede haber sido cancelada por su propio tokenizer.
            if Task.isCancelled, !policy.isCancelled,
                attempt?.permitsCleanup(for: policy) == true {
                throw error
            }
            throw policy.latch(error)
        }
        throw error
    }
}
