import Foundation

/// Resultado de normalizar el texto extraído de un documento local.
///
/// Vive en un fichero Foundation-only para poder probar los límites y la limpieza sin
/// compilar PDFKit/Vision ni el target completo de la app.
struct SanitizedDocumentText: Sendable, Equatable {
    let text: String
    let wasTruncated: Bool
}

/// Limpieza determinista del texto de PDFs e imágenes antes de guardarlo en `offlineText`.
enum DocumentTextSanitizer {
    /// Cota de almacenamiento y búsqueda: alrededor de 4 MB en UTF-16 por documento.
    static let maximumCharacters = 2_000_000

    static func normalize(
        _ fragments: [String],
        maximumCharacters: Int = maximumCharacters
    ) -> SanitizedDocumentText {
        guard maximumCharacters > 0 else {
            return SanitizedDocumentText(text: "", wasTruncated: fragments.contains { !$0.isEmpty })
        }

        var cleaned: [String] = []
        cleaned.reserveCapacity(fragments.count)
        var accumulated = 0
        var truncated = false
        let (scaledInputLimit, overflow) = maximumCharacters.multipliedReportingOverflow(by: 4)
        var remainingInput = overflow ? Int.max : max(maximumCharacters, scaledInputLimit)

        for fragment in fragments {
            guard remainingInput > 0 else {
                truncated = true
                break
            }
            let boundary = fragment.index(
                fragment.startIndex,
                offsetBy: remainingInput,
                limitedBy: fragment.endIndex
            )
            let inputWasTruncated = boundary.map { $0 != fragment.endIndex } ?? false
            let boundedFragment = boundary.map { String(fragment[..<$0]) } ?? fragment
            remainingInput -= boundedFragment.count

            let normalized = normalizeFragment(boundedFragment)
            guard !normalized.isEmpty else {
                if inputWasTruncated {
                    truncated = true
                    break
                }
                continue
            }

            let separatorCount = cleaned.isEmpty ? 0 : 2
            let remaining = maximumCharacters - accumulated - separatorCount
            guard remaining > 0 else {
                truncated = true
                break
            }

            if normalized.count > remaining {
                cleaned.append(String(normalized.prefix(remaining)))
                accumulated += separatorCount + remaining
                truncated = true
                break
            }

            cleaned.append(normalized)
            accumulated += separatorCount + normalized.count
            if inputWasTruncated {
                truncated = true
                break
            }
        }

        return SanitizedDocumentText(
            text: cleaned.joined(separator: "\n\n"),
            wasTruncated: truncated
        )
    }

    private static func normalizeFragment(_ raw: String) -> String {
        var result = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")

        result.removeAll { scalar in
            scalar.isASCII && scalar.asciiValue.map { $0 < 32 && $0 != 9 && $0 != 10 } == true
        }
        result = result.replacing(#/[ \t]{2,}/#, with: " ")
        result = result.replacing(#/\n[ \t]+/#, with: "\n")
        result = result.replacing(#/\n{3,}/#, with: "\n\n")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
