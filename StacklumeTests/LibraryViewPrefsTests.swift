import Testing
import Foundation

// `LibraryViewPrefs`/`LibraryViewPrefsStore` se compilan dentro del módulo de tests.
// Verifica el round-trip JSON del diccionario `scope → preferencia de vista` que
// permite que CADA colección recuerde su modo y su tamaño de portada (paridad Raindrop).

@Suite("LibraryViewPrefs — preferencias de vista por sección")
struct LibraryViewPrefsTests {

    @Test("Round-trip: codificar y decodificar conserva el diccionario")
    func roundTrip() {
        let dict: [String: LibraryViewPref] = [
            "all": LibraryViewPref(mode: "moodboard", coverScale: 1.25),
            "collection:ABC": LibraryViewPref(mode: "list", coverScale: 1.0),
        ]
        let json = LibraryViewPrefsStore.encode(dict)
        #expect(!json.isEmpty)
        let back = LibraryViewPrefsStore.decode(json)
        #expect(back == dict)
        #expect(back["all"]?.mode == "moodboard")
        #expect(back["all"]?.coverScale == 1.25)
    }

    @Test("Cadena vacía decodifica a diccionario vacío (no rompe)")
    func emptyDecodes() {
        #expect(LibraryViewPrefsStore.decode("").isEmpty)
    }

    @Test("JSON inválido decodifica a diccionario vacío (tolerante)")
    func invalidDecodes() {
        #expect(LibraryViewPrefsStore.decode("{no es json").isEmpty)
    }

    @Test("Valor por defecto de coverScale es 1.0")
    func defaultCoverScale() {
        #expect(LibraryViewPref(mode: "grid").coverScale == 1.0)
    }
}
