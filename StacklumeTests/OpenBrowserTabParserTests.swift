import Foundation
import Testing

@Suite("OpenBrowserTabParser — pestañas seguras")
struct OpenBrowserTabParserTests {
    @Test("Decodifica HTTP/HTTPS, descarta esquemas internos y ordena por ventana")
    func decodesAndFilters() throws {
        let data = Data(#"""
        [
          {"title":"Segunda","url":"https://example.com/b","windowIndex":2,"tabIndex":1,"isActive":false},
          {"title":"","url":"https://www.example.org/a","windowIndex":1,"tabIndex":2,"isActive":true},
          {"title":"Ajustes","url":"brave://settings","windowIndex":1,"tabIndex":1,"isActive":false}
        ]
        """#.utf8)

        let tabs = try OpenBrowserTabParser.decode(
            data,
            browserID: "brave",
            browserName: "Brave",
            browserIcon: "globe"
        )

        #expect(tabs.count == 2)
        #expect(tabs[0].title == "example.org")
        #expect(tabs[0].isActive)
        #expect(tabs[1].title == "Segunda")
    }

    @Test("Deduplica variantes canónicas dentro del mismo navegador")
    func deduplicatesWithinBrowser() throws {
        let data = Data(#"""
        [
          {"title":"Una","url":"http://www.example.com/page?utm_source=x","windowIndex":1,"tabIndex":1,"isActive":true},
          {"title":"Otra","url":"https://example.com/page","windowIndex":1,"tabIndex":2,"isActive":false}
        ]
        """#.utf8)

        let tabs = try OpenBrowserTabParser.decode(
            data,
            browserID: "safari",
            browserName: "Safari",
            browserIcon: "safari.fill"
        )

        #expect(tabs.count == 1)
        #expect(tabs[0].title == "Una")
    }

    @Test("Deduplica la misma página abierta en dos navegadores")
    func deduplicatesAcrossBrowsers() {
        let safari = tab(browserID: "safari", url: "https://example.com/article")
        let brave = tab(browserID: "brave", url: "http://www.example.com/article?utm_medium=tab")

        let tabs = OpenBrowserTabParser.deduplicated([safari, brave])

        #expect(tabs.count == 1)
        #expect(tabs[0].browserID == "safari")
    }

    @Test("Un JSON corrupto produce un error en vez de datos parciales")
    func rejectsCorruptJSON() {
        #expect(throws: (any Error).self) {
            try OpenBrowserTabParser.decode(
                Data("no es JSON".utf8),
                browserID: "safari",
                browserName: "Safari",
                browserIcon: "safari.fill"
            )
        }
    }

    @Test("Rechaza lotes desmesurados antes de construir la lista")
    func rejectsTooManyTabs() {
        let row = #"{"title":"Una","url":"https://example.com","windowIndex":1,"tabIndex":1}"#
        let data = Data(("["
            + Array(repeating: row, count: 2_001).joined(separator: ",")
            + "]").utf8)

        #expect(throws: OpenBrowserTabParserError.tooManyTabs) {
            try OpenBrowserTabParser.decode(
                data,
                browserID: "safari",
                browserName: "Safari",
                browserIcon: "safari.fill"
            )
        }
    }

    @Test("Acota títulos y aplica la validación canónica de URL")
    func boundsFieldsAndRejectsHiddenControls() throws {
        let longTitle = String(repeating: "á", count: 1_200)
        let data = try JSONSerialization.data(withJSONObject: [[
            "title": longTitle,
            "url": "https://example.com/article",
            "windowIndex": 1,
            "tabIndex": 1,
        ], [
            "title": "Inyectada",
            "url": "https://example.org/%250Aevil",
            "windowIndex": 1,
            "tabIndex": 2,
        ]])

        let tabs = try OpenBrowserTabParser.decode(
            data,
            browserID: "safari",
            browserName: "Safari",
            browserIcon: "safari.fill"
        )

        #expect(tabs.count == 1)
        #expect(tabs[0].title.count == 1_024)
    }

    private func tab(browserID: String, url: String) -> OpenBrowserTab {
        OpenBrowserTab(
            browserID: browserID,
            browserName: browserID,
            browserIcon: "globe",
            title: "Ejemplo",
            url: url,
            windowIndex: 1,
            tabIndex: 1,
            isActive: true
        )
    }
}
