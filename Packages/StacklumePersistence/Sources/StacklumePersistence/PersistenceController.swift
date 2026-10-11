import Foundation
import SwiftData
import StacklumeCore

/// Construye y configura el `ModelContainer` de la app.
public enum PersistenceController {

    /// Crea el contenedor SwiftData con el esquema completo de Stacklume.
    /// - Parameter inMemory: si es `true`, los datos no se persisten en disco
    ///   (útil para previews y tests).
    public static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        let schema = Schema(StacklumeCore.models)

        if inMemory {
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            // swiftlint:disable:next force_try
            return try! ModelContainer(for: schema, configurations: [configuration])
        }

        // Store compartido con la Share Extension vía App Group, SOLO si el
        // contenedor del grupo está realmente disponible en los entitlements. Si no
        // lo está (p. ej. un build firmado con cuenta de desarrollador gratuita, que
        // no permite App Groups), SwiftData hace `fatalError` al construir la
        // configuración —no es un error capturable con `try?`—, así que lo
        // comprobamos antes con `FileManager` y caemos al store local.
        //
        // En macOS NO se intenta el App Group: acceder al «Group Container» desde una
        // app sin sandbox (distribución Developer ID) dispara el aviso TCC «acceder a
        // datos de otras apps» en cada arranque. La app de escritorio usa su store
        // local; cuando se añada la Share Extension de Mac se reevaluará con los
        // entitlements de App Group adecuados.
        #if !os(macOS)
        if FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: StacklumeCore.appGroupID) != nil {
            let groupConfiguration = ModelConfiguration(
                schema: schema,
                groupContainer: .identifier(StacklumeCore.appGroupID)
            )
            if let container = try? ModelContainer(for: schema, configurations: [groupConfiguration]) {
                return container
            }
        }
        #endif

        // Fallback: store local (si el App Group no está disponible).
        let localConfiguration = ModelConfiguration(schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: [localConfiguration])
        } catch {
            fatalError("No se pudo crear el ModelContainer de Stacklume: \(error)")
        }
    }
}
