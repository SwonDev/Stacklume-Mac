import Foundation

/// Métricas de lectura de un enlace (tiempo estimado), como muestran Pocket/GoodLinks/Readwise.
/// Se calcula a partir del texto disponible (copia sin conexión, o un texto legible pasado
/// aparte), a ~200 palabras/minuto. No persiste nada (el modelo es de solo lectura).
enum ReadingMetrics {
    /// Palabras por minuto de lectura media de un adulto.
    private static let wordsPerMinute = 200.0

    /// Minutos estimados a partir de un texto. `nil` si el texto es demasiado corto para que
    /// el dato sea útil (menos de ~40 palabras).
    static func minutes(forText text: String?) -> Int? {
        guard let text, !text.isEmpty else { return nil }
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).count
        guard words >= 40 else { return nil }
        return max(1, Int((Double(words) / wordsPerMinute).rounded()))
    }

    /// Etiqueta corta para la UI: «5 min».
    static func label(_ minutes: Int) -> String { "\(minutes) min" }
}
