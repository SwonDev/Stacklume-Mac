import Foundation
import CoreSpotlight
import UniformTypeIdentifiers
import SwiftData
import StacklumeCore

/// Indexa los enlaces en Spotlight para que aparezcan en la búsqueda del sistema
/// de macOS. Al seleccionar un resultado, la app se abre en ese enlace.
@MainActor
enum SpotlightIndexer {
    static let domain = "com.swondev.stacklume.bookmark"

    /// Construye el item de Spotlight para un enlace.
    private static func item(
        for link: Bookmark,
        includePrivateContent: Bool
    ) -> CSSearchableItem {
        let contentType: UTType = switch link.fileKind {
        case "pdf": .pdf
        case "image": .image
        case "epub": .epub
        default: .url
        }
        let attributes = CSSearchableItemAttributeSet(contentType: contentType)
        attributes.title = link.title.isEmpty ? link.url : link.title
        if link.fileKind == nil { attributes.contentURL = URL(string: link.url) }
        attributes.identifier = link.id.uuidString

        // Metadatos básicos para mejorar la búsqueda. Colección y etiquetas solo se entregan
        // cuando el usuario ha mantenido activa la integración con Spotlight.
        var keywords = [link.platform.displayName]
        keywords.append(contentsOf: link.tags.map(\.name))
        if let category = link.category?.name { keywords.append(category) }
        attributes.keywords = keywords

        let host = URL(string: link.url)?.host() ?? "Stacklume"
        if includePrivateContent {
            let descriptionParts = [link.details, link.notes, host]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            attributes.contentDescription = descriptionParts.first ?? host
            // El texto completo solo sale al índice local tras opt-in explícito y se acota
            // para no entregar al sistema documentos desmesurados.
            if link.fileKind != nil, let offline = link.offlineText, !offline.isEmpty {
                attributes.textContent = String(offline.prefix(200_000))
            }
        } else {
            attributes.contentDescription = host
        }

        return CSSearchableItem(uniqueIdentifier: link.id.uuidString,
                                domainIdentifier: domain,
                                attributeSet: attributes)
    }

    /// Indexa o actualiza un único enlace.
    static func index(_ link: Bookmark) {
        guard StacklumeSpotlightPolicy.isEnabled() else {
            remove(id: link.id)
            return
        }
        guard link.deletedAt == nil else { remove(id: link.id); return }
        let includePrivateContent = StacklumeSpotlightPolicy.includesPrivateContent()
        CSSearchableIndex.default().indexSearchableItems([
            item(for: link, includePrivateContent: includePrivateContent)
        ])
    }

    /// Elimina un enlace del índice.
    static func remove(id: UUID) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [id.uuidString])
    }

    /// Vacía por completo el índice de la app (todo el dominio). Se usa al restablecer
    /// la aplicación, para que no queden resultados fantasma en la búsqueda del sistema.
    static func clearAll() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain])
        UserDefaults.standard.removeObject(forKey: signatureKey)
    }

    /// Clave en `UserDefaults` con la «firma» del último índice (recuento + fecha de la
    /// última modificación). Permite saltarse el reindexado completo si nada cambió.
    private static let signatureKey = "stacklume.spotlight.signature"

    /// Reindexa toda la biblioteca (al arrancar la app o tras importar). Optimizado para
    /// bibliotecas grandes: primero comprueba con DOS consultas baratas (recuento + el
    /// `updatedAt` más reciente) si la biblioteca cambió desde el último índice; si no,
    /// no hace NADA (antes recargaba toda la tabla y reconstruía miles de items en cada
    /// arranque, bloqueando el inicio). `force` ignora el guard (p. ej. tras importar).
    static func reindexAll(in context: ModelContext, force: Bool = false) {
        guard StacklumeSpotlightPolicy.isEnabled() else {
            clearAll()
            return
        }
        let activePredicate = #Predicate<Bookmark> { $0.deletedAt == nil }
        let count = (try? context.fetchCount(FetchDescriptor<Bookmark>(predicate: activePredicate))) ?? 0
        var latestDescriptor = FetchDescriptor<Bookmark>(
            predicate: activePredicate,
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        latestDescriptor.fetchLimit = 1
        latestDescriptor.propertiesToFetch = [\.updatedAt]
        let latest = (try? context.fetch(latestDescriptor))?.first?.updatedAt ?? Date.distantPast
        let privacy = StacklumeSpotlightPolicy.signatureFragment()
        let signature = "\(count)-\(latest.timeIntervalSince1970)-\(privacy)"
        if !force, UserDefaults.standard.string(forKey: signatureKey) == signature { return }

        let links = ((try? context.fetch(FetchDescriptor<Bookmark>())) ?? [])
            .filter { $0.deletedAt == nil }
        // Los items se construyen aquí, en el MainActor (item(for:) lee el Bookmark).
        let includePrivateContent = StacklumeSpotlightPolicy.includesPrivateContent()
        let items = links.map { item(for: $0, includePrivateContent: includePrivateContent) }
        // CSSearchableIndex serializa las operaciones en orden FIFO y `indexSearchableItems`
        // procesa en segundo plano (no bloquea), así que borrar y reindexar secuencial es seguro.
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain])
        index.indexSearchableItems(items)
        UserDefaults.standard.set(signature, forKey: signatureKey)
    }
}
