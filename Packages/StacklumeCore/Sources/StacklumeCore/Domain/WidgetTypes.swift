import Foundation

/// Tipo de widget del dashboard. Catálogo curado y enfocado en la gestión de
/// enlaces (más notas y un par de utilidades que encajan con la app).
public enum WidgetType: String, Codable, CaseIterable, Sendable, Identifiable {
    // Enlaces y datos de la biblioteca
    case favorites
    case recent
    case categoryLinks
    case tagCloud
    case readingQueue
    case weeklyDigest
    case linkStats
    // Descubrir (desarrollo)
    case githubTrending
    case repoPosts
    case hackerNews
    case devArticles
    // Juegos
    case steamDeals
    case freeGames
    case steamSpotlight
    case appStoreDeals
    // Productividad / utilidades relacionadas con los enlaces
    case note
    case quickActions
    case passwordGenerator
    case qrCode

    public var id: String { rawValue }

    public var displayName: String {
        let raw: String
        switch self {
        case .favorites: raw = "Favoritos"
        case .recent: raw = "Recientes"
        case .categoryLinks: raw = "Categoría"
        case .tagCloud: raw = "Nube de etiquetas"
        case .readingQueue: raw = "Cola de lectura"
        case .weeklyDigest: raw = "Destacados de la semana"
        case .linkStats: raw = "Estadísticas"
        case .githubTrending: raw = "GitHub Trending"
        case .repoPosts: raw = "MAGI//ARCHIVE"
        case .hackerNews: raw = "Hacker News"
        case .devArticles: raw = "Artículos dev"
        case .steamDeals: raw = "Ofertas de Steam"
        case .freeGames: raw = "Juegos gratis"
        case .steamSpotlight: raw = "Steam: destacados"
        case .appStoreDeals: raw = "Ofertas App Store"
        case .note: raw = "Nota"
        case .quickActions: raw = "Accesos rápidos"
        case .passwordGenerator: raw = "Generador de contraseñas"
        case .qrCode: raw = "Código QR"
        }
        return localizedDomain(raw)
    }

    public var sfSymbol: String {
        switch self {
        case .favorites: "star.fill"
        case .recent: "clock.arrow.circlepath"
        case .categoryLinks: "folder.fill"
        case .tagCloud: "tag.fill"
        case .readingQueue: "book.fill"
        case .weeklyDigest: "calendar.badge.clock"
        case .linkStats: "chart.bar.xaxis"
        case .githubTrending: "flame.fill"
        case .repoPosts: "binoculars.fill"
        case .hackerNews: "newspaper.fill"
        case .devArticles: "doc.richtext.fill"
        case .steamDeals: "gamecontroller.fill"
        case .freeGames: "gift.fill"
        case .steamSpotlight: "crown.fill"
        case .appStoreDeals: "arrow.down.circle.fill"
        case .note: "note.text"
        case .quickActions: "bolt.fill"
        case .passwordGenerator: "key.fill"
        case .qrCode: "qrcode"
        }
    }

    public var defaultSize: WidgetSize {
        switch self {
        case .tagCloud, .linkStats, .quickActions: .wide
        case .passwordGenerator, .githubTrending, .repoPosts, .hackerNews,
             .devArticles, .steamDeals, .freeGames, .steamSpotlight, .appStoreDeals: .large
        default: .medium
        }
    }

    /// `true` si el widget muestra contenido externo en vivo (desarrollo/juegos)
    /// que se puede ampliar a pantalla completa (doble toque) para navegarlo,
    /// ordenarlo y guardar elementos en la biblioteca.
    public var isDiscover: Bool {
        switch self {
        case .githubTrending, .repoPosts, .hackerNews, .devArticles,
             .steamDeals, .freeGames, .steamSpotlight, .appStoreDeals: true
        default: false
        }
    }

    /// Categoría del widget (para agrupar en el selector).
    public var group: String {
        let raw: String
        switch self {
        case .favorites, .recent, .categoryLinks, .readingQueue, .tagCloud,
             .weeklyDigest, .linkStats:
            raw = "Enlaces"
        case .githubTrending, .repoPosts, .hackerNews, .devArticles: raw = "Descubrir"
        case .steamDeals, .freeGames, .steamSpotlight, .appStoreDeals: raw = "Juegos"
        case .note: raw = "Productividad"
        case .quickActions, .passwordGenerator, .qrCode: raw = "Utilidades"
        }
        return localizedDomain(raw)
    }

    /// Descripción breve mostrada en el selector de widgets.
    public var summary: String {
        let raw: String
        switch self {
        case .favorites: raw = "Tus enlaces marcados como favoritos."
        case .recent: raw = "Los últimos enlaces que has guardado."
        case .categoryLinks: raw = "Enlaces de una categoría concreta."
        case .tagCloud: raw = "Tus etiquetas para filtrar rápido."
        case .readingQueue: raw = "Enlaces pendientes de leer."
        case .weeklyDigest: raw = "Los enlaces que guardaste esta semana."
        case .linkStats: raw = "Resumen: total, sin leer y favoritos."
        case .githubTrending: raw = "Repos de GitHub en tendencia esta semana."
        case .repoPosts: raw = "Repos curados de MAGI//ARCHIVE (tom-doerr)."
        case .hackerNews: raw = "Las historias top de Hacker News."
        case .devArticles: raw = "Artículos técnicos populares de dev.to."
        case .steamDeals: raw = "Ofertas de Steam que puedes ordenar por descuento, precio o valoración."
        case .freeGames: raw = "Juegos gratis por tiempo limitado (Steam, Epic, GOG…)."
        case .steamSpotlight: raw = "Top ventas, novedades y ofertas destacadas de Steam."
        case .appStoreDeals: raw = "Bajadas de precio de apps y juegos de pago de la App Store."
        case .note: raw = "Una nota rápida en el dashboard."
        case .quickActions: raw = "Atajos para añadir, buscar y ver favoritos."
        case .passwordGenerator: raw = "Genera contraseñas seguras al instante."
        case .qrCode: raw = "Crea un QR a partir de cualquier enlace."
        }
        return localizedDomain(raw)
    }
}

/// Tamaño de un widget en la rejilla de 2 columnas (adaptado a iPhone).
public enum WidgetSize: String, Codable, CaseIterable, Sendable, Identifiable {
    case small        // 1 columna
    case medium       // 2 columnas, alto medio
    case large        // 2 columnas, alto grande
    case wide         // 2 columnas, alto bajo
    case extraLarge   // 2 columnas, alto extra (aprovecha el espacio vertical)

    public var id: String { rawValue }

    public var displayName: String {
        let raw: String
        switch self {
        case .small: raw = "Pequeño"
        case .medium: raw = "Mediano"
        case .large: raw = "Grande"
        case .wide: raw = "Ancho"
        case .extraLarge: raw = "Extra grande"
        }
        return localizedDomain(raw)
    }

    /// Columnas que ocupa (1 o 2) en una rejilla de 2 columnas.
    public var columnSpan: Int {
        self == .small ? 1 : 2
    }

    /// Altura aproximada en puntos. El pequeño es casi cuadrado (≈ media columna)
    /// y todos usan altura fija para que el redimensionado anime con suavidad.
    public var approxHeight: CGFloat {
        switch self {
        case .small: 162
        case .wide: 116
        case .medium: 180
        case .large: 320
        case .extraLarge: 470
        }
    }
}
