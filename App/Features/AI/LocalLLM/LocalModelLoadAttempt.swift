import Foundation

enum LocalModelLoadingError: Error, Equatable {
    case unknownMemoryPressure
    case memoryPressure(Int32)
    case workingSetBudgetExceeded
}

struct LocalModelLoadAdmission {
    private(set) var isBlocked = false
    mutating func block() { isBlocked = true }
    mutating func explicitRequest(hasPendingAttempt: Bool) {
        if !hasPendingAttempt { isBlocked = false }
    }

    @MainActor mutating func requestUnload<Value: Sendable>(attempt: LocalModelLoadAttempt<Value>?,
        reason: any Error, hasActiveInference: Bool) -> Bool {
        if let attempt {
            attempt.cancel(reason)
            block()
        }
        return hasActiveInference
    }
}

/// Solo guarda la causa del intento; nunca conserva modelos, sesiones ni arrays.
final class LocalModelLoadControl: @unchecked Sendable {
    private let lock = NSLock()
    private var firstError: (any Error)?
    private var warningDeadline: ContinuousClock.Instant?

    var terminalError: (any Error)? { lock.withLock { firstError } }

    @discardableResult func stop(_ error: any Error) -> any Error {
        lock.withLock {
            if let firstError { return firstError }
            firstError = error
            return error
        }
    }

    func check(pressure: @Sendable () -> Int32?) throws {
        if let error = terminalError { throw error }
        if Task.isCancelled { throw stop(CancellationError()) }
        guard let level = pressure() else { throw stop(LocalModelLoadingError.unknownMemoryPressure) }
        guard level == 1 else { throw stop(LocalModelLoadingError.memoryPressure(level)) }
        if let error = terminalError { throw error }
    }

    func checkLoadingPressure(pressure: @Sendable () -> Int32?,
                              recoveryTimeout: Duration = .seconds(5),
                              workingSetIsSafe: (@Sendable () -> Bool)? = nil,
                              releaseCache: @Sendable () -> Void = {}) throws {
        let clock = ContinuousClock()
        while true {
            if let error = terminalError { throw error }
            if Task.isCancelled { throw stop(CancellationError()) }
            guard let level = pressure() else { throw stop(LocalModelLoadingError.unknownMemoryPressure) }
            guard level == 1 || level == 2 else { throw stop(LocalModelLoadingError.memoryPressure(level)) }
            if let workingSetIsSafe, !workingSetIsSafe() {
                throw stop(LocalModelLoadingError.workingSetBudgetExceeded)
            }
            if level == 1 {
                if let error = terminalError { throw error }
                return
            }
            let (deadline, firstWarning) = lock.withLock {
                if let warningDeadline { return (warningDeadline, false) }
                let deadline = clock.now.advanced(by: recoveryTimeout)
                warningDeadline = deadline
                return (deadline, true)
            }
            if firstWarning { releaseCache() }
            if clock.now >= deadline {
                // WARNING puede persistir con pesos válidos retenidos. Solo continúa
                // con presupuesto comprobado; CRITICAL y una lectura fallida abortan.
                guard let workingSetIsSafe else { throw stop(LocalModelLoadingError.memoryPressure(level)) }
                Thread.sleep(forTimeInterval: 0.025)
                try checkResidentPressure(pressure: pressure, workingSetIsSafe: workingSetIsSafe)
                return
            }
            // Solo se usa en los checkpoints del SDK, fuera del MainActor.
            // El plazo es compartido por todo el intento; no reinicia por grupo.
            Thread.sleep(forTimeInterval: 0.025)
        }
    }

    func checkResidentPressure(pressure: @Sendable () -> Int32?,
                               workingSetIsSafe: @Sendable () -> Bool) throws {
        if let error = terminalError { throw error }
        if Task.isCancelled { throw stop(CancellationError()) }
        guard let level = pressure() else { throw stop(LocalModelLoadingError.unknownMemoryPressure) }
        guard level == 1 || level == 2 else { throw stop(LocalModelLoadingError.memoryPressure(level)) }
        guard workingSetIsSafe() else { throw stop(LocalModelLoadingError.workingSetBudgetExceeded) }
        if let error = terminalError { throw error }
    }
}

/// Se registra sin suspender y se conserva hasta que el task devuelve su valor.
/// Cancelar un consumidor cancela el intento compartido; no inicia otro al drenar.
@MainActor final class LocalModelLoadAttempt<Value: Sendable> {
    let id: UUID
    let control: LocalModelLoadControl
    private(set) var task: Task<Value?, Never>?
    private let cancelPolicy: @Sendable () -> Void

    init(id: UUID, control: LocalModelLoadControl, cancelPolicy: @escaping @Sendable () -> Void) {
        self.id = id
        self.control = control
        self.cancelPolicy = cancelPolicy
    }

    func register(_ operation: @escaping @MainActor @Sendable () async -> Value?) {
        precondition(task == nil)
        task = Task { await operation() }
    }

    func cancel(_ error: any Error = CancellationError()) {
        control.stop(error)
        cancelPolicy()
        task?.cancel()
    }

    func canPublish(activeID: UUID?) -> Bool {
        activeID == id && !Task.isCancelled && control.terminalError == nil
    }

    nonisolated static func loadDetached(cancelPolicy: @escaping @Sendable () -> Void,
        operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let task = Task.detached(priority: .background) { try await operation() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            cancelPolicy()
            task.cancel()
        }
    }

    func value() async -> Value? {
        guard let task else { return nil }
        let control = control, cancelPolicy = cancelPolicy
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            control.stop(CancellationError())
            cancelPolicy()
            task.cancel()
        }
        guard !Task.isCancelled, control.terminalError == nil else { return nil }
        return result
    }
}
