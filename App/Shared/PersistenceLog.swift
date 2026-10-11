import Foundation
import SwiftData
import OSLog

/// Registro de persistencia. Un fallo de `ModelContext.save()` (disco lleno, almacén
/// corrupto, violación de constraint) implicaría pérdida o incoherencia de datos; en vez de
/// tragarlo en silencio con `try?`, lo dejamos REGISTRADO para poder diagnosticarlo.
enum PersistenceLog {
    static let logger = Logger(subsystem: "com.swondev.stacklume", category: "persistence")
}

extension Notification.Name {
    /// Señal interna y sin payload: una transacción de SwiftData se guardó correctamente.
    /// Las vistas con cálculos O(n) la usan como revisión barata para invalidar sus cachés
    /// solo cuando cambió el modelo, no en cada hover, selección o animación de SwiftUI.
    static let stacklumeModelDidSave = Notification.Name("stacklume.modelDidSave")
}

extension ModelContext {
    /// Guarda registrando el error si lo hay (en lugar de `try?`, que lo descarta). Para
    /// operaciones del usuario o destructivas donde un fallo NO debe perderse en silencio.
    func saveLogging(_ operation: String = #function) {
        guard hasChanges else { return }
        do {
            try save()
            // Algunos enriquecidos guardan desde un ModelContext de fondo. La señal que
            // invalida `@State` siempre se entrega en main para no introducir escrituras
            // de UI fuera del actor principal; el guardado en sí permanece en su contexto.
            if Thread.isMainThread {
                NotificationCenter.default.post(name: .stacklumeModelDidSave, object: nil)
            } else {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .stacklumeModelDidSave, object: nil)
                }
            }
        } catch {
            PersistenceLog.logger.error(
                "Fallo al guardar (\(operation, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }
}
