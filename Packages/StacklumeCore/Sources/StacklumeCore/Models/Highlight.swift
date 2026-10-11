import Foundation
import SwiftData

/// Resaltado / anotación de un enlace (varios por marcador). Equivale a los
/// highlights de Raindrop: un fragmento de texto con color, para citar o anotar.
@Model
public final class Highlight {
    public var id: UUID = UUID()
    public var text: String = ""
    /// Color del resaltado en formato hex.
    public var colorHex: String = "#D4A853"
    public var createdAt: Date = Date()

    /// Marcador al que pertenece.
    public var bookmark: Bookmark?

    public init(
        id: UUID = UUID(),
        text: String = "",
        colorHex: String = "#D4A853",
        bookmark: Bookmark? = nil
    ) {
        self.id = id
        self.text = text
        self.colorHex = colorHex
        self.createdAt = Date()
        self.bookmark = bookmark
    }
}
