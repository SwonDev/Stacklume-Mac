import Foundation
import Testing

@Suite("DroppedContentImporter — captura segura desde Finder")
struct DroppedContentImporterTests {
    @Test("Decodifica una ubicación .webloc válida")
    func decodesWebloc() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["URL": "https://example.com/guía?utm_source=finder"],
            format: .binary,
            options: 0
        )

        let url = DroppedContentImporter.internetLocationURL(
            from: data,
            fileExtension: "webloc"
        )

        #expect(url?.host() == "example.com")
        #expect(url?.path == "/guía")
    }

    @Test("Decodifica un acceso directo .url de Windows")
    func decodesWindowsInternetShortcut() {
        let data = Data("[InternetShortcut]\r\nURL=https://openai.com/research\r\n".utf8)

        let url = DroppedContentImporter.internetLocationURL(from: data, fileExtension: "url")

        #expect(url?.absoluteString == "https://openai.com/research")
    }

    @Test("Rechaza esquemas locales o ejecutables")
    func rejectsUnsafeSchemes() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["URL": "file:///Applications/Utilities/Terminal.app"],
            format: .xml,
            options: 0
        )

        #expect(DroppedContentImporter.validatedWebURL("javascript:alert(1)") == nil)
        #expect(DroppedContentImporter.internetLocationURL(
            from: data,
            fileExtension: "webloc"
        ) == nil)
    }

    @Test("Solo acepta HTTP/HTTPS con host")
    func validatesWebURLs() {
        #expect(DroppedContentImporter.validatedWebURL("https://example.org/a") != nil)
        #expect(DroppedContentImporter.validatedWebURL("http://localhost:8080/a") != nil)
        #expect(DroppedContentImporter.validatedWebURL("https:///sin-host") == nil)
        #expect(DroppedContentImporter.validatedWebURL("ftp://example.org/a") == nil)
        #expect(DroppedContentImporter.validatedWebURL("httpx://example.org/a") == nil)
        #expect(DroppedContentImporter.validatedWebURL("https://usuario:secreto@example.org") == nil)
    }
}
