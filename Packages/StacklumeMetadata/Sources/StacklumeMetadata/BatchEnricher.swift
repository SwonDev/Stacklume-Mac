import Foundation
import SwiftData
import StacklumeCore

/// Enriquece en lote los enlaces de la biblioteca (metadatos + auto-etiquetas +
/// auto-categoría). Útil tras importar o para completar enlaces guardados sin
/// metadatos. Secuencial para no saturar la red ni el contexto.
@MainActor
public enum BatchEnricher {

    /// Un enlace necesita enriquecimiento si le faltan metadatos clave.
    public static func needsEnrichment(_ link: Bookmark) -> Bool {
        link.platform == .generic
            || link.imageURL?.isEmpty != false
            || link.siteName?.isEmpty != false
            || link.title.isEmpty
            || link.title.lowercased() == host(of: link.url)
            // Repos de GitHub aún sin estrellas/forks.
            || (link.platform == .github && link.repoInfo == nil)
    }

    /// - Parameter pauseIfBusy: gancho OPCIONAL que se invoca al inicio de cada iteración. La app
    ///   lo usa para CEDER el paso mientras el usuario está interactuando (scroll/teclado): así el
    ///   enriquecido de red —que escribe en SwiftData e invalida la lista— no entrecorta la UI.
    ///   `nil` (por defecto, p. ej. iPhone) = sin pausa, comportamiento idéntico al anterior.
    /// - Parameter shouldSkip: la app marca aquí los enlaces que YA se intentaron enriquecer por
    ///   red (libro mayor), para que el barrido AUTOMÁTICO no reprocese los mismos enlaces
    ///   incompletos cada vez (re-`autoOrganize` + escritura → invalida el @Query). `force` lo ignora.
    /// - Parameter onProcessed: se invoca tras procesar cada enlace, para que la app lo marque.
    @discardableResult
    public static func enrich(
        in context: ModelContext,
        force: Bool = false,
        limit: Int = 300,
        pauseIfBusy: (@MainActor () async -> Void)? = nil,
        shouldSkip: (@MainActor (Bookmark) -> Bool)? = nil,
        onProcessed: (@MainActor (Bookmark) -> Void)? = nil,
        onProgress: @MainActor (Int, Int) -> Void = { _, _ in }
    ) async -> Int {
        let all = (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
        let pending = all.filter {
            $0.deletedAt == nil
                && (force || (needsEnrichment($0) && !(shouldSkip?($0) ?? false)))
        }
        let slice = Array(pending.prefix(limit))

        // Reglas de clasificación del usuario (se aplican tras enriquecer cada enlace).
        let rules = (try? context.fetch(FetchDescriptor<ClassificationRule>())) ?? []
        let categories = (try? context.fetch(FetchDescriptor<BookmarkCategory>())) ?? []
        let tags = (try? context.fetch(FetchDescriptor<Tag>())) ?? []

        var done = 0
        for link in slice {
            if Task.isCancelled { break }
            if let pauseIfBusy { await pauseIfBusy() }   // cede mientras el usuario interactúa
            if Task.isCancelled { break }
            // El modelo pudo invalidarse/eliminarse entre iteraciones (presión de
            // memoria de SwiftData con miles de enlaces, o borrado concurrente).
            guard link.modelContext != nil, link.deletedAt == nil else { continue }
            let overwriteTitle = link.title.isEmpty || link.title == host(of: link.url)
            await LinkEnricher.enrichFromNetwork(link, in: context, overwriteTitle: overwriteTitle)
            if !rules.isEmpty {
                ClassificationEngine.apply(to: link, rules: rules, categories: categories, tags: tags)
            }
            // Marca como ya intentado (red) aunque siga incompleto: el barrido automático NO lo
            // reprocesará en la próxima ronda. El redo es manual (`force`).
            if link.modelContext != nil { onProcessed?(link) }
            done += 1
            onProgress(done, slice.count)
        }
        try? context.save()
        return done
    }

    private static func host(of urlString: String) -> String {
        let value = urlString.contains("://") ? urlString : "https://" + urlString
        let host = URL(string: value)?.host()?.lowercased() ?? urlString.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
