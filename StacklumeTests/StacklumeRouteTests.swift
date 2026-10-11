import Foundation
import Testing

@Suite("StacklumeRoute — deep links cerrados")
struct StacklumeRouteTests {
    @Test("Interpreta alta, sección y marcador exacto")
    func parsesSupportedRoutes() {
        let id = UUID()
        let add = URL(string: "stacklume://add?url=https%3A%2F%2Fexample.com%2Fguia")!
        let section = URL(string: "stacklume://section/inbox")!
        let bookmark = URL(string: "stacklume://bookmark/\(id.uuidString)")!

        #expect(StacklumeRoute.parse(add) == .add(URL(string: "https://example.com/guia")!))
        #expect(StacklumeRoute.parse(section) == .section("inbox"))
        #expect(StacklumeRoute.parse(bookmark) == .bookmark(id))
    }

    @Test("Mantiene la compatibilidad del widget con stacklume://open")
    func keepsWidgetCompatibility() {
        #expect(StacklumeRoute.parse(URL(string: "stacklume://open")!) == .favorites)
    }

    @Test("Admite el marcador exacto como query de open")
    func parsesOpenIdentifier() {
        let id = UUID()
        let route = StacklumeRoute.parse(URL(string: "stacklume://open?id=\(id.uuidString)")!)

        #expect(route == .bookmark(id))
    }

    @Test("Rechaza rutas y URLs externas no autorizadas")
    func rejectsUnknownRoutes() {
        #expect(StacklumeRoute.parse(URL(string: "https://example.com")!) == nil)
        #expect(StacklumeRoute.parse(URL(string: "stacklume://delete/all")!) == nil)
        #expect(StacklumeRoute.parse(URL(string: "stacklume://add?url=file:///tmp/a")!) == nil)
        #expect(StacklumeRoute.parse(
            URL(string: "stacklume://add?url=http%3A%2F%2F127.0.0.1%3A8080%2Fadmin")!
        ) == nil)
        #expect(StacklumeRoute.parse(
            URL(string: "stacklume://add?url=http%3A%2F%2Fservidor.local%2Fpanel")!
        ) == nil)
    }
}
