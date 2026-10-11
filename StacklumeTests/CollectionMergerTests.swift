import Testing
import Foundation

// `CollectionMerger.canonical` reduce un nombre de colección a una forma canónica para
// detectar equivalentes (case, acentos y un mapa de sinónimos/traducciones ES/EN). La
// fusión real toca SwiftData; aquí se cubre la parte determinista y pura.

@Suite("CollectionMerger — canonicalización de nombres")
struct CollectionMergerTests {

    @Test("Traducciones EN→ES caen en la misma forma canónica")
    func translations() {
        #expect(CollectionMerger.canonical("Development") == CollectionMerger.canonical("Desarrollo"))
        #expect(CollectionMerger.canonical("Coding") == CollectionMerger.canonical("desarrollo"))
        #expect(CollectionMerger.canonical("Programming") == CollectionMerger.canonical("Desarrollo"))
        #expect(CollectionMerger.canonical("Games") == CollectionMerger.canonical("Videojuegos"))
        #expect(CollectionMerger.canonical("Juegos") == CollectionMerger.canonical("videojuegos"))
        #expect(CollectionMerger.canonical("AI") == CollectionMerger.canonical("IA"))
    }

    @Test("Sinónimos/clústeres ampliados caen en la misma forma canónica")
    func extendedSynonyms() {
        // Videojuegos: singular, gaming, gamedev, «video games».
        #expect(CollectionMerger.canonical("Juego") == CollectionMerger.canonical("Videojuegos"))
        #expect(CollectionMerger.canonical("Gaming") == CollectionMerger.canonical("videojuegos"))
        #expect(CollectionMerger.canonical("video games") == CollectionMerger.canonical("Videojuegos"))
        // Herramientas: tools/herramienta/utilidades.
        #expect(CollectionMerger.canonical("Tools") == CollectionMerger.canonical("Herramientas"))
        #expect(CollectionMerger.canonical("Herramienta") == CollectionMerger.canonical("herramientas"))
        #expect(CollectionMerger.canonical("Utilidades") == CollectionMerger.canonical("Herramientas"))
        // Social: redes sociales / RRSS.
        #expect(CollectionMerger.canonical("Redes sociales") == CollectionMerger.canonical("Social"))
        #expect(CollectionMerger.canonical("RRSS") == CollectionMerger.canonical("social"))
        // Noticias / IA / Educación.
        #expect(CollectionMerger.canonical("News") == CollectionMerger.canonical("Noticias"))
        #expect(CollectionMerger.canonical("Machine Learning") == CollectionMerger.canonical("IA"))
        #expect(CollectionMerger.canonical("Cursos") == CollectionMerger.canonical("Educación"))
    }

    @Test("preferredDisplayName usa la grafía española «bonita» para términos conocidos")
    func preferredDisplay() {
        #expect(CollectionMerger.preferredDisplayName(for: "Juegos") == "Videojuegos")
        #expect(CollectionMerger.preferredDisplayName(for: "games") == "Videojuegos")
        #expect(CollectionMerger.preferredDisplayName(for: "development") == "Desarrollo")
        #expect(CollectionMerger.preferredDisplayName(for: "tools") == "Herramientas")
        #expect(CollectionMerger.preferredDisplayName(for: "redes sociales") == "Social")
        #expect(CollectionMerger.preferredDisplayName(for: "ai") == "IA")
    }

    @Test("preferredDisplayName conserva los nombres no reconocidos (recortados)")
    func preferredDisplayPreservesUnknown() {
        #expect(CollectionMerger.preferredDisplayName(for: "Marketing") == "Marketing")
        #expect(CollectionMerger.preferredDisplayName(for: "  Recetas veganas  ") == "Recetas veganas")
    }

    @Test("No singulariza palabras acabadas en s que no son plurales")
    func doesNotCorruptNonPluralWords() {
        #expect(CollectionMerger.canonical("Canvas") != CollectionMerger.canonical("Canva"))
        #expect(CollectionMerger.canonical("Analysis") == "analysis")
    }

    @Test("Insensible a mayúsculas y acentos")
    func caseAndAccents() {
        #expect(CollectionMerger.canonical("DISEÑO") == CollectionMerger.canonical("diseño"))
        #expect(CollectionMerger.canonical("Design") == CollectionMerger.canonical("Diseño"))
    }

    @Test("Nombres realmente distintos NO colisionan")
    func distinct() {
        #expect(CollectionMerger.canonical("Social") != CollectionMerger.canonical("Desarrollo"))
        #expect(CollectionMerger.canonical("Recetas") != CollectionMerger.canonical("Viajes"))
    }

    @Test("Los espacios al borde no afectan")
    func trimming() {
        #expect(CollectionMerger.canonical("  Desarrollo  ") == CollectionMerger.canonical("Desarrollo"))
    }
}
