import Foundation
import SwiftData
import StacklumeCore
import StacklumePersistence

/// Recuperación ANTE DESASTRE. Si la app arranca con la biblioteca VACÍA pero existe una copia de
/// seguridad reciente CON enlaces (p. ej. tras un crash que dejó el store de SwiftData inservible),
/// restaura automáticamente la última copia al instante. Reutiliza la MISMA lógica probada que
/// «Importar desde JSON» (`BackupService.merge` + `CompleteBackupService.restoreExtras`) y la MISMA
/// carpeta que [[AutoBackup]]. Añadido tras perder el usuario la biblioteca por un crash (2026-06-28).
@MainActor
enum BackupRecovery {
    /// Huella del último backup restaurado automáticamente: evita re-restaurar la MISMA revisión si
    /// vacías la biblioteca a propósito, pero permite recuperar una revisión nueva del archivo diario.
    private static let lastRestoredKey = "stacklume.lastAutoRestoredBackup"

    /// La copia `.json` más reciente que sea válida y contenga al menos un enlace. Si la más nueva
    /// está vacía/corrupta, retrocede a la siguiente copia sana en vez de abandonar la recuperación.
    static func latestBackupURL() -> URL? {
        let dir = AutoBackup.directory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let candidates = files.filter { $0.pathExtension.lowercased() == "json" }.sorted { a, b in
            modificationDate(of: a) > modificationDate(of: b)
        }
        return candidates.first { url in
            guard let data = try? BoundedFileReader.read(
                url,
                maximumBytes: 256 * 1_024 * 1_024
            ) else { return false }
            guard (try? ImportSafety.validateBackup(data)) != nil,
                  (try? CompleteBackupService.validateForImport(data)) != nil else { return false }
            return (BackupArchiveInspector.linkCount(in: data) ?? 0) > 0
        }
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    /// Nombre + tamaño + fecha de modificación. El archivo diario conserva el nombre, pero no la
    /// huella cuando se sobrescribe con una copia nueva.
    private static func fingerprint(of url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(url.lastPathComponent)|\(values?.fileSize ?? 0)|\(stamp)"
    }

    /// Si la biblioteca está VACÍA y hay un backup con enlaces, restaura la última copia. Solo una vez
    /// por backup (no re-restaura el mismo si lo vaciaste a propósito). Devuelve cuántos enlaces se
    /// restauraron (0 si no hizo nada). Best-effort: nunca lanza ni rompe el arranque.
    @discardableResult
    static func restoreIfEmpty(in context: ModelContext) -> Int {
        guard !LibraryResetIntent.preventsAutomaticRecovery() else { return 0 }
        let count = (try? context.fetchCount(FetchDescriptor<Bookmark>(
            predicate: #Predicate { $0.deletedAt == nil }))) ?? 0
        guard count == 0 else { return 0 }                       // hay enlaces → no tocar
        guard let url = latestBackupURL() else { return 0 }
        let fingerprint = fingerprint(of: url)
        if let previous = UserDefaults.standard.string(forKey: lastRestoredKey) {
            guard previous != fingerprint else { return 0 }
            // Migración desde la versión antigua, que solo guardaba el nombre del archivo.
            if previous == url.lastPathComponent {
                UserDefaults.standard.set(fingerprint, forKey: lastRestoredKey)
                return 0
            }
        }
        guard let data = try? BoundedFileReader.read(
                  url,
                  maximumBytes: 256 * 1_024 * 1_024
              ),
              let result = try? MacBackupImport.merge(data, into: context), result.addedLinks > 0 else { return 0 }
        let extras = CompleteBackupService.restoreExtras(from: data, in: context)
        markAllAsEnriched(in: context)
        context.saveLogging()
        UserDefaults.standard.set(fingerprint, forKey: lastRestoredKey)
        return result.addedLinks + extras.createdLinks
    }

    /// Marca TODOS los enlaces activos como «ya intentados» en los 4 libros mayores ([[EnrichmentLedger]]).
    /// Tras restaurar una biblioteca COMPLETA desde un backup (que YA viene enriquecida), evita que el
    /// barrido de fondo re-enriquezca cientos de enlaces a la vez y sature la GPU (la app se quedaba
    /// inusable: 100 %+ de CPU, lentísima al pasar a primer plano). El usuario lo sufrió el 2026-06-28.
    /// Si algún enlace concreto necesita rehacerse, «Mejorar con IA» (force) ignora el libro mayor.
    static func markAllAsEnriched(in context: ModelContext) {
        let links = (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
        for link in links where link.deletedAt == nil {
            EnrichmentLedger.markAIAttempt(link.id)
            EnrichmentLedger.markNetworkAttempt(link.id)
            EnrichmentLedger.markCoverAttempt(link.id)
            EnrichmentLedger.markCompleterAttempt(link.id)
        }
    }

    /// Restauración MANUAL de la última copia (para un botón en Ajustes › Datos), SIN el control de
    /// «una vez»: el usuario lo pide explícitamente. Es ADITIVA (no borra lo que ya haya).
    @discardableResult
    static func restoreLatest(in context: ModelContext) -> Int {
        guard let url = latestBackupURL(),
              let data = try? BoundedFileReader.read(
                  url,
                  maximumBytes: 256 * 1_024 * 1_024
              ),
              let result = try? MacBackupImport.merge(data, into: context) else { return 0 }
        let extras = CompleteBackupService.restoreExtras(from: data, in: context)
        markAllAsEnriched(in: context)
        context.saveLogging()
        return result.addedLinks + extras.createdLinks
    }
}
