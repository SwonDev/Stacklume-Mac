import Testing
import Foundation
import StacklumeCore

// `SearchQuery` se compila dentro del módulo de tests. Verifica el PARSEO de la barra
// de búsqueda con operadores estilo Raindrop: que el texto libre se separe bien de los
// operadores (que se aplican como post-filtro). Los predicados se ejercitan sobre
// `Bookmark` en la app; aquí se cubre la parte determinista (freeText + hasOperators).

@Suite("SearchQuery — operadores de búsqueda")
struct SearchQueryTests {

    @Test("Sin operadores: todo es texto libre")
    func plainText() {
        let q = SearchQuery.parse("swift testing")
        #expect(q.freeText == "swift testing")
        #expect(q.hasOperators == false)
    }

    @Test("type: se separa del texto libre")
    func typeOperator() {
        let q = SearchQuery.parse("type:video swift")
        #expect(q.freeText == "swift")
        #expect(q.hasOperators == true)
    }

    @Test("Solo operadores ⇒ texto libre vacío")
    func onlyOperators() {
        let q = SearchQuery.parse("title:zod -tag:old domain:github.com")
        #expect(q.freeText.isEmpty)
        #expect(q.hasOperators == true)
    }

    @Test("#etiqueta es un operador, no texto libre")
    func hashTag() {
        let q = SearchQuery.parse("#swiftui")
        #expect(q.freeText.isEmpty)
        #expect(q.hasOperators == true)
    }

    @Test("Palabra negada es predicado; la positiva queda como texto libre")
    func negatedWord() {
        let q = SearchQuery.parse("hello -world")
        #expect(q.freeText == "hello")
        #expect(q.hasOperators == true)
    }

    @Test("Operador con valor vacío cae a texto libre")
    func emptyOperatorValue() {
        let q = SearchQuery.parse("tag:")
        #expect(q.freeText == "tag:")
        #expect(q.hasOperators == false)
    }

    @Test("created: se separa; el resto es texto libre")
    func createdOperator() {
        let q = SearchQuery.parse("created:2026-06 react")
        #expect(q.freeText == "react")
        #expect(q.hasOperators == true)
    }

    @Test("created: admite rango A..B como un solo operador")
    func createdRange() {
        let q = SearchQuery.parse("created:2026-01..2026-06 swift")
        #expect(q.freeText == "swift")
        #expect(q.hasOperators == true)
    }

    @Test("Cadena vacía o solo espacios ⇒ sin nada")
    func emptyInput() {
        let q = SearchQuery.parse("   ")
        #expect(q.freeText.isEmpty)
        #expect(q.hasOperators == false)
    }

    @Test("Encuentra texto que solo existe en el contenido OCR")
    func matchesOfflineDocumentText() {
        let link = Bookmark(url: "", title: "Factura escaneada", contentType: .document)
        link.offlineText = "Detalle de facturación del proyecto Atlántico"

        #expect(SearchQuery.parse("facturacion atlantico").lexicalMatches(link))
        #expect(SearchQuery.parse("-facturación").lexicalMatches(link) == false)
    }
}
