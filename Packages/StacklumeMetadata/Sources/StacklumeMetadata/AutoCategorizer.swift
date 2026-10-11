import Foundation
import StacklumeCore

/// Sugerencia de categoría automática para un enlace.
public struct CategorySuggestion: Sendable, Equatable {
    public let name: String
    public let icon: String
    public let colorHex: String
}

/// Sugiere una categoría según el tipo de contenido / plataforma. Mejora sobre
/// el original (que solo categoriza por reglas de usuario): da una organización
/// automática útil "out of the box". Devuelve `nil` para contenido genérico.
public enum AutoCategorizer {

    public static func suggestion(contentType: ContentType, platform: Platform) -> CategorySuggestion? {
        // La plataforma puede afinar la categoría aunque el tipo sea genérico.
        if platform == .appStore {
            return CategorySuggestion(name: "Apps", icon: "app.badge.fill", colorHex: "#0D96F6")
        }
        switch contentType {
        case .code:
            return CategorySuggestion(name: "Desarrollo", icon: "chevron.left.forwardslash.chevron.right", colorHex: "#7AA2F7")
        case .video:
            return CategorySuggestion(name: "Vídeos", icon: "play.rectangle.fill", colorHex: "#FF6B6B")
        case .music:
            return CategorySuggestion(name: "Música", icon: "music.note", colorHex: "#1DB954")
        case .game:
            return CategorySuggestion(name: "Juegos", icon: "gamecontroller.fill", colorHex: "#9146FF")
        case .design:
            return CategorySuggestion(name: "Diseño", icon: "paintpalette.fill", colorHex: "#C8A8FF")
        case .article:
            return CategorySuggestion(name: "Lectura", icon: "book.fill", colorHex: "#4ECDC4")
        case .social:
            return CategorySuggestion(name: "Social", icon: "bubble.left.and.bubble.right.fill", colorHex: "#1DA1F2")
        case .document:
            return CategorySuggestion(name: "Documentos", icon: "doc.fill", colorHex: "#94A3B8")
        case .commerce:
            return CategorySuggestion(name: "Compras", icon: "cart.fill", colorHex: "#FF9900")
        case .website:
            return nil
        }
    }
}
