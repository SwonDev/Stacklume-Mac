import Foundation

/// Utilidades de TEXTO para salidas del modelo local. Aislado para reutilizar en el
/// resumidor, el organizador por temas, etc., sin duplicar.
enum AIText {
    /// Quita el bloque de razonamiento `<think>…</think>` que algunos modelos (LFM2.5)
    /// emiten aunque se pida desactivarlo. Si el modelo SOLO razonó (abrió `<think>` sin
    /// cerrarlo, p. ej. por límite de tokens) devuelve `""` (no hay respuesta útil).
    static func withoutThinking(_ raw: String) -> String {
        if raw.contains("<think>") && !raw.contains("</think>") { return "" }
        var text = raw
        if let closing = text.range(of: "</think>") { text = String(text[closing.upperBound...]) }
        return text
            .replacingOccurrences(of: "<think>", with: "")
            .replacingOccurrences(of: "</think>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
