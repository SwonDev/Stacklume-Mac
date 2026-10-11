import Foundation
import SwiftData
import StacklumeCore

/// Acceso al registro único de preferencias (`AppSettings`).
@MainActor
public enum AppSettingsStore {

    /// Devuelve el `AppSettings` existente o crea uno nuevo si no hay ninguno.
    @discardableResult
    public static func current(in context: ModelContext) -> AppSettings {
        var descriptor = FetchDescriptor<AppSettings>()
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let created = AppSettings()
        context.insert(created)
        try? context.save()
        return created
    }
}
