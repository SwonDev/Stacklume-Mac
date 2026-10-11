import Foundation
import Testing

private final class LoadingPressureSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int32?]
    init(_ values: [Int32?]) { self.values = values }
    func next() -> Int32? {
        lock.withLock {
            if values.count > 1 { return values.removeFirst() }
            return values.first ?? nil
        }
    }
}

struct LocalModelLoadingPressureTests {
    @Test("Un aviso recuperado permite continuar sin cancelar la carga")
    func recoveredWarning() throws {
        let pressure = LoadingPressureSequence([2, 1])
        let control = LocalModelLoadControl()
        try control.checkLoadingPressure(pressure: { pressure.next() }, recoveryTimeout: .seconds(1))
        #expect(control.terminalError == nil)
    }

    @Test("Un aviso persistente agota su plazo y conserva la causa")
    func persistentWarning() {
        let control = LocalModelLoadControl()
        #expect(throws: LocalModelLoadingError.memoryPressure(2)) {
            try control.checkLoadingPressure(pressure: { 2 }, recoveryTimeout: .zero)
        }
        #expect(control.terminalError as? LocalModelLoadingError == .memoryPressure(2))
    }

    @Test("La presión crítica interrumpe la recuperación inmediatamente")
    func criticalDuringRecovery() {
        let pressure = LoadingPressureSequence([2, 4])
        let control = LocalModelLoadControl()
        #expect(throws: LocalModelLoadingError.memoryPressure(4)) {
            try control.checkLoadingPressure(pressure: { pressure.next() })
        }
    }

    @Test("Una lectura desconocida nunca permite seguir cargando")
    func unknownPressure() {
        let control = LocalModelLoadControl()
        #expect(throws: LocalModelLoadingError.unknownMemoryPressure) {
            try control.checkLoadingPressure(pressure: { nil })
        }
    }

    @Test("La cancelación conserva su causa aunque la memoria se recupere")
    func cancelledAttempt() {
        let control = LocalModelLoadControl()
        control.stop(CancellationError())
        #expect(throws: CancellationError.self) {
            try control.checkLoadingPressure(pressure: { 1 })
        }
    }

    @Test("Cancelar durante la recuperación interrumpe la espera")
    func cancellationDuringRecovery() {
        let control = LocalModelLoadControl()
        #expect(throws: CancellationError.self) {
            try control.checkLoadingPressure(pressure: { 2 }, releaseCache: {
                control.stop(CancellationError())
            })
        }
    }

    @Test("Las advertencias posteriores comparten el plazo del intento")
    func sharedRecoveryDeadline() throws {
        let pressure = LoadingPressureSequence([2, 1, 2])
        let control = LocalModelLoadControl()
        try control.checkLoadingPressure(pressure: { pressure.next() }, recoveryTimeout: .milliseconds(50))
        Thread.sleep(forTimeInterval: 0.06)
        #expect(throws: LocalModelLoadingError.memoryPressure(2)) {
            try control.checkLoadingPressure(pressure: { pressure.next() }, recoveryTimeout: .seconds(5))
        }
    }

    @Test("La comprobación inmediata de la UI sigue rechazando los avisos")
    func immediateAdmission() {
        let control = LocalModelLoadControl()
        #expect(throws: LocalModelLoadingError.memoryPressure(2)) {
            try control.check(pressure: { 2 })
        }
    }

    @Test("Un aviso permite continuar con presupuesto de memoria comprobado")
    func budgetedWarning() throws {
        let control = LocalModelLoadControl()
        try control.checkLoadingPressure(pressure: { 2 }, recoveryTimeout: .zero, workingSetIsSafe: { true })
        #expect(control.terminalError == nil)
    }

    @Test("El presupuesto se comprueba incluso con presión normal")
    func excessiveWorkingSet() {
        for level: Int32 in [1, 2] {
            let control = LocalModelLoadControl()
            #expect(throws: LocalModelLoadingError.workingSetBudgetExceeded) {
                try control.checkLoadingPressure(pressure: { level }, workingSetIsSafe: { false })
            }
        }
    }

    @Test("El presupuesto disponible no autoriza presión crítica")
    func criticalDespiteBudget() {
        let control = LocalModelLoadControl()
        #expect(throws: LocalModelLoadingError.memoryPressure(4)) {
            try control.checkLoadingPressure(pressure: { 4 }, workingSetIsSafe: { true })
        }
    }

    @Test("Publicar el modelo cargado no bloquea el MainActor durante un aviso")
    func residentWarning() throws {
        let control = LocalModelLoadControl()
        try control.checkResidentPressure(pressure: { 2 }, workingSetIsSafe: { true })
        #expect(control.terminalError == nil)
    }
}
