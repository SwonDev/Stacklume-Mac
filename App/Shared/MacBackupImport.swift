import Foundation
import SwiftData
import StacklumePersistence

/// Las entradas manuales y de recuperación comparten esta validación previa a la fusión.
@MainActor
enum MacBackupImport {
    static func merge(_ data: Data, into context: ModelContext) throws -> BackupService.MergeResult {
        try ImportSafety.validateBackup(data)
        try CompleteBackupService.validateForImport(data)
        return try BackupService.merge(data, into: context)
    }
}
