import Foundation

/// Datos enriquecidos de un repositorio de código (GitHub). Se guarda embebido en
/// `Bookmark.repoInfo` (SwiftData almacena el valor Codable). Permite mostrar una
/// tarjeta especial con estrellas, forks y lenguaje sin volver a la red.
public struct RepoInfo: Codable, Sendable, Hashable {
    public var stars: Int
    public var forks: Int
    public var language: String?
    public var ownerAvatarURL: String?
    /// Fecha del último push (para «actualizado hace…»).
    public var lastPush: Date?

    public init(stars: Int, forks: Int, language: String? = nil,
                ownerAvatarURL: String? = nil, lastPush: Date? = nil) {
        self.stars = stars
        self.forks = forks
        self.language = language
        self.ownerAvatarURL = ownerAvatarURL
        self.lastPush = lastPush
    }

    /// Estrellas con formato compacto (1.2k, 15.3k…).
    public var starsText: String { Self.compact(stars) }
    public var forksText: String { Self.compact(forks) }

    static func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}
