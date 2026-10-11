import Foundation
import SwiftData
import StacklumeCore

/// Genera un TL;DR de UNA frase del enlace con el modelo local y lo guarda en
/// `Bookmark.summary` (un campo que existía pero no se usaba: la IA mete su descripción
/// rica en `details`). Sirve para ESCANEAR la biblioteca/cola sin abrir cada enlace y
/// para enriquecer la búsqueda semántica. 100 % local. No usa red salvo para traer el
/// contenido si no hay copia offline.
@MainActor
enum LinkSummarizer {

    /// Resume `link` en `Bookmark.summary`. No pisa un resumen existente salvo `force`.
    /// Devuelve `true` si generó uno. Requiere el modelo local disponible.
    @discardableResult
    static func summarize(_ link: Bookmark, in context: ModelContext,
                          language: String, force: Bool = false) async -> Bool {
        guard link.modelContext != nil else { return false }
        if !force, let existing = link.summary,
           !existing.trimmingCharacters(in: .whitespaces).isEmpty { return false }

        let runner = LocalAIRunner.shared
        guard runner.isAvailable, await runner.ensureReady() != nil, link.modelContext != nil else { return false }

        // Contenido: copia offline si la hay; si no, un extracto descargado; en último caso,
        // los propios metadatos (título + descripción). Se limpia de CSS/ruido (algunas SPAs lo
        // filtran al texto) para que el resumen no se base en estilos en vez de en prosa.
        var content = ProseText.clean(link.offlineText ?? "")
        if content.count < 120 {
            content = await AIBatchEnricher.pageContentExcerpt(for: link.url) ?? content
        }
        guard link.modelContext != nil else { return false }
        if content.count < 80 {
            // Sin contenido REAL de la página: resume SOLO si hay una descripción (OG) fiable.
            // BLINDAJE anti-alucinación: nunca resumir un título/URL pelado (el modelo inventaría),
            // como pasó con un t.co descrito como un juego que no era.
            let og = (link.details ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !og.isEmpty else { return false }
            content = [link.title, og].joined(separator: ". ")
        }
        let excerpt = String(content.prefix(3000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard excerpt.count >= 24 else { return false }

        let langName = language == "en" ? "inglés" : "español"
        let system = "Eres un asistente que resume. Devuelve UNA sola frase (máximo 25 palabras) en \(langName) con la idea principal del contenido. Sin preámbulo, sin comillas, sin viñetas."
        guard let raw = await runner.complete(system: system, prompt: excerpt, maxTokens: 160, enableThinking: false),
              link.modelContext != nil else { return false }

        let text = AIText.withoutThinking(raw)
        let oneLine = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "") }
            .first { !$0.isEmpty } ?? ""
        let summary = String(oneLine.prefix(220)).trimmingCharacters(in: .whitespacesAndNewlines)
        // Rechaza la META-RESPUESTA de la IA («no se proporcionó información…») — no es un resumen.
        guard summary.count >= 8, !AIBatchEnricher.isMetaNonAnswer(summary) else { return false }

        link.summary = summary
        link.updatedAt = Date()
        context.saveLogging()
        return true
    }
}
