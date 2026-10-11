import Foundation

/// Detecta declaraciones capaces de introducir expansión de entidades antes de entregar
/// XML/XHTML no confiable a `XMLParser`. Recorre todos los bytes ya acotados, también para
/// UTF-16/UTF-32 (ignorando NUL entre caracteres ASCII).
enum XMLInputSafety {
    private static let forbiddenTokens = [
        Array("<!doctype".utf8),
        Array("<!entity".utf8),
    ]

    static func containsForbiddenDeclaration(_ data: Data) -> Bool {
        var states = Array(repeating: 0, count: forbiddenTokens.count)
        for rawByte in data {
            if rawByte == 0 { continue }
            let byte: UInt8 = (65...90).contains(rawByte) ? rawByte + 32 : rawByte
            for index in forbiddenTokens.indices {
                let token = forbiddenTokens[index]
                var state = states[index]
                if byte == token[state] {
                    state += 1
                    if state == token.count { return true }
                } else {
                    state = byte == token[0] ? 1 : 0
                }
                states[index] = state
            }
        }
        return false
    }
}
