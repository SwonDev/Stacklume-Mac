import Foundation

/// Distingue un borrado solicitado de una pérdida accidental del store.
enum LibraryResetIntent {
    private static let key = "stacklume.libraryIntentionallyEmpty"

    static func preventsAutomaticRecovery(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func markIntentionalReset(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }

    static func performingReset<T>(in defaults: UserDefaults = .standard, _ operation: () throws -> T) rethrows -> T {
        let previous = defaults.object(forKey: key)
        markIntentionalReset(in: defaults)
        do { return try operation() }
        catch {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
            throw error
        }
    }

    static func didCreateNonemptyBackup(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
