import Foundation
import SwiftData
import StacklumeCore

/// Aplica metadatos y organización automática (auto-etiquetas y auto-categoría)
/// a un `Bookmark`, creando las etiquetas y categorías que falten. Lo usan el
/// editor y la Share Extension para que guardar un enlace sea rico "out of the box".
@MainActor
public enum LinkEnricher {

    /// Vuelca los metadatos obtenidos en el bookmark (sin pisar lo que el usuario
    /// ya haya escrito a mano en título/descripción si no hay valor nuevo).
    public static func applyMetadata(_ metadata: LinkMetadata, to bookmark: Bookmark, overwriteTitle: Bool) {
        if overwriteTitle || bookmark.title.trimmingCharacters(in: .whitespaces).isEmpty {
            if let title = metadata.title, !title.isEmpty { bookmark.title = title }
        }
        if let details = metadata.details, bookmark.details?.isEmpty != false { bookmark.details = details }
        if let image = metadata.imageURL { bookmark.imageURL = image }
        if let favicon = metadata.faviconURL { bookmark.faviconURL = favicon }
        if let site = metadata.siteName { bookmark.siteName = site }
        if let author = metadata.author { bookmark.author = author }
        bookmark.platform = metadata.platform
        bookmark.contentType = metadata.contentType
        bookmark.platformColor = metadata.platformColor
        if !metadata.keywords.isEmpty { bookmark.semanticTags = metadata.keywords }
        bookmark.updatedAt = Date()
    }

    /// Asigna automáticamente etiquetas y categoría, creando las que no existan.
    public static func autoOrganize(
        _ bookmark: Bookmark,
        in context: ModelContext,
        autoTags: Bool = true,
        autoCategory: Bool = true
    ) {
        // Si el modelo fue invalidado/eliminado (p. ej. durante un await de red previo,
        // o por presión de memoria de SwiftData en bibliotecas muy grandes), NO accedas
        // a sus propiedades persistidas: abortaría con un _assertionFailure de SwiftData.
        guard bookmark.modelContext != nil else { return }
        if autoTags {
            var names = AutoTagger.tags(
                platform: bookmark.platform, contentType: bookmark.contentType,
                title: bookmark.title, url: bookmark.url)
            // Añade hasta 3 etiquetas de las keywords del paquete (npm/PyPI/cargo).
            names.append(contentsOf: keywordTags(from: bookmark.semanticTags, excluding: names))
            let existing = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
            for name in names {
                if let match = existing.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    if !bookmark.tags.contains(where: { $0.id == match.id }) { bookmark.tags.append(match) }
                } else if !bookmark.tags.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    let tag = Tag(name: name, colorHex: color(for: name), order: existing.count)
                    context.insert(tag)
                    bookmark.tags.append(tag)
                }
            }
        }

        // Garantiza que SIEMPRE haya favicon (fallback de Google si falta).
        if bookmark.faviconURL?.isEmpty != false {
            bookmark.faviconURL = FaviconProvider.googleFavicon(forURL: bookmark.url)
        }

        if autoCategory, bookmark.category == nil,
           let suggestion = AutoCategorizer.suggestion(contentType: bookmark.contentType, platform: bookmark.platform) {
            let existing = (try? context.fetch(FetchDescriptor<BookmarkCategory>())) ?? []
            if let match = existing.first(where: { $0.name.caseInsensitiveCompare(suggestion.name) == .orderedSame }) {
                bookmark.category = match
            } else {
                let category = BookmarkCategory(name: suggestion.name, icon: suggestion.icon,
                                                colorHex: suggestion.colorHex, order: existing.count)
                context.insert(category)
                bookmark.category = category
            }
        }
    }

    /// Flujo completo: obtiene metadatos de la red y organiza el bookmark.
    public static func enrichFromNetwork(
        _ bookmark: Bookmark,
        in context: ModelContext,
        overwriteTitle: Bool = false
    ) async {
        // El modelo puede invalidarse durante los `await` (presión de memoria de
        // SwiftData a gran escala, o borrado concurrente). Tras cada suspensión se
        // verifica que sigue vivo (`modelContext != nil`) antes de tocar propiedades
        // persistidas; si no, se aborta limpiamente (evita el _assertionFailure).
        guard bookmark.modelContext != nil else { return }
        let url = bookmark.url
        let metadata = await MetadataService().fetchMetadata(for: url)
        guard bookmark.modelContext != nil else { return }
        applyMetadata(metadata, to: bookmark, overwriteTitle: overwriteTitle)
        // Enriquecimiento específico de plataforma (GitHub: estrellas/forks/lenguaje;
        // X/Twitter: autor y texto del tweet).
        await PlatformEnricher.enrich(bookmark)
        guard bookmark.modelContext != nil else { return }
        autoOrganize(bookmark, in: context)
        try? context.save()
    }

    private static let palette = [
        "#D4A853", "#F05138", "#FF6B6B", "#FF8C42", "#34D399", "#4ECDC4",
        "#0066FF", "#7AA2F7", "#C8A8FF", "#A259FF", "#FF4FA3", "#1DB954"
    ]

    private static func color(for name: String) -> String {
        let count = palette.count
        let index = ((name.lowercased().hashValue % count) + count) % count
        return palette[index]
    }

    /// Convierte las keywords de un paquete en nombres de etiqueta limpios (palabra
    /// simple de 2–20 caracteres), capitalizando la inicial, sin duplicar las que ya
    /// genera el autotagger. Máximo `limit`.
    private static func keywordTags(from keywords: [String], excluding existing: [String], limit: Int = 3) -> [String] {
        var result: [String] = []
        for raw in keywords {
            guard result.count < limit else { break }
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.count >= 2, clean.count <= 20,
                  clean.range(of: #"^[\w.\-]+$"#, options: .regularExpression) != nil else { continue }
            let nice = clean.first!.isLowercase ? clean.prefix(1).uppercased() + clean.dropFirst() : clean
            if existing.contains(where: { $0.caseInsensitiveCompare(nice) == .orderedSame }) { continue }
            if result.contains(where: { $0.caseInsensitiveCompare(nice) == .orderedSame }) { continue }
            result.append(nice)
        }
        return result
    }
}
