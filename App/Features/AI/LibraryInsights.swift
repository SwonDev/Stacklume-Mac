import Foundation
import SwiftData
import StacklumeCore

/// Resumen/insight de la biblioteca con el modelo Liquid LOCAL (diferenciador frente a
/// Raindrop, que no tiene IA on-device). Reutiliza `LocalAIRunner.complete` (no duplica el
/// motor) y NO cambia el modelo. Solo alimenta al modelo con AGREGADOS (nombres y recuentos
/// de colecciones/etiquetas/dominios), nunca con las URLs ni el contenido; y todo es on-device.
@MainActor
enum LibraryInsights {

    /// Genera un párrafo breve sobre los intereses y temas de la biblioteca. `nil` si no hay
    /// IA disponible o aún hay pocos enlaces.
    static func generate(in context: ModelContext, language: String) async -> String? {
        let links = ((try? context.fetch(FetchDescriptor<Bookmark>())) ?? [])
            .filter { $0.deletedAt == nil }
        guard links.count >= 5 else { return nil }

        let cats = topCounts(links.compactMap { $0.category?.name }, limit: 8)
        let tags = topCounts(links.flatMap { $0.tags.map(\.name) }, limit: 12)
        let domains = topCounts(links.map { $0.url.urlHost }.filter { !$0.isEmpty }, limit: 8)
        let read = links.filter(\.isRead).count

        var data = "Total: \(links.count) enlaces (\(read) leídos).\n"
        if !cats.isEmpty { data += "Colecciones: " + cats.map { "\($0.0) (\($0.1))" }.joined(separator: ", ") + "\n" }
        if !tags.isEmpty { data += "Etiquetas: " + tags.map(\.0).joined(separator: ", ") + "\n" }
        if !domains.isEmpty { data += "Dominios: " + domains.map { "\($0.0) (\($0.1))" }.joined(separator: ", ") + "\n" }

        let langName = language == "en" ? "English" : "español"
        let system = "Eres un analista CONCISO de bibliotecas de marcadores. Respondes SOLO con el párrafo pedido, en \(langName), sin preámbulos ni listas."
        let prompt = """
        Datos agregados de la biblioteca de una persona:
        \(data)
        Escribe en \(langName) un párrafo BREVE (3-4 frases) que describa sus intereses y temas principales según estos datos, y termina con UNA sugerencia útil y concreta para organizar mejor su biblioteca. No inventes datos que no aparezcan arriba.
        """

        // Carga el modelo si hace falta; si no se puede, no hay insight.
        guard await LocalAIRunner.shared.ensureReady() != nil else { return nil }
        // Presupuesto holgado: LFM2.5 razona en un bloque `<think>` aunque se desactive; con
        // pocos tokens lo gasta TODO razonando y nunca cierra el bloque ni escribe la respuesta
        // (entonces `withoutThinking` devuelve ""). Con margen, cierra el `<think>` y responde.
        let out = await LocalAIRunner.shared.complete(system: system, prompt: prompt,
                                                      maxTokens: 700, enableThinking: true)
        let text = AIText.withoutThinking(out ?? "")
        return text.isEmpty ? nil : text
    }

    /// Digest temático de lo guardado en los últimos `days` días (por defecto una semana):
    /// un par de frases sobre QUÉ ha estado explorando la persona, agrupando por temas y
    /// destacando algo. `nil` si no hay IA o si guardó muy poco en el periodo (no se fuerza
    /// un resumen de la nada). Como `generate`, alimenta al modelo con AGREGADOS + algunos
    /// títulos (datos propios del usuario, on-device), nunca con URLs ni contenido de páginas.
    static func digest(in context: ModelContext, language: String, days: Int = 7) async -> String? {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let recent = ((try? context.fetch(FetchDescriptor<Bookmark>())) ?? [])
            .filter { $0.deletedAt == nil && $0.createdAt >= since }
            .sorted { $0.createdAt > $1.createdAt }
        guard recent.count >= 3 else { return nil }

        let cats = topCounts(recent.compactMap { $0.category?.name }, limit: 6)
        let tags = topCounts(recent.flatMap { $0.tags.map(\.name) }, limit: 10)
        let types = topCounts(recent.map { $0.contentType.displayName }, limit: 6)
        // Una muestra de títulos (los más recientes) para que el resumen sea concreto.
        let titles = recent.prefix(12).map { $0.title.isEmpty ? $0.url.urlHost : $0.title }

        var data = "Total guardados en \(days) días: \(recent.count).\n"
        if !cats.isEmpty { data += "Colecciones: " + cats.map { "\($0.0) (\($0.1))" }.joined(separator: ", ") + "\n" }
        if !types.isEmpty { data += "Tipos: " + types.map { "\($0.0) (\($0.1))" }.joined(separator: ", ") + "\n" }
        if !tags.isEmpty { data += "Etiquetas: " + tags.map(\.0).joined(separator: ", ") + "\n" }
        data += "Títulos:\n- " + titles.joined(separator: "\n- ")

        let langName = language == "en" ? "English" : "español"
        let system = "Eres un analista CONCISO que resume la semana de marcadores de una persona. Respondes SOLO con el párrafo pedido, en \(langName), sin preámbulos ni listas ni encabezados."
        let prompt = """
        Esto es lo que una persona guardó recientemente:
        \(data)

        Escribe en \(langName) un resumen BREVE (2-3 frases) de QUÉ ha estado explorando, AGRUPANDO por temas (no enumeres todo). Termina destacando 1 tema o enlace concreto que parezca el más relevante. No inventes nada que no aparezca arriba.
        """

        guard await LocalAIRunner.shared.ensureReady() != nil else { return nil }
        // Margen amplio para que el bloque `<think>` de LFM2.5 cierre y deje sitio a la
        // respuesta (con poco presupuesto se quedaba razonando y `withoutThinking` vaciaba todo).
        let out = await LocalAIRunner.shared.complete(system: system, prompt: prompt,
                                                      maxTokens: 700, enableThinking: true)
        let text = AIText.withoutThinking(out ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Cuenta y ordena por frecuencia descendente, devolviendo los `limit` más comunes.
    private static func topCounts(_ values: [String], limit: Int) -> [(String, Int)] {
        Dictionary(grouping: values, by: { $0 }).mapValues(\.count)
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map { ($0.key, $0.value) }
    }
}
