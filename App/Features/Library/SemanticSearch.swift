import Foundation
import SwiftUI
import StacklumeCore
import StacklumeDesignSystem

/// Conexiones, duplicados y grupos temáticos derivados del índice multimodal privado.
/// Conserva las señales explicables de etiquetas, dominio y colección.
@MainActor
enum SemanticSearch {
    /// Resultado enriquecido para explicar una conexión en la interfaz. La similitud no
    /// es una «caja negra»: el usuario puede ver qué señales concretas la sostienen.
    struct RelatedMatch: Identifiable {
        let link: Bookmark
        let score: Double
        let sharedTagCount: Int
        let sameDomain: Bool
        let sameCategory: Bool
        let samePlatform: Bool
        let semanticSimilarity: Double

        var id: UUID { link.id }

        /// Intensidad 0…1 usada únicamente para el grosor/opacidad de la arista.
        var strength: Double { ConnectionMapLayout.normalizedStrength(score: score) }

        var explanation: String {
            var reasons: [String] = []
            if sharedTagCount == 1 { reasons.append("1 etiqueta compartida") }
            if sharedTagCount > 1 { reasons.append("\(sharedTagCount) etiquetas compartidas") }
            if semanticSimilarity >= 0.55 { reasons.append("tema muy similar") }
            else if semanticSimilarity >= 0.35 { reasons.append("tema relacionado") }
            if sameDomain { reasons.append("mismo sitio") }
            if sameCategory { reasons.append("misma colección") }
            if samePlatform { reasons.append("misma plataforma") }
            return reasons.isEmpty ? "Relación semántica local" : reasons.joined(separator: " · ")
        }
    }

    private static var vectorCache: [UUID: (stamp: Date, vector: [Double])] = [:]
    private static var cacheRevision: UInt?
    private static var cacheTask = "document"

    /// Metadatos LIGEROS de un enlace para `related` (etiquetas/dominio/categoría/plataforma).
    /// Cacheados por UUID e invalidados por `updatedAt`. Evitan RE-FAULTEAR la relación `.tags`
    /// (y `.category`) de CIENTOS de enlaces en CADA clic de la ficha —eso bloqueaba el hilo
    /// principal mientras cargaba la sección «relacionados»—. NO dependen del idioma del embedding.
    private struct LinkMeta { let stamp: Date; let tagKeys: Set<String>; let host: String
        let catID: UUID?; let platform: Platform }
    private static var metaCache: [UUID: LinkMeta] = [:]

    /// Metadatos del enlace: del caché si están vigentes; si no, los calcula (faulta `.tags` UNA
    /// vez) y los cachea. Así el cálculo de relacionados deja de faultear cientos de relaciones
    /// en cada selección: tras la primera vez de cada enlace, es lectura en memoria.
    private static func meta(for link: Bookmark) -> LinkMeta {
        if let m = metaCache[link.id], m.stamp == link.updatedAt { return m }
        let m = LinkMeta(stamp: link.updatedAt, tagKeys: tagKeys(of: link),
                         host: link.url.urlHost, catID: link.category?.id, platform: link.platform)
        metaCache[link.id] = m
        return m
    }

    private static func ensureCacheRevision() {
        let revision = MultimodalSearchService.shared.revision
        if cacheRevision != revision {
            vectorCache.removeAll()
            cacheRevision = revision
        }
    }

    static func isAvailable(language: String) -> Bool { true }

    /// Enlaces REALMENTE relacionados con `link` (excluyéndolo). Antes era solo coseno de
    /// embeddings con umbral bajo (0.30): con esos vectores casi cualquier enlace del mismo
    /// dominio amplio (tecnología) «parecía» relacionado y salían enlaces sin relación real.
    ///
    /// Ahora exige una RELACIÓN CONCRETA y rankea con una puntuación híbrida (las señales
    /// duras pesan más que el coseno difuso). Un enlace entra SOLO si:
    ///   · comparte alguna ETIQUETA (manual o semántica) con el objetivo, o
    ///   · es del MISMO dominio, o
    ///   · misma CATEGORÍA **y** similitud semántica media (≥0.35), o
    ///   · similitud semántica ALTA (≥0.55).
    /// Si nada cumple, la sección queda vacía (mejor vacío que aleatorio). Funciona aunque
    /// NO haya embeddings (cae a etiquetas/dominio/categoría), así nunca depende solo del coseno.
    static func related(to link: Bookmark, in links: [Bookmark], language: String,
                        limit: Int = 6) -> [Bookmark] {
        relatedMatches(to: link, in: links, language: language, limit: limit).map(\.link)
    }

    /// Variante explicable de `related`: conserva las señales y la fuerza de cada arista
    /// para que «Conexiones» pueda representar y justificar el grafo sin recalcularlo.
    static func relatedMatches(to link: Bookmark, in links: [Bookmark], language: String,
                               limit: Int = 6) -> [RelatedMatch] {
        // Metadatos del objetivo desde el caché (sin re-faultear la relación `.tags`).
        let targetMeta = meta(for: link)
        let targetTags = targetMeta.tagKeys
        let targetCat = targetMeta.catID
        let targetHost = targetMeta.host
        let targetPlatform = targetMeta.platform

        // Vector multimodal del índice privado; nunca se mezcla con NLEmbedding.
        ensureCacheRevision()
        let targetVec = vectorCache[link.id]?.vector

        var scored: [RelatedMatch] = []
        for other in links where other.id != link.id && other.deletedAt == nil {
            // Señales concretas (metadatos cacheados: no se faulta `.tags`/`.category` en cada clic).
            let om = meta(for: other)
            let sharedTags = targetTags.intersection(om.tagKeys)
            let sameCategory = targetCat != nil && om.catID == targetCat
            let sameHost = !targetHost.isEmpty && om.host == targetHost
            let samePlatform = targetPlatform != .generic && om.platform == targetPlatform
            // Señal semántica (0 si falta el vector de alguno).
            var sem = 0.0
            if let tv = targetVec, let c = vectorCache[other.id], c.stamp == other.updatedAt {
                sem = cosine(tv, c.vector)
            }
            // Verja de RELACIÓN REAL.
            let related = !sharedTags.isEmpty || sameHost || (sameCategory && sem >= 0.35) || sem >= 0.55
            guard related else { continue }
            // Puntuación: las señales duras dominan; el coseno refina el orden.
            var score = Double(sharedTags.count) * 0.6
            if sameHost { score += 0.5 }
            if sameCategory { score += 0.25 }
            if samePlatform { score += 0.15 }
            score += sem * 0.8
            scored.append(RelatedMatch(
                link: other,
                score: score,
                sharedTagCount: sharedTags.count,
                sameDomain: sameHost,
                sameCategory: sameCategory,
                samePlatform: samePlatform,
                semanticSimilarity: sem
            ))
        }
        return Array(scored.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.link.updatedAt != $1.link.updatedAt { return $0.link.updatedAt > $1.link.updatedAt }
            return $0.link.id.uuidString < $1.link.id.uuidString
        }.prefix(limit))
    }

    /// Conjunto de claves de etiqueta de un enlace (manuales + semánticas), normalizadas
    /// (minúsculas, sin tildes) para comparar sin distinguir grafía.
    private static func tagKeys(of link: Bookmark) -> Set<String> {
        var keys = Set<String>()
        for t in link.tags { keys.insert(normalizeKey(t.name)) }
        for t in link.semanticTags { keys.insert(normalizeKey(t)) }
        keys.remove("")
        return keys
    }

    private static func normalizeKey(_ s: String) -> String {
        s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Agrupa enlaces con CONTENIDO casi idéntico (la misma noticia/artículo guardado en
    /// URLs distintas, o variantes amp/http/https) por ALTA similitud coseno. Clustering
    /// voraz por semilla. Requiere vectores ya calculados por `warm()`. Umbral alto (0.93)
    /// para no juntar artículos solo «parecidos». Algo que Raindrop no hace (solo URL exacta).
    static func duplicateClusters(in links: [Bookmark], language: String,
                                  threshold: Double = 0.93, maxLinks: Int = 1000) -> [[Bookmark]] {
        guard links.count > 1 else { return [] }
        ensureCacheRevision()
        let items: [(link: Bookmark, vec: [Double])] = links.prefix(maxLinks).compactMap { link in
            guard let c = vectorCache[link.id], c.stamp == link.updatedAt else { return nil }
            return (link, c.vector)
        }
        var used = Set<Int>()
        var clusters: [[Bookmark]] = []
        for i in items.indices where !used.contains(i) {
            var cluster = [items[i].link]
            for j in items.indices where j > i && !used.contains(j) {
                if cosine(items[i].vec, items[j].vec) >= threshold {
                    cluster.append(items[j].link)
                    used.insert(j)
                }
            }
            if cluster.count > 1 { used.insert(i); clusters.append(cluster) }
        }
        return clusters.sorted { $0.count > $1.count }
    }

    /// Agrupa enlaces por TEMA (no por duplicado): clustering voraz por semilla con umbral
    /// MEDIO y tamaño mínimo. A diferencia de `duplicateClusters` (0.93, casi idénticos),
    /// junta enlaces del MISMO ASUNTO para proponer colecciones automáticas («tienes 12 de
    /// React» → colección React). Requiere vectores ya calculados por `warm()`. Los enlaces
    /// que no formen un grupo de al menos `minSize` se dejan sin agrupar (mejor pocos grupos
    /// confiables que muchos ruidosos). Algo que Raindrop NO hace (no tiene IA local).
    static func topicClusters(in links: [Bookmark], language: String,
                              threshold: Double = 0.45, minSize: Int = 3,
                              maxLinks: Int = 1500) -> [[Bookmark]] {
        guard links.count > 1 else { return [] }
        ensureCacheRevision()
        let items: [(link: Bookmark, vec: [Double])] = links.prefix(maxLinks).compactMap { link in
            guard let c = vectorCache[link.id], c.stamp == link.updatedAt else { return nil }
            return (link, c.vector)
        }
        var used = Set<Int>()
        var clusters: [[Bookmark]] = []
        for i in items.indices where !used.contains(i) {
            var cluster = [items[i].link]
            used.insert(i)
            for j in items.indices where j > i && !used.contains(j) {
                if cosine(items[i].vec, items[j].vec) >= threshold {
                    cluster.append(items[j].link)
                    used.insert(j)
                }
            }
            clusters.append(cluster)
        }
        return clusters.filter { $0.count >= minSize }.sorted { $0.count > $1.count }
    }

    /// El índice SQLite persiste los vectores; esta caché solo acelera la interfaz.
    static func warm(_ links: [Bookmark], language: String, task: String = "document") async {
        try? await warmChecked(links, language: language, task: task)
    }

    static func warmChecked(_ links: [Bookmark], language: String, task: String = "document") async throws {
        ensureCacheRevision()
        if cacheTask != task { vectorCache.removeAll(); cacheTask = task }
        let revision = cacheRevision
        let pending: [(id: UUID, stamp: Date)] = links.compactMap { link in
            if let cached = vectorCache[link.id], cached.stamp == link.updatedAt { return nil }
            return (link.id, link.updatedAt)
        }
        guard !pending.isEmpty else { return }
        do {
            let vectors = try await MultimodalSearchService.shared.vectors(for: pending.map(\.id), task: task)
            guard revision == MultimodalSearchService.shared.revision, cacheTask == task else { return }
            for item in pending {
                if let vector = vectors[item.id] { vectorCache[item.id] = (item.stamp, vector) }
            }
            if vectorCache.count > 6_000 {
                let live = Set(links.map(\.id))
                vectorCache = vectorCache.filter { live.contains($0.key) }
                metaCache = metaCache.filter { live.contains($0.key) }
            }
        } catch { throw error }
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let denom = na.squareRoot() * nb.squareRoot()
        return denom == 0 ? 0 : dot / denom
    }
}

/// Toggle reutilizable del modo «Buscar por significado». Sirve también de INDICADOR:
/// cuando está activo muestra una nota aclaratoria de que los resultados se ordenan
/// por relevancia semántica (no por coincidencia exacta). Adaptación macOS: sin
/// gestos táctiles ni hápticos; el `Toggle` nativo basta. Se integra bajo la cabecera
/// de la biblioteca cuando hay texto de búsqueda y embeddings disponibles.
struct SemanticSearchToggle: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isOn: Bool
    var warming: Bool = false
    var statusMessage: String?
    var onActivate: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            if warming {
                ProgressView().controlSize(.small).frame(width: 14, height: 14)
            } else {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(isOn ? palette.accent : palette.textSecondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Buscar por significado")
                    .stacklumeFont(.caption.weight(.medium))
                    .foregroundStyle(palette.textPrimary)
                    Text(statusMessage ?? (warming
                         ? "Preparando la búsqueda semántica…"
                         : (isOn ? "Palabras, significado, imágenes y color" : "Coincidencias por palabras")))
                        .stacklumeFont(.caption2)
                        .foregroundStyle(palette.textSecondary)
                        .stacklumeLineLimit(1)
                        .themedHelp(statusMessage ?? "La búsqueda combina coincidencias exactas y significado")
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(palette.accent)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .frame(height: 44)
        .onChange(of: isOn) { _, on in if on { onActivate() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Buscar por significado")
    }
}
