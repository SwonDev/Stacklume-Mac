import Foundation

/// Identidad mínima de un enlace dentro de una copia de seguridad.
///
/// Se mantiene libre de SwiftData para poder validar archivos antes de tocar el store y para
/// cubrir la lógica de recuperación con tests unitarios rápidos.
struct BackupLinkIdentity: Decodable, Sendable, Equatable {
    let id: UUID
    let url: String
}

/// Inspección tolerante del formato base de `BackupService`.
enum BackupArchiveInspector {
    private struct Archive: Decodable {
        let links: [BackupLinkIdentity]
    }

    /// Enlaces contenidos en una copia válida; `nil` si el JSON está corrupto o no es una copia.
    static func links(in data: Data) -> [BackupLinkIdentity]? {
        try? JSONDecoder().decode(Archive.self, from: data).links
    }

    /// Número de enlaces de una copia válida; distingue «vacía» (`0`) de «inválida» (`nil`).
    static func linkCount(in data: Data) -> Int? {
        links(in: data)?.count
    }

    /// Traduce los UUID del archivo a los UUID efectivos del store tras `BackupService.merge`.
    /// La fusión crea UUID nuevos y omite URLs ya presentes, por lo que no se puede restaurar
    /// información lateral buscando directamente el UUID original.
    static func localIDMap(
        from data: Data,
        localLinks: [BackupLinkIdentity]
    ) -> [UUID: UUID] {
        guard let remoteLinks = links(in: data) else { return [:] }

        // Primero replica la igualdad de URL usada por BackupService.merge. La clave canónica es
        // la reserva para copias antiguas o URLs equivalentes con www/esquema/tracking distintos.
        let exact = Dictionary(
            localLinks.map { (exactURLKey($0.url), $0.id) },
            uniquingKeysWith: { first, _ in first })
        let canonical = Dictionary(
            localLinks.map { (CanonicalURL.key($0.url), $0.id) },
            uniquingKeysWith: { first, _ in first })

        var result: [UUID: UUID] = [:]
        result.reserveCapacity(remoteLinks.count)
        for remote in remoteLinks {
            // Los adjuntos locales comparten URL vacía. Asociarlos por URL haría que todos
            // apuntaran al primer documento y mezclaría recordatorios/resaltados/portadas.
            // `CompleteBackupService` los identifica por su payload y completa este mapa.
            guard !remote.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if let localID = exact[exactURLKey(remote.url)] ?? canonical[CanonicalURL.key(remote.url)] {
                result[remote.id] = localID
            }
        }
        return result
    }

    private static func exactURLKey(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
