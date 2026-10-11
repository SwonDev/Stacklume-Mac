import Foundation
import SwiftData
import StacklumeCore

/// Punto ÚNICO de alta de colecciones y etiquetas. Reutiliza la equivalente existente por
/// forma CANÓNICA (sinónimos/traducciones/acentos/mayúsculas; ver `CollectionMerger`) o crea
/// una nueva con el nombre de presentación preferido. Centralizar aquí evita que cada origen
/// (importación de navegador/CSV, IA por lotes, editor manual, asistente) cree duplicados como
/// «Juegos»/«Videojuegos» o «Development»/«Desarrollo»: se crea bien DESDE EL PRINCIPIO, sin
/// depender de que el usuario use luego «Fusionar colecciones» en Mantenimiento.
///
/// `nonisolated` y síncrono: opera sobre el `ModelContext` que recibe, igual que el resto de
/// altas de la app, así que es llamable desde cualquier actor (View `@MainActor`, enriquecido
/// por lotes `@MainActor`, bloques `MainActor.run` del asistente…).
enum EntityResolver {

    // MARK: - Colecciones

    /// Find-or-create canónico de una colección con caché de LOTE (forma canónica → colección)
    /// para no hacer un fetch por enlace. En fallo de caché re-comprueba el contexto (ve los
    /// inserts pendientes de tareas concurrentes) antes de crear, y cachea bajo la clave canónica.
    @discardableResult
    static func category(_ rawName: String, in context: ModelContext,
                         cache: inout [String: BookmarkCategory]) -> BookmarkCategory? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = CollectionMerger.canonical(trimmed)
        if let hit = cache[key] {
            if hit.deletedAt == nil { return hit }
            cache[key] = nil
        }
        if let existing = (try? context.fetch(FetchDescriptor<BookmarkCategory>()))?
            .first(where: { $0.deletedAt == nil && CollectionMerger.canonical($0.name) == key }) {
            cache[key] = existing
            return existing
        }
        let display = CollectionMerger.preferredDisplayName(for: trimmed)
        let category = BookmarkCategory(name: display, icon: CategoryIcon.symbol(for: display),
                                        colorHex: display.deterministicColorHex, order: cache.count)
        context.insert(category)
        cache[key] = category
        return category
    }

    /// Find-or-create canónico de una colección para uso puntual (sin caché). `colorHex` e
    /// `icon` permiten elegirlos explícitamente (p. ej. el que pida el usuario al crearla desde
    /// el editor del enlace); si son `nil` usa el color determinista del nombre y el icono
    /// sugerido por `CategoryIcon`. Si la colección YA existe (canónico), se devuelve tal cual
    /// (no se le cambia icono/color: solo afecta a la creación).
    @discardableResult
    static func category(_ rawName: String, in context: ModelContext,
                         colorHex: String? = nil, icon: String? = nil) -> BookmarkCategory? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = CollectionMerger.canonical(trimmed)
        let cats = (try? context.fetch(FetchDescriptor<BookmarkCategory>()))?
            .filter { $0.deletedAt == nil } ?? []
        if let existing = cats.first(where: { CollectionMerger.canonical($0.name) == key }) {
            return existing
        }
        let display = CollectionMerger.preferredDisplayName(for: trimmed)
        let category = BookmarkCategory(name: display, icon: icon ?? CategoryIcon.symbol(for: display),
                                        colorHex: colorHex ?? display.deterministicColorHex, order: cats.count)
        context.insert(category)
        return category
    }

    /// Colección activa equivalente por canónico SIN crear. Para acciones que no deben crear
    /// (p. ej. el asistente comprobando si ya existe antes de crear/renombrar/borrar).
    static func existingCategory(_ rawName: String, in context: ModelContext) -> BookmarkCategory? {
        let key = CollectionMerger.canonical(rawName)
        return (try? context.fetch(FetchDescriptor<BookmarkCategory>()))?
            .first { $0.deletedAt == nil && CollectionMerger.canonical($0.name) == key }
    }

    // MARK: - Etiquetas

    /// Clave canónica de etiqueta: la de `TagSanitizer.key` (minúsculas, sin tildes, espacios
    /// colapsados) + SIN «s» final (singular/plural) para nombres > 4, así «videojuego» y
    /// «videojuegos» se tratan como la MISMA etiqueta.
    static func tagKey(_ name: String) -> String {
        var k = TagSanitizer.key(name)
        // Quita la «s» final para unificar singular/plural (videojuego/videojuegos, tool/tools),
        // PERO nunca en palabras que acaban en «s» SIN ser plural: fusionarlas borraría etiquetas
        // DISTINTAS («Canvas» (API de dibujo) ≠ «Canva» (app), «Analysis», «iOS», «CSS»…). Excluye
        // los acabados en «ss» y una lista de singulares-en-«s» conocidos.
        if k.count > 4, k.hasSuffix("s"), !k.hasSuffix("ss"), !Self.nonPluralS.contains(k) {
            k.removeLast()
        }
        return k
    }

    /// Palabras que acaban en «s» pero NO son plurales (no se les quita la «s» al deduplicar).
    private static let nonPluralS: Set<String> = [
        "canvas", "analysis", "atlas", "redis", "kubernetes", "series", "basis", "axis",
        "ios", "macos", "ipados", "watchos", "tvos", "visionos", "news", "kudos", "chaos",
        "campus", "census", "bonus", "status", "focus", "virus", "bias", "lens",
    ]

    /// Find-or-create canónico de una etiqueta con caché de lote. Conserva la grafía del
    /// usuario al crear (solo deduplica; no transforma el nombre).
    @discardableResult
    static func tag(_ rawName: String, in context: ModelContext,
                    cache: inout [String: Tag], colorHex: String? = nil) -> Tag? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = tagKey(trimmed)
        if let hit = cache[key] {
            if hit.deletedAt == nil { return hit }
            cache[key] = nil
        }
        if let existing = (try? context.fetch(FetchDescriptor<Tag>()))?
            .first(where: { $0.deletedAt == nil && tagKey($0.name) == key }) {
            cache[key] = existing
            return existing
        }
        // `colorHex` permite elegir el color al crearla (editor del enlace); si es nil, determinista.
        let tag = Tag(name: trimmed, colorHex: colorHex ?? trimmed.deterministicColorHex, order: cache.count)
        context.insert(tag)
        cache[key] = tag
        return tag
    }

    /// Find-or-create canónico de una etiqueta para uso puntual (sin caché). `colorHex` opcional.
    @discardableResult
    static func tag(_ rawName: String, in context: ModelContext, colorHex: String? = nil) -> Tag? {
        var throwaway: [String: Tag] = [:]
        return tag(rawName, in: context, cache: &throwaway, colorHex: colorHex)
    }

    /// Fusiona etiquetas DUPLICADAS por clave canónica (may./tildes y singular/plural):
    /// conserva la que más enlaces tiene (desempate: menor `order`), le traslada los enlaces
    /// y subetiquetas de las demás y borra las duplicadas. Equivalente a
    /// `CollectionMerger.mergeDuplicates` pero para `Tag` (relación N:N). Devuelve cuántas se
    /// eliminaron. Pensado para auto-repararse en el arranque, sin intervención del usuario.
    @discardableResult
    static func mergeDuplicateTags(in context: ModelContext) -> Int {
        guard let all = try? context.fetch(FetchDescriptor<Tag>()) else { return 0 }
        let active = all.filter { $0.deletedAt == nil }
        var groups: [String: [Tag]] = [:]
        for t in active { groups[tagKey(t.name), default: []].append(t) }

        var removed = 0
        for (_, group) in groups where group.count > 1 {
            guard let winner = group.sorted(by: {
                $0.links.count != $1.links.count ? $0.links.count > $1.links.count : $0.order < $1.order
            }).first else { continue }
            for loser in group where loser.id != winner.id {
                // Relación N:N: en cada enlace de la perdedora, añade la ganadora (si falta) y
                // quita la perdedora.
                for bm in Array(loser.links) {
                    if !bm.tags.contains(where: { $0.id == winner.id }) { bm.tags.append(winner) }
                    bm.tags.removeAll { $0.id == loser.id }
                }
                for child in Array(loser.children) { child.parent = winner }
                context.delete(loser)
                removed += 1
            }
        }
        if removed > 0 { context.saveLogging() }
        return removed
    }
}
