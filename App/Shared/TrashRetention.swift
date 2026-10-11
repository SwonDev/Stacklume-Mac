import Foundation
import SwiftData
import StacklumeCore

/// Caducidad de la papelera (paridad con Raindrop, que la vacía a los 7 días). Aquí, más
/// conservador: borra DEFINITIVAMENTE los enlaces que llevan más de `days` días en la papelera,
/// para que no crezca sin límite (sus copias offline en `@Attribute(.externalStorage)` y sus
/// portadas seguían ocupando disco). Reutiliza `BookmarkActions.deleteForever`, así que también
/// limpia los datos laterales. Pensado para el arranque.
@MainActor
enum TrashRetention {
    static let defaultDays = 30

    @discardableResult
    static func purgeOld(in context: ModelContext, days: Int = defaultDays) -> Int {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let old = ((try? context.fetch(FetchDescriptor<Bookmark>(
            predicate: #Predicate { $0.deletedAt != nil }))) ?? [])
            .filter { ($0.deletedAt ?? .distantPast) < cutoff }
        guard !old.isEmpty else { return 0 }
        BookmarkActions.deleteForever(old, in: context)
        return old.count
    }
}
