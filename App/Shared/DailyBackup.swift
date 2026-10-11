import Foundation
import SwiftData
import StacklumeCore

/// Copia de seguridad DIARIA a una hora elegida por el usuario, que SOBRESCRIBE la del día anterior
/// (un único archivo `stacklume-diario.json` siempre actualizado). Complementa —no sustituye— a
/// [[AutoBackup]] (cada 3 días, datados, conserva 7) y al export manual. Blindaje extra pedido por el
/// usuario (2026-06-28) tras un crash que vació el store: cuantas más redes de seguridad, mejor.
/// Export COMPLETO (con adjuntos, texto OCR, resaltados/notas/recordatorios/progreso/portadas)
/// vía [[CompleteBackupService]].
@MainActor
enum DailyBackup {
    /// Opt-out (activado por defecto).
    static let enabledKey = "stacklume.dailyBackup.enabled"
    /// Hora del día como MINUTOS desde medianoche (p. ej. 9:00 = 540). Default 9:00.
    static let minuteOfDayKey = "stacklume.dailyBackup.minuteOfDay"
    private static let lastRunKey = "stacklume.dailyBackup.lastRun"
    static let defaultMinuteOfDay = 9 * 60

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var minuteOfDay: Int { UserDefaults.standard.object(forKey: minuteOfDayKey) as? Int ?? defaultMinuteOfDay }

    /// Ruta FIJA de la copia diaria (se sobrescribe cada día). En la misma carpeta que [[AutoBackup]],
    /// con un nombre que su `prune` ignora (contiene «diario»), para que nunca se purgue.
    static func fileURL() -> URL {
        AutoBackup.directory().appendingPathComponent("stacklume-diario.json")
    }

    /// Hace la copia diaria si toca: activada, ya pasó la hora configurada hoy y aún no se hizo hoy.
    /// Best-effort y silenciosa. La llama el arranque y un temporizador periódico mientras la app vive.
    static func runIfDue(in context: ModelContext) {
        guard isEnabled else { return }
        guard hasActiveLinks(in: context) else { return }
        let cal = Calendar.current
        let now = Date()
        // ¿ya se hizo hoy? (una vez al día)
        if let last = UserDefaults.standard.object(forKey: lastRunKey) as? Date, cal.isDateInToday(last) { return }
        // ¿ya pasó la hora configurada hoy?
        let comps = cal.dateComponents([.hour, .minute], from: now)
        let nowMinutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        guard nowMinutes >= minuteOfDay else { return }
        guard let data = try? CompleteBackupService.export(from: context) else { return }
        do {
            try PrivateFileIO.write(data, to: fileURL())   // sobrescribe la del día anterior
            LibraryResetIntent.didCreateNonemptyBackup()
            UserDefaults.standard.set(now, forKey: lastRunKey)
        } catch {
            PersistenceLog.logger.error("Copia diaria falló: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Genera la copia diaria AHORA mismo (botón «Hacer copia ahora» de Ajustes). Devuelve si lo logró.
    @discardableResult
    static func runNow(in context: ModelContext) -> Bool {
        guard hasActiveLinks(in: context) else { return false }
        guard let data = try? CompleteBackupService.export(from: context) else { return false }
        do {
            try PrivateFileIO.write(data, to: fileURL())
            LibraryResetIntent.didCreateNonemptyBackup()
            UserDefaults.standard.set(Date(), forKey: lastRunKey)
            return true
        } catch { return false }
    }

    private static func hasActiveLinks(in context: ModelContext) -> Bool {
        let count = (try? context.fetchCount(FetchDescriptor<Bookmark>(
            predicate: #Predicate { $0.deletedAt == nil }))) ?? 0
        return count > 0
    }
}
