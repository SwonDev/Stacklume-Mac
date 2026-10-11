#if DEBUG
import Foundation
import SwiftData
import StacklumeCore

/// Generador de datos de PRUEBA (solo en builds de desarrollo) para medir el
/// rendimiento con miles de enlaces. Marca cada enlace con `source == marker` para
/// poder borrarlos todos sin tocar los reales. NO se compila en release (#if DEBUG).
@MainActor
public enum TestDataGenerator {
    /// Marca para reconocer y borrar los enlaces de prueba.
    public static let marker = "stacklume-test-data"

    private static let words = [
        "swift", "diseño", "render", "pipeline", "async", "actor", "gradiente",
        "neuronal", "caché", "layout", "testing", "metal", "embeddings",
        "productividad", "minimalismo", "arquitectura", "concurrencia", "animación",
        "accesibilidad", "rendimiento", "compilador", "memoria", "índice", "semántica",
        "widget", "fotografía", "tipografía", "color", "vector", "documentación"
    ]
    private static let domains = [
        "github.com", "medium.com", "youtube.com", "dribbble.com", "developer.apple.com",
        "arxiv.org", "news.ycombinator.com", "reddit.com", "stackoverflow.com",
        "figma.com", "css-tricks.com", "smashingmagazine.com"
    ]
    /// Paleta local (el paquete no depende de ColorPresets, que vive en el target App).
    private static let palette = [
        "#D4A853", "#F05138", "#FF6B6B", "#34D399", "#4ECDC4",
        "#0066FF", "#7AA2F7", "#C8A8FF", "#A259FF", "#1DB954"
    ]

    /// Nº de enlaces de prueba actualmente en la biblioteca.
    public static func count(in context: ModelContext) -> Int {
        let all = (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
        return all.filter { $0.source == marker }.count
    }

    /// Inserta `count` enlaces de prueba variados (categorías, etiquetas, tipos,
    /// favoritos, leídos…) para que el filtrado/búsqueda/semántica tengan datos reales.
    public static func generate(count: Int, in context: ModelContext) async {
        let cats = ensureCategories(in: context)
        let tags = ensureTags(in: context)
        let types = ContentType.allCases
        let platforms: [Platform] = [.generic, .github, .youtube, .dribbble]
        let base = (try? context.fetchCount(FetchDescriptor<Bookmark>())) ?? 0

        for i in 0..<count {
            let w1 = words[i % words.count]
            let w2 = words[(i / words.count + 3) % words.count]
            let domain = domains[i % domains.count]
            let bm = Bookmark(
                url: "https://\(domain)/\(marker)/\(i)-\(w1)-\(w2)",
                title: "\(w1.capitalized) \(w2) #\(i)",
                details: "Enlace de prueba sobre \(w1) y \(w2) para medir rendimiento a escala.",
                category: i % 4 == 0 ? nil : cats[i % cats.count],
                tags: i % 3 == 0 ? [] : [tags[i % tags.count], tags[(i + 2) % tags.count]],
                isFavorite: i % 11 == 0,
                platform: platforms[i % platforms.count],
                contentType: types[i % types.count],
                order: base + i)
            bm.source = marker
            bm.siteName = domain
            bm.isRead = i % 5 == 0
            context.insert(bm)
            if i % 500 == 499 {
                try? context.save()      // guarda por lotes
                await Task.yield()       // cede el hilo para no congelar la UI
            }
        }
        try? context.save()
    }

    /// Borra TODOS los enlaces de prueba (los reales no se tocan). Devuelve cuántos.
    @discardableResult
    public static func deleteAll(in context: ModelContext) -> Int {
        let all = (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
        let test = all.filter { $0.source == marker }
        for bm in test { context.delete(bm) }
        try? context.save()
        return test.count
    }

    /// Reutiliza las categorías existentes o crea un set variado si hay pocas.
    private static func ensureCategories(in context: ModelContext) -> [BookmarkCategory] {
        var cats = ((try? context.fetch(FetchDescriptor<BookmarkCategory>())) ?? [])
            .filter { $0.deletedAt == nil }
        let extra = ["Tecnología", "Investigación", "Recursos", "Marketing", "Personal", "Trabajo"]
        for (idx, name) in extra.enumerated() where !cats.contains(where: { $0.name == name }) {
            let c = BookmarkCategory(name: name, icon: "folder.fill",
                                     colorHex: palette[idx % palette.count], order: cats.count)
            context.insert(c)
            cats.append(c)
        }
        return cats.isEmpty ? [] : cats
    }

    private static func ensureTags(in context: ModelContext) -> [Tag] {
        var tags = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        let extra = ["iOS", "macOS", "UX", "UI", "Open Source", "Paper", "Vídeo", "Guía", "Idea", "Referencia"]
        for (idx, name) in extra.enumerated() where !tags.contains(where: { $0.name == name }) {
            let t = Tag(name: name, colorHex: palette[(idx + 4) % palette.count], order: tags.count)
            context.insert(t)
            tags.append(t)
        }
        return tags
    }
}
#endif
