import Foundation

/// Codificación RFC 4180 con neutralización de fórmulas para hojas de cálculo.
enum CSVFieldEncoder {
    static func encode(_ raw: String) -> String {
        var safe = raw
        if beginsWithFormulaTrigger(raw) {
            safe.insert("'", at: safe.startIndex)
        }
        if safe.contains(",") || safe.contains("\"") || safe.contains("\n") || safe.contains("\r") {
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return safe
    }

    private static func beginsWithFormulaTrigger(_ value: String) -> Bool {
        let ignored = CharacterSet.whitespaces.union(.controlCharacters)
        guard let first = value.unicodeScalars.first(where: { !ignored.contains($0) }) else {
            return false
        }
        return first == "=" || first == "+" || first == "-" || first == "@"
    }
}
