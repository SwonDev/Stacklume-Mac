import Foundation
import StacklumeCore

/// Exporta los resaltados a Markdown (listo para Obsidian/Notion/Readwise). Gratis y
/// local — Raindrop cobra por la integración con Readwise; aquí es nativo.
enum HighlightExport {
    /// Markdown de los resaltados de un conjunto de enlaces, agrupados por enlace y
    /// ordenados por antigüedad. Cada resaltado es una cita Markdown (`>`), con la fuente
    /// como enlace en el encabezado de cada sección.
    static func markdown(for links: [Bookmark]) -> String {
        let withHighlights = links
            .filter { !$0.highlights.isEmpty }
            .sorted {
                ($0.highlights.map(\.createdAt).max() ?? .distantPast) >
                ($1.highlights.map(\.createdAt).max() ?? .distantPast)
            }
        var out = "# Resaltados\n\n"
        for link in withHighlights {
            let title = link.title.isEmpty ? link.url : link.title
            out += "## [\(escape(title))](\(link.url))\n\n"
            for highlight in link.highlights.sorted(by: { $0.createdAt < $1.createdAt }) {
                let text = highlight.text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: "\n> ")
                guard !text.isEmpty else { continue }
                out += "> \(text)\n"
                let note = HighlightNoteStore.note(for: highlight.id)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                if !note.isEmpty { out += ">\n> — *\(note)*\n" }
                out += "\n"
            }
        }
        return out
    }

    /// Markdown de los resaltados de UN enlace.
    static func markdown(for link: Bookmark) -> String { markdown(for: [link]) }

    /// Escapa los caracteres de Markdown que romperían un enlace `[texto](url)`.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
    }
}
