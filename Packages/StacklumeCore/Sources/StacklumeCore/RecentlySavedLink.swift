import Foundation

/// Puente entre la Share Extension y la app, 100 % soportado por App Store:
/// la extensión registra el último enlace guardado en el App Group y la app,
/// al volver a primer plano, ofrece abrirlo. No abre la app desde la extensión
/// (eso requeriría técnicas no permitidas en revisión).
public enum RecentlySavedLink {
    private static let idKey = "stacklume.recentlySaved.id"
    private static let titleKey = "stacklume.recentlySaved.title"
    private static let dateKey = "stacklume.recentlySaved.date"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: StacklumeCore.appGroupID)
    }

    /// Registra el enlace recién guardado desde la extensión.
    public static func record(id: UUID, title: String) {
        guard let defaults else { return }
        defaults.set(id.uuidString, forKey: idKey)
        defaults.set(title, forKey: titleKey)
        defaults.set(Date(), forKey: dateKey)
    }

    /// Devuelve el enlace guardado recientemente (dentro de `maxAge` segundos) y
    /// aún sin consumir, o `nil` si no hay ninguno pendiente.
    public static func pending(maxAge: TimeInterval = 300) -> (id: UUID, title: String)? {
        guard let defaults,
              let idString = defaults.string(forKey: idKey),
              let id = UUID(uuidString: idString),
              let date = defaults.object(forKey: dateKey) as? Date,
              Date().timeIntervalSince(date) <= maxAge else { return nil }
        let title = defaults.string(forKey: titleKey) ?? ""
        return (id, title)
    }

    /// Marca el enlace pendiente como consumido.
    public static func clear() {
        guard let defaults else { return }
        defaults.removeObject(forKey: idKey)
        defaults.removeObject(forKey: titleKey)
        defaults.removeObject(forKey: dateKey)
    }
}
