import Foundation

/// Elige un icono SF Symbol acorde al TEMA de una categoría por su nombre (es/en),
/// para que las categorías creadas por IA no salgan todas con el mismo «folder.fill».
enum CategoryIcon {
    private static let map: [(keys: [String], symbol: String)] = [
        (["videojuego", "juego", "game", "gaming", "steam", "consola"], "gamecontroller.fill"),
        (["tecnolog", "tech", "gadget", "hardware", "dispositiv"], "cpu"),
        (["desarrollo", "program", "código", "code", "dev", "software", "api"], "chevron.left.forwardslash.chevron.right"),
        (["diseño", "design", "ux", "ui", "arte", "art"], "paintbrush.pointed.fill"),
        (["música", "music", "canción", "audio", "podcast"], "music.note"),
        (["vídeo", "video", "película", "movie", "cine", "film", "youtube", "serie"], "play.rectangle.fill"),
        (["noticia", "news", "actualidad", "prensa"], "newspaper.fill"),
        (["receta", "cocina", "comida", "food", "recipe"], "fork.knife"),
        (["deporte", "sport", "fitness", "gym", "ejercicio"], "figure.run"),
        (["viaje", "travel", "turismo", "vuelo", "hotel"], "airplane"),
        (["compra", "shopping", "tienda", "shop", "ecommerce", "producto"], "cart.fill"),
        (["oferta", "descuento", "deal", "rebaja", "promo", "promoción", "ganga", "chollo", "berraka"], "tag.fill"),
        (["regalo", "gift", "obsequio"], "gift.fill"),
        (["educa", "curso", "course", "learn", "aprend", "tutorial"], "graduationcap.fill"),
        (["salud", "health", "médic", "medic"], "heart.fill"),
        (["finanz", "dinero", "money", "banco", "invers", "cripto", "crypto"], "dollarsign.circle.fill"),
        (["libro", "book", "lectura", "read", "novela"], "book.fill"),
        (["foto", "photo", "imagen", "cámara", "camera"], "camera.fill"),
        (["trabajo", "work", "negocio", "business", "productiv"], "briefcase.fill"),
        (["social", "twitter", "instagram", "comunidad"], "person.2.fill"),
        (["ciencia", "science", "investiga", "research"], "atom"),
        (["herramient", "tool", "utilidad"], "wrench.and.screwdriver.fill"),
        (["moda", "fashion", "ropa", "estilo"], "tshirt.fill"),
        (["marketing", "publicidad", "advertis"], "megaphone.fill"),
        (["podcast"], "mic.fill"),
        (["cripto", "crypto", "bitcoin", "blockchain", "web3"], "bitcoinsign.circle.fill"),
        (["inteligencia artificial", "machine learning", "llm"], "brain.head.profile"),
        (["inspiración", "inspiration", "idea"], "lightbulb.fill"),
        (["documenta", "docs", "referencia", "manual", "guía"], "doc.text.fill")
    ]

    /// Devuelve un SF Symbol acorde al nombre de la categoría (o «folder.fill»).
    static func symbol(for name: String) -> String {
        let n = name.lowercased()
        for entry in map where entry.keys.contains(where: { n.contains($0) }) {
            return entry.symbol
        }
        return "folder.fill"
    }
}

extension String {
    /// Color (hex) determinista derivado del nombre, tomado de `ColorPresets`. Se usa
    /// al CREAR una categoría/etiqueta para fijar su color (luego se persiste en
    /// `colorHex`). Centraliza la lógica que antes estaba duplicada en varias vistas.
    var deterministicColorHex: String {
        let count = ColorPresets.all.count
        // Hash estable djb2 sobre los bytes UTF-8: determinista entre arranques
        // (a diferencia de `String.hashValue`, que usa una semilla aleatoria por proceso).
        var h: UInt64 = 5381
        for b in utf8 { h = (h &* 33) &+ UInt64(b) }
        return ColorPresets.all[Int(h % UInt64(count))]
    }

    /// Extrae el host legible de una URL (sin "www.").
    var urlHost: String {
        guard let url = URL(string: self), let host = url.host() else {
            return self
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
