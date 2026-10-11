import Foundation
import SwiftData
import StacklumeCore

/// Backups AUTOMÁTICOS de la biblioteca (paridad con Raindrop, que respalda en la nube; aquí,
/// en local). Al arrancar, si han pasado ≥3 días desde el último, vuelca un export COMPLETO
/// (incluye adjuntos, texto OCR, resaltados/notas/recordatorios/progreso/portadas; ver
/// `CompleteBackupService`) a
/// `~/Library/Application Support/Stacklume/Backups/stacklume-YYYY-MM-DD.json` y conserva los
/// últimos 7. Opt-out en Ajustes › Datos.
@MainActor
enum AutoBackup {
    /// Clave de `@AppStorage` (opt-out; activado por defecto).
    static let enabledKey = "stacklume.autoBackup"
    private static let lastKey = "stacklume.autoBackup.last"
    private static let intervalDays = 3
    private static let keepCount = 7

    /// Carpeta de backups (creada si no existe).
    static func directory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Stacklume/Backups", isDirectory: true)
        try? PrivateFileIO.ensureDirectory(dir)
        return dir
    }

    /// Hace un backup si toca (≥3 días desde el último). Best-effort, silencioso.
    static func runIfNeeded(in context: ModelContext) {
        let on = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
        guard on else { return }
        // Nunca conviertas un arranque con store vacío/dañado en una copia «válida» que desplace
        // a las copias sanas. La recuperación del arranque puede ejecutarse en otra `.task`.
        let active = (try? context.fetchCount(FetchDescriptor<Bookmark>(
            predicate: #Predicate { $0.deletedAt == nil }))) ?? 0
        guard active > 0 else { return }
        if let last = UserDefaults.standard.object(forKey: lastKey) as? Date,
           Date().timeIntervalSince(last) < Double(intervalDays) * 86_400 { return }
        guard let data = try? CompleteBackupService.export(from: context) else { return }
        let url = directory().appendingPathComponent("stacklume-\(dateStamp()).json")
        do {
            try PrivateFileIO.write(data, to: url)
            LibraryResetIntent.didCreateNonemptyBackup()
            UserDefaults.standard.set(Date(), forKey: lastKey)
            prune()
        } catch {
            PersistenceLog.logger.error("Backup automático falló: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func dateStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// Conserva solo los `keepCount` backups más recientes.
    private static func prune() {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: directory(), includingPropertiesForKeys: [.creationDateKey])) ?? [])
            // La copia DIARIA ([[DailyBackup]], «stacklume-diario.json») NO se purga: es la red de
            // seguridad siempre presente. Solo se rotan los backups datados de cada 3 días.
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.contains("diario") }
        guard files.count > keepCount else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a > b
        }
        for old in sorted.dropFirst(keepCount) { try? FileManager.default.removeItem(at: old) }
    }
}
