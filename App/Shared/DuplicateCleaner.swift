import Foundation
import SwiftData
import StacklumeCore

/// Deduplicación de la biblioteca: fusión de datos y AUTOLIMPIEZA de duplicados por URL.
/// La idea (visión del usuario): no tiene sentido tener enlaces duplicados, así que se
/// limpian solos. Centraliza la lógica de fusión que también usa el gestor manual
/// (`DuplicatesView`) para no duplicar código.
@MainActor
enum DuplicateCleaner {

    /// AUTOLIMPIEZA: agrupa los enlaces activos por URL CANÓNICA ([[CanonicalURL]]) y, por
    /// cada grupo con más de uno, conserva el MÁS COMPLETO, funde en él los datos del
    /// resto (sin perder nada) y manda los demás a la papelera (restaurable). Solo por URL
    /// canónica —inequívocamente la misma página—; el contenido «parecido» se deja al
    /// gestor manual para no fusionar páginas distintas. Devuelve cuántos enlaces fusionó.
    @discardableResult
    static func autoMergeURLDuplicates(in context: ModelContext, force: Bool = false) -> Int {
        // Guarda barata (igual que SpotlightIndexer): si la biblioteca no cambió desde la
        // última pasada, NO rehagas el barrido completo + agrupación por URL en cada arranque.
        let signature = currentSignature(in: context)
        if !force, UserDefaults.standard.string(forKey: signatureKey) == signature { return 0 }

        let active = ((try? context.fetch(FetchDescriptor<Bookmark>())) ?? [])
            .filter { $0.deletedAt == nil && CanonicalURL.webBookmarkKey($0.url, fileKind: $0.fileKind) != nil }
        let groups = Dictionary(grouping: active) { CanonicalURL.key($0.url) }
            .filter { $0.value.count > 1 }
        guard !groups.isEmpty else {
            UserDefaults.standard.set(signature, forKey: signatureKey)   // nada que limpiar: recuérdalo
            return 0
        }

        var merged = 0
        var removedIDs: [UUID] = []
        var keptModified: [Bookmark] = []
        for (_, links) in groups {
            let sorted = links.sorted { $0.createdAt < $1.createdAt }   // empate → más antiguo
            let kept = sorted.reduce(sorted.first) { best, link in
                guard let best else { return link }
                return richness(link) > richness(best) ? link : best
            }
            guard let kept else { continue }
            for dup in sorted where dup.id != kept.id {
                merge(dup, into: kept)
                dup.deletedAt = Date()
                removedIDs.append(dup.id)
                merged += 1
            }
            kept.updatedAt = Date()
            keptModified.append(kept)
        }
        guard merged > 0 else {
            UserDefaults.standard.set(signature, forKey: signatureKey)
            return 0
        }
        context.saveLogging()
        removedIDs.forEach { SpotlightIndexer.remove(id: $0) }
        keptModified.forEach { SpotlightIndexer.index($0) }   // reindexa el fusionado
        WidgetReloader.reload()
        // El estado cambió (fusiones): recuerda la firma nueva para saltar la próxima pasada.
        UserDefaults.standard.set(currentSignature(in: context), forKey: signatureKey)
        return merged
    }

    private static let signatureKey = "stacklume.duplicateCleaner.signature"

    /// Firma barata de la biblioteca activa (recuento + `updatedAt` más reciente), para
    /// saltar el barrido completo si nada cambió desde la última autolimpieza.
    private static func currentSignature(in context: ModelContext) -> String {
        let activePredicate = #Predicate<Bookmark> { $0.deletedAt == nil }
        let count = (try? context.fetchCount(FetchDescriptor<Bookmark>(predicate: activePredicate))) ?? 0
        var descriptor = FetchDescriptor<Bookmark>(
            predicate: activePredicate,
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        let latest = (try? context.fetch(descriptor))?.first?.updatedAt ?? Date.distantPast
        return "\(count)-\(latest.timeIntervalSince1970)"
    }

    /// Funde el duplicado en el que se conserva SIN perder información: unión de etiquetas,
    /// conserva favorito/leído/recordatorio y rellena huecos (descripción, resumen, imagen,
    /// notas, colección, título). Compartida con el gestor manual de duplicados.
    static func merge(_ dup: Bookmark, into kept: Bookmark) {
        for tag in dup.tags where !kept.tags.contains(where: { $0.id == tag.id }) {
            kept.tags.append(tag)
        }
        kept.isFavorite = kept.isFavorite || dup.isFavorite
        kept.isRead = kept.isRead || dup.isRead
        if kept.reminderAt == nil { kept.reminderAt = dup.reminderAt }
        if (kept.details?.isEmpty ?? true), let d = dup.details, !d.isEmpty { kept.details = d }
        if (kept.summary?.isEmpty ?? true), let s = dup.summary, !s.isEmpty { kept.summary = s }
        if (kept.imageURL?.isEmpty ?? true), let i = dup.imageURL, !i.isEmpty { kept.imageURL = i }
        if (kept.notes?.isEmpty ?? true), let n = dup.notes, !n.isEmpty { kept.notes = n }
        if kept.category == nil { kept.category = dup.category }
        if kept.title.isEmpty || kept.title == kept.url.urlHost {
            if !dup.title.isEmpty, dup.title != dup.url.urlHost { kept.title = dup.title }
        }
    }

    /// Puntuación de «riqueza»: cuántos datos valiosos tiene un enlace. Se conserva el de
    /// mayor puntuación al fusionar (se pierde menos).
    static func richness(_ link: Bookmark) -> Int {
        var score = 0
        if link.isFavorite { score += 10 }
        if !(link.imageURL?.isEmpty ?? true) { score += 3 }
        if !(link.details?.isEmpty ?? true) { score += 2 }
        if !(link.notes?.isEmpty ?? true) { score += 2 }
        if !(link.summary?.isEmpty ?? true) { score += 1 }
        if link.category != nil { score += 1 }
        score += link.tags.count
        if !link.title.isEmpty, link.title != link.url.urlHost { score += 1 }
        return score
    }
}
