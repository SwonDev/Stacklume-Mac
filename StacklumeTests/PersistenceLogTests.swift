import Foundation
import SwiftData
import Testing
import StacklumeCore

@Suite("Persistencia — invalidación de cachés")
struct PersistenceLogTests {
    @Test("Un guardado correcto emite exactamente una revisión del modelo")
    @MainActor
    func successfulSavePublishesRevision() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Bookmark.self, configurations: configuration)
        let context = container.mainContext

        await confirmation("Se notificó la transacción guardada", expectedCount: 1) { confirmed in
            let token = NotificationCenter.default.addObserver(
                forName: .stacklumeModelDidSave,
                object: nil,
                queue: nil
            ) { _ in
                confirmed()
            }
            defer { NotificationCenter.default.removeObserver(token) }

            context.insert(Bookmark(url: "https://example.com", title: "Ejemplo"))
            context.saveLogging("Prueba de revisión")
        }
    }

    @Test("Guardar sin cambios no invalida las vistas")
    @MainActor
    func unchangedContextDoesNotPublishRevision() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Bookmark.self, configurations: configuration)
        let context = container.mainContext

        await confirmation("No hubo una transacción", expectedCount: 0) { confirmed in
            let token = NotificationCenter.default.addObserver(
                forName: .stacklumeModelDidSave,
                object: nil,
                queue: nil
            ) { _ in
                confirmed()
            }
            defer { NotificationCenter.default.removeObserver(token) }

            context.saveLogging("Prueba sin cambios")
        }
    }
}
