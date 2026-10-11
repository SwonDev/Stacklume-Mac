import Foundation
import UserNotifications

extension Notification.Name {
    /// Se emite cuando el usuario toca una notificación de recordatorio.
    static let stacklumeOpenBookmark = Notification.Name("stacklume.openBookmark")
    /// Se emite al tocar la notificación «¿Guardar este enlace?» del monitor de portapapeles.
    /// `object`: la URL (String) a guardar.
    static let stacklumeSaveURL = Notification.Name("stacklume.saveURL")
}

/// Programa recordatorios «leer más tarde» como notificaciones locales. Al tocar
/// la notificación se emite `stacklumeOpenBookmark` con el `id` del marcador.
///
/// `UNUserNotificationCenter` es multiplataforma (iOS y macOS), así que esta
/// implementación replica fielmente la del iPhone, sin dependencias específicas
/// de UIKit (que no existen en el Mac).
@MainActor
enum ReminderService {
    private static let prefix = "stacklume.reminder."

    /// Pide permiso para notificaciones (idempotente).
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        default:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    /// Programa (o reprograma) el recordatorio de un enlace.
    static func schedule(id: UUID, title: String, host: String, at date: Date) async {
        guard await requestAuthorization() else { return }
        guard date > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? host : title
        content.body = "Recordatorio de Stacklume · \(host)"
        content.sound = .default
        content.userInfo = ["bookmarkID": id.uuidString]

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: prefix + id.uuidString, content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Notificación INMEDIATA (sin trigger) para feedback rápido, p. ej. tras guardar
    /// un enlace con el atajo global. Best-effort: si no hay permiso, no muestra nada.
    static func notifyNow(title: String, body: String) async {
        guard await requestAuthorization() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "stacklume.quicksave." + UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Sugerencia DISCRETA (sin sonido) del monitor de portapapeles: «¿Guardar este enlace?».
    /// Al tocarla, el delegate emite `stacklumeSaveURL` con la URL.
    static func notifyClipboardSuggestion(url: String) async {
        guard await requestAuthorization() else { return }
        let content = UNMutableNotificationContent()
        content.title = "¿Guardar este enlace?"
        content.body = url.urlHost
        content.userInfo = ["saveURL": url]
        let request = UNNotificationRequest(
            identifier: "stacklume.clipsuggest." + UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Cancela el recordatorio de un enlace.
    static func cancel(id: UUID) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [prefix + id.uuidString])
    }
}

/// Maneja la interacción con las notificaciones de recordatorio.
/// Sin estado mutable: `@unchecked Sendable` es seguro.
final class ReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = ReminderNotificationDelegate()

    /// Muestra la notificación aunque la app esté en primer plano.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
    -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Al tocar la notificación: abre el enlace (recordatorio) o lo guarda (sugerencia de
    /// portapapeles), según el `userInfo`.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let idString = info["bookmarkID"] as? String, let id = UUID(uuidString: idString) {
            await MainActor.run { NotificationCenter.default.post(name: .stacklumeOpenBookmark, object: id) }
        } else if let url = info["saveURL"] as? String {
            await MainActor.run { NotificationCenter.default.post(name: .stacklumeSaveURL, object: url) }
        }
    }
}
