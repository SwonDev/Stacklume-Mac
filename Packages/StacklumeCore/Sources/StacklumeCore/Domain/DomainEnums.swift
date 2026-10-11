import Foundation

/// Plataforma detectada para un enlace. Equivale a `platform-detection.ts` del
/// original. La detección automática real se implementa en la Fase 2; aquí se
/// modela el dominio completo.
public enum Platform: String, Codable, CaseIterable, Sendable, Identifiable {
    case youtube, vimeo, twitch, netflix
    case steam, epic, gog, itch
    case spotify, soundcloud, appleMusic
    case github, gitlab, bitbucket, codepen, stackoverflow
    case hackerNews, npm, pypi
    case twitter, reddit, instagram, tiktok, linkedin, facebook
    case pinterest, dribbble, behance, figma
    case notion, googleDocs, googleDrive, dropbox
    case amazon, ebay, etsy
    case medium, devto, hashnode, wikipedia
    case appStore
    case local
    case generic

    public var id: String { rawValue }

    /// Nombre legible para mostrar en la interfaz.
    public var displayName: String {
        switch self {
        case .youtube: "YouTube"
        case .vimeo: "Vimeo"
        case .twitch: "Twitch"
        case .netflix: "Netflix"
        case .steam: "Steam"
        case .epic: "Epic Games"
        case .gog: "GOG"
        case .itch: "itch.io"
        case .spotify: "Spotify"
        case .soundcloud: "SoundCloud"
        case .appleMusic: "Apple Music"
        case .github: "GitHub"
        case .gitlab: "GitLab"
        case .bitbucket: "Bitbucket"
        case .codepen: "CodePen"
        case .stackoverflow: "Stack Overflow"
        case .hackerNews: "Hacker News"
        case .npm: "npm"
        case .pypi: "PyPI"
        case .twitter: "Twitter / X"
        case .reddit: "Reddit"
        case .instagram: "Instagram"
        case .tiktok: "TikTok"
        case .linkedin: "LinkedIn"
        case .facebook: "Facebook"
        case .pinterest: "Pinterest"
        case .dribbble: "Dribbble"
        case .behance: "Behance"
        case .figma: "Figma"
        case .notion: "Notion"
        case .googleDocs: "Google Docs"
        case .googleDrive: "Google Drive"
        case .dropbox: "Dropbox"
        case .amazon: "Amazon"
        case .ebay: "eBay"
        case .etsy: "Etsy"
        case .medium: "Medium"
        case .devto: "DEV.to"
        case .hashnode: "Hashnode"
        case .wikipedia: "Wikipedia"
        case .appStore: "App Store"
        case .local: "Local"
        case .generic: "Web"
        }
    }

    /// Nombre de SF Symbol representativo (provisional; se afina en Fase 2).
    public var sfSymbol: String {
        switch self {
        case .youtube, .vimeo, .netflix: "play.rectangle.fill"
        case .twitch: "gamecontroller.fill"
        case .steam, .epic, .gog, .itch: "gamecontroller.fill"
        case .spotify, .soundcloud, .appleMusic: "music.note"
        case .github, .gitlab, .bitbucket: "chevron.left.forwardslash.chevron.right"
        case .codepen, .stackoverflow: "curlybraces"
        case .hackerNews: "newspaper.fill"
        case .npm, .pypi: "shippingbox.fill"
        case .twitter, .instagram, .tiktok, .linkedin, .facebook, .reddit: "bubble.left.and.bubble.right.fill"
        case .pinterest, .dribbble, .behance, .figma: "paintpalette.fill"
        case .notion, .googleDocs, .googleDrive, .dropbox: "doc.fill"
        case .amazon, .ebay, .etsy: "cart.fill"
        case .medium, .devto, .hashnode, .wikipedia: "doc.text.fill"
        case .appStore: "app.badge.fill"
        case .local: "internaldrive.fill"
        case .generic: "globe"
        }
    }

    /// Color de marca (hex), fiel a la tabla del Stacklume original.
    public var brandColorHex: String {
        switch self {
        case .youtube: "#FF0000"
        case .vimeo: "#1AB7EA"
        case .twitch: "#9146FF"
        case .netflix: "#E50914"
        case .steam: "#1B2838"
        case .epic: "#313131"
        case .gog: "#86328A"
        case .itch: "#FA5C5C"
        case .spotify: "#1DB954"
        case .soundcloud: "#FF5500"
        case .appleMusic: "#FC3C44"
        case .github: "#181717"
        case .gitlab: "#FC6D26"
        case .bitbucket: "#0052CC"
        case .codepen: "#000000"
        case .stackoverflow: "#F48024"
        case .hackerNews: "#FF6600"
        case .npm: "#CB3837"
        case .pypi: "#3776AB"
        case .twitter: "#1DA1F2"
        case .reddit: "#FF4500"
        case .instagram: "#E4405F"
        case .tiktok: "#000000"
        case .linkedin: "#0A66C2"
        case .facebook: "#1877F2"
        case .pinterest: "#E60023"
        case .dribbble: "#EA4C89"
        case .behance: "#1769FF"
        case .figma: "#F24E1E"
        case .notion: "#000000"
        case .googleDocs, .googleDrive: "#4285F4"
        case .dropbox: "#0061FF"
        case .amazon: "#FF9900"
        case .ebay: "#E53238"
        case .etsy: "#F56400"
        case .medium: "#000000"
        case .devto: "#0A0A0A"
        case .hashnode: "#2962FF"
        case .wikipedia: "#000000"
        case .appStore: "#0D96F6"
        case .local: "#6366F1"
        case .generic: "#6B7280"
        }
    }
}

/// Tipo de contenido de un enlace.
public enum ContentType: String, Codable, CaseIterable, Sendable, Identifiable {
    case video, music, game, code, article, social, design, document, commerce, website

    public var id: String { rawValue }

    public var displayName: String {
        let raw: String
        switch self {
        case .video: raw = "Vídeo"
        case .music: raw = "Música"
        case .game: raw = "Juego"
        case .code: raw = "Código"
        case .article: raw = "Artículo"
        case .social: raw = "Social"
        case .design: raw = "Diseño"
        case .document: raw = "Documento"
        case .commerce: raw = "Comercio"
        case .website: raw = "Sitio web"
        }
        return localizedDomain(raw)
    }
}

/// Estado de la cola de lectura.
public enum ReadingStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case inbox, reading, done

    public var id: String { rawValue }

    public var displayName: String {
        let raw: String
        switch self {
        case .inbox: raw = "Pendiente"
        case .reading: raw = "Leyendo"
        case .done: raw = "Leído"
        }
        return localizedDomain(raw)
    }

    public var sfSymbol: String {
        switch self {
        case .inbox: "tray.fill"
        case .reading: "book.fill"
        case .done: "checkmark.circle.fill"
        }
    }
}

/// Estado de salud de un enlace (comprobación de URL, Fase 2).
public enum HealthStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case ok, redirect, broken, timeout

    public var id: String { rawValue }

    public var displayName: String {
        let raw: String
        switch self {
        case .ok: raw = "Correcto"
        case .redirect: raw = "Redirección"
        case .broken: raw = "Roto"
        case .timeout: raw = "Tiempo agotado"
        }
        return localizedDomain(raw)
    }
}

/// Modo de visualización del dashboard.
public enum ViewMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case bento, list

    public var id: String { rawValue }

    public var displayName: String {
        let raw: String
        switch self {
        case .bento: raw = "Bento"
        case .list: raw = "Lista"
        }
        return localizedDomain(raw)
    }

    public var sfSymbol: String {
        switch self {
        case .bento: "square.grid.2x2.fill"
        case .list: "list.bullet"
        }
    }
}

/// Densidad visual de la interfaz.
public enum ViewDensity: String, Codable, CaseIterable, Sendable, Identifiable {
    case compact, normal, comfortable

    public var id: String { rawValue }

    public var displayName: String {
        let raw: String
        switch self {
        case .compact: raw = "Compacta"
        case .normal: raw = "Normal"
        case .comfortable: raw = "Cómoda"
        }
        return localizedDomain(raw)
    }
}

/// Idioma de la aplicación.
public enum AppLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case es, en

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .es: "Español"
        case .en: "English"
        }
    }
}
