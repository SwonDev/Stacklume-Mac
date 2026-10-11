import Foundation
import SwiftData
import StacklumeCore

/// Fusiona colecciones DUPLICADAS conceptualmente (p. ej. «Development» y «Desarrollo»,
/// «Juegos» y «Videojuegos»). La IA, al clasificar enlaces importados en inglés, puede
/// inventar una colección equivalente a una que ya existe en español; esto las reúne.
///
/// La equivalencia se decide por una forma CANÓNICA (minúsculas, sin acentos, + un mapa
/// pequeño de sinónimos/traducciones MUY comunes). Conservador a propósito: solo mapea
/// casos claros para no fusionar colecciones que el usuario quiere separadas.
@MainActor
enum CollectionMerger {
    /// Forma canónica de un nombre de colección para detectar equivalentes. `nonisolated`:
    /// es lógica pura (sin estado), reutilizable desde cualquier actor y testeable.
    nonisolated static func canonical(_ name: String) -> String {
        let base = name.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Colapsa guiones y espacios internos para una clave estable.
        let whole = base.replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        // 1) El nombre COMPLETO en el mapa primero (captura frases: «machine learning», «ui ux»).
        if let syn = synonyms[whole] { return syn }
        // 2) PALABRA POR PALABRA: traduce/normaliza CADA token. Así «ai development», «ia
        //    development», «ai desarrollo» e «ia desarrollo» dan TODAS «ia desarrollo»; y singular/
        //    plural se unifican («ide»/«ides», «tool»/«tools»). Antes solo se miraba el nombre
        //    entero → cada combinación quedaba como una colección distinta (redundantes en inglés).
        let tokens = whole.components(separatedBy: " ").filter { !$0.isEmpty }
        var mapped: [String] = []
        for token in tokens {
            let m: String
            if let syn = synonyms[token] { m = syn }
            else if token.count > 3, token.hasSuffix("s") {      // plural conocido → singular
                let singular = String(token.dropLast())
                // Singularizar cualquier palabra era destructivo: «canvas» acababa como «canva»
                // y «recetas veganas» como «recetas vegana». Solo se hace cuando el singular está
                // en el vocabulario o es un término técnico explícitamente seguro.
                if let synonym = synonyms[singular] { m = synonym }
                else if safePluralStems.contains(singular) { m = singular }
                else { m = token }
            } else { m = token }
            // Dedup de tokens canónicos repetidos: «ux design» → [diseno, diseno] → [diseno]. Sin
            // esto, dos sinónimos del MISMO canónico en un nombre compuesto daban «diseno diseno»
            // (clave distinta de «diseno» → NO fusionaba) y «Diseño Diseño» como nombre mostrado.
            if !mapped.contains(m) { mapped.append(m) }
        }
        let joined = mapped.joined(separator: " ")
        // 3) Re-busca el COMPUESTO ya traducido por si quedó como una frase conocida.
        return synonyms[joined] ?? joined
    }

    /// Mapa de sinónimos/traducciones (ES·EN·PT) → forma canónica. Conservador a propósito:
    /// solo agrupa conceptos CLARAMENTE equivalentes; ante la duda, se deja separado para no
    /// fusionar colecciones que el usuario quiere distintas. Claves en forma plegada.
    nonisolated static let synonyms: [String: String] = [
        // Desarrollo / programación
        "development": "desarrollo", "dev": "desarrollo", "coding": "desarrollo",
        "programming": "desarrollo", "programacion": "desarrollo", "code": "desarrollo",
        // «software development» como FRASE (la IA a veces nombra así «Desarrollo»); «software» a
        // secas se deja FUERA: una colección «Software» (apps para usar) es legítima y distinta de
        // «Desarrollo» (código), no se deben fusionar al arrancar.
        "software development": "desarrollo", "developer": "desarrollo", "devs": "desarrollo",
        "programa": "desarrollo", "desenvolvimento": "desarrollo",
        // Videojuegos
        "game": "videojuegos", "games": "videojuegos", "gaming": "videojuegos",
        "juego": "videojuegos", "juegos": "videojuegos", "videojuego": "videojuegos",
        "videogame": "videojuegos", "video game": "videojuegos", "video games": "videojuegos",
        "gamedev": "videojuegos", "steam": "videojuegos", "jogos": "videojuegos",
        // Diseño
        "design": "diseno", "ux": "diseno", "ui": "diseno", "ui ux": "diseno",
        // Vídeos
        "video": "video", "videos": "video", "pelicula": "video", "peliculas": "video",
        "movie": "video", "movies": "video", "cine": "video", "film": "video",
        "serie": "video", "series": "video",
        // IA
        "ai": "ia", "ml": "ia", "machine learning": "ia", "inteligencia artificial": "ia",
        "artificial intelligence": "ia", "llm": "ia", "deep learning": "ia",
        // Herramientas
        "tool": "herramientas", "tools": "herramientas", "herramienta": "herramientas",
        "utility": "herramientas", "utilities": "herramientas",
        "utilidad": "herramientas", "utilidades": "herramientas", "ferramenta": "herramientas",
        // Social
        // «redes» a secas se deja fuera (redes informáticas/networking ≠ redes sociales).
        "social media": "social", "redes sociales": "social", "red social": "social",
        "rrss": "social", "community": "social", "comunidad": "social",
        // Noticias
        "news": "noticias", "noticia": "noticias", "actualidad": "noticias", "prensa": "noticias",
        // Productividad
        "productivity": "productividad", "productivo": "productividad",
        // Música
        // «audio» a secas se deja fuera (ingeniería de audio, Web Audio… ≠ Música).
        "music": "musica", "cancion": "musica", "song": "musica",
        // Compras
        "shopping": "compras", "shop": "compras", "tienda": "compras", "compra": "compras",
        "ecommerce": "compras", "store": "compras",
        // Educación
        "education": "educacion", "learning": "educacion", "aprendizaje": "educacion",
        "course": "educacion", "courses": "educacion", "tutorial": "educacion",
        "curso": "educacion", "cursos": "educacion",
        // Lectura (leer después ≠ catálogo de libros)
        "reading": "lectura", "read later": "lectura", "leer mas tarde": "lectura",
        "por leer": "lectura", "leer": "lectura",
        // Libros
        "book": "libros", "books": "libros", "libro": "libros", "ebook": "libros", "ebooks": "libros",
        // Finanzas
        "finance": "finanzas", "money": "finanzas", "dinero": "finanzas",
        "investing": "finanzas", "inversion": "finanzas", "banca": "finanzas",
        // Cripto
        "crypto": "cripto", "cryptocurrency": "cripto", "criptomoneda": "cripto",
        "bitcoin": "cripto", "blockchain": "cripto", "web3": "cripto",
        // Tecnología
        "tech": "tecnologia", "technology": "tecnologia", "gadget": "tecnologia",
        "hardware": "tecnologia", "tecnologico": "tecnologia",
        // Ciencia
        "science": "ciencia", "research": "ciencia", "investigacion": "ciencia",
        // Salud
        "health": "salud", "wellness": "salud", "bienestar": "salud", "medicina": "salud",
        "medicine": "salud",
        // Deporte
        "sport": "deporte", "sports": "deporte", "deportes": "deporte", "fitness": "deporte",
        "gym": "deporte", "ejercicio": "deporte",
        // Viajes
        "travel": "viajes", "viaje": "viajes", "trip": "viajes", "trips": "viajes",
        "turismo": "viajes",
        // Recetas / cocina
        "recipe": "recetas", "receta": "recetas", "cocina": "recetas", "cooking": "recetas",
        "food": "recetas", "comida": "recetas",
        // Fotografía
        "photography": "fotografia", "photo": "fotografia", "foto": "fotografia",
        "fotos": "fotografia", "fotografias": "fotografia",
        // «imagen»/«imágenes» a secas NO van aquí: una colección «Imágenes» (assets, capturas,
        // imágenes generadas por IA) es distinta de «Fotografía» y no debe fusionarse sin más.
        // Arte
        "art": "arte",
        // Moda
        "fashion": "moda",
        // Marketing
        "marketing": "marketing", "publicidad": "marketing", "ad": "marketing",
        "advertising": "marketing",
        // Negocios (≠ trabajo personal)
        "business": "negocios", "negocio": "negocios", "startup": "negocios",
        "emprendimiento": "negocios",
        // Trabajo
        "work": "trabajo", "job": "trabajo",
        // Podcasts
        "podcast": "podcasts",
        // Inspiración / ideas
        "inspiration": "inspiracion", "idea": "inspiracion", "ideas": "inspiracion",
        // Documentación / referencia
        "doc": "documentacion", "docs": "documentacion", "documentation": "documentacion",
        "documentacion": "documentacion", "documentos": "documentacion", "documento": "documentacion",
        "reference": "documentacion", "referencia": "documentacion",
        "manual": "documentacion", "guia": "documentacion", "guide": "documentacion",
    ]

    /// Plurales técnicos cuyo singular no colisiona con otra palabra conocida.
    nonisolated private static let safePluralStems: Set<String> = [
        "api", "framework", "ide", "library", "package", "sdk",
    ]

    /// Nombre de presentación preferido para una colección NUEVA. Si su forma canónica es un
    /// término conocido, usa la grafía española «bonita» (con tildes/mayúscula correctas) en
    /// vez de la entrada cruda; si no, conserva el nombre tal cual (recortado). Así se crea
    /// «Videojuegos»/«Desarrollo» desde el principio y nunca «Juegos»/«development».
    /// `nonisolated` y pura → reutilizable desde cualquier actor y testeable.
    /// Grafía «bonita» en español de cada término canónico (capitalizado, con tildes).
    nonisolated static let displayMap: [String: String] = [
        "desarrollo": "Desarrollo", "videojuegos": "Videojuegos", "diseno": "Diseño",
        "video": "Vídeos", "ia": "IA", "herramientas": "Herramientas", "social": "Social",
        "noticias": "Noticias", "productividad": "Productividad", "musica": "Música",
        "compras": "Compras", "educacion": "Educación", "lectura": "Lectura",
        "finanzas": "Finanzas", "libros": "Libros", "cripto": "Cripto",
        "tecnologia": "Tecnología", "ciencia": "Ciencia", "salud": "Salud",
        "deporte": "Deporte", "viajes": "Viajes", "recetas": "Recetas",
        "fotografia": "Fotografía", "arte": "Arte", "moda": "Moda", "marketing": "Marketing",
        "negocios": "Negocios", "trabajo": "Trabajo", "podcasts": "Podcasts",
        "inspiracion": "Inspiración", "documentacion": "Documentación",
    ]

    nonisolated static func preferredDisplayName(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let canon = canonical(trimmed)
        if let p = displayMap[canon] { return p }   // término simple conocido → grafía bonita
        let inputWords = trimmed.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        let allWordsKnown = inputWords.allSatisfy { word in
            if synonyms[word] != nil || displayMap[word] != nil { return true }
            guard word.count > 3, word.hasSuffix("s") else { return false }
            let singular = String(word.dropLast())
            return synonyms[singular] != nil || safePluralStems.contains(singular)
        }
        // Un compuesto parcialmente desconocido es un nombre del usuario, no una frase para
        // «traducir» ni capitalizar. Se conserva exactamente (salvo espacios exteriores).
        guard allWordsKnown else { return trimmed }
        // Compuesto («ia desarrollo»): traduce CADA palabra a su grafía bonita en español (o
        // capitaliza). Así «AI Development»/«IA Development» se muestran como «IA Desarrollo».
        let words = canon.components(separatedBy: " ").filter { !$0.isEmpty }
        if words.count > 1 {
            return words.map { displayMap[$0] ?? $0.capitalized }.joined(separator: " ")
        }
        return trimmed
    }

    /// Fusiona las colecciones activas que comparten forma canónica: conserva la que más
    /// enlaces tiene (desempate: la de menor `order`), le mueve los enlaces de las demás y
    /// borra las duplicadas. Devuelve cuántas colecciones se eliminaron.
    @discardableResult
    static func mergeDuplicates(in context: ModelContext) -> Int {
        guard let all = try? context.fetch(FetchDescriptor<BookmarkCategory>()) else { return 0 }
        let active = all.filter { $0.deletedAt == nil }
        var groups: [String: [BookmarkCategory]] = [:]
        for category in active { groups[canonical(category.name), default: []].append(category) }

        var removed = 0
        for (_, group) in groups where group.count > 1 {
            guard let winner = group.sorted(by: {
                $0.links.count != $1.links.count
                    ? $0.links.count > $1.links.count
                    : $0.order < $1.order
            }).first else { continue }
            for loser in group where loser.id != winner.id {
                // Mueve los enlaces a la ganadora (copia el array: la relación se muta).
                for link in Array(loser.links) { link.category = winner }
                // Reasigna las subcolecciones de la perdedora a la ganadora.
                for child in Array(loser.children) { child.parent = winner }
                context.delete(loser)
                removed += 1
            }
            // La ganadora adopta la grafía PREFERIDA en español (p. ej. «IA Development» → «IA
            // Desarrollo», «IDEs» → «IDE»): así no queda el nombre en inglés del más votado.
            let pretty = preferredDisplayName(for: winner.name)
            if winner.name != pretty { winner.name = pretty }
        }
        if removed > 0 { context.saveLogging() }
        return removed
    }
}
