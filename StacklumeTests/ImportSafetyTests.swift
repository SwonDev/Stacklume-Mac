import Foundation
import Testing

@Suite("Importación — límites antes de escribir")
struct ImportSafetyTests {
    private func backup(categories: [[String: Any]] = [], tags: [[String: Any]] = [], extras: [String: Any]? = nil) throws -> Data {
        var value: [String: Any] = ["links": [], "categories": categories, "tags": tags, "rules": []]
        if let extras { value["extras"] = extras }
        return try JSONSerialization.data(withJSONObject: value)
    }

    @Test("Acepta copias antiguas, datos laterales y jerarquías ordinarias")
    func legitimateArchive() throws {
        let parent = UUID().uuidString, child = UUID().uuidString
        let data = try backup(categories: [["id": parent, "name": "Recursos"], ["id": child, "name": "Swift", "parentID": parent]],
                              extras: ["highlights": [["text": "Texto legítimo"]], "customCovers": [child: Data(repeating: 0, count: 3 * 1_024 * 1_024).base64EncodedString()]])
        try ImportSafety.validateBackup(data)
        try ImportSafety.validateBackup(backup())
    }

    @Test("Rechaza padres propios, ciclos y UUID repetidos sin depender del formato de UUID")
    func invalidHierarchies() throws {
        let a = UUID().uuidString, b = UUID().uuidString
        #expect(throws: ImportSafetyError.cyclicHierarchy) {
            try ImportSafety.validateBackup(backup(categories: [["id": a, "parentID": a.lowercased()]]))
        }
        #expect(throws: ImportSafetyError.cyclicHierarchy) {
            try ImportSafety.validateBackup(backup(tags: [["id": a, "parentID": b], ["id": b, "parentID": a]]))
        }
        #expect(throws: ImportSafetyError.duplicateIdentity) {
            try ImportSafety.validateBackup(backup(categories: [["id": a], ["id": a.lowercased()]]))
        }
    }

    @Test("El preflight interpreta escapes y rechaza claves repetidas o profundidad excesiva")
    func lexicalLimits() throws {
        try ImportSafety.preflightJSON(Data(#"{"title":"Texto con [ ] { } y \"comillas\""}"#.utf8))
        #expect(throws: ImportSafetyError.invalidStructure) {
            try ImportSafety.preflightJSON(Data(#"{"links":[],"\u006cinks":[]}"#.utf8))
        }
        let deep = String(repeating: "[", count: ImportSafety.maximumDepth + 1) + "0" + String(repeating: "]", count: ImportSafety.maximumDepth + 1)
        #expect(throws: ImportSafetyError.limitExceeded) { try ImportSafety.preflightJSON(Data(deep.utf8)) }
    }

    @Test("Rechaza campos excesivos y conserva CSV RFC 4180")
    func csvLimitsAndControl() throws {
        #expect(try BoundedCSVImporter.parse("url,title\nhttps://example.com,\"Dos, palabras\ncon \"\"comillas\"\"\"\n") == [
            ["url", "title"], ["https://example.com", "Dos, palabras\ncon \"comillas\""]
        ])
        #expect(try BoundedCSVImporter.parse("url,title\r\nhttps://example.com,Título\r\n") == [
            ["url", "title"], ["https://example.com", "Título"]
        ])
        #expect(throws: ImportSafetyError.limitExceeded) {
            try BoundedCSVImporter.parse(String(repeating: "x", count: ImportSafety.maximumFieldBytes + 1))
        }
        #expect(throws: ImportSafetyError.limitExceeded) {
            try BoundedCSVImporter.parse(Array(repeating: "x", count: 257).joined(separator: ","))
        }
        #expect(throws: ImportSafetyError.invalidStructure) { try BoundedCSVImporter.parse("\"sin cerrar") }
    }

    @Test("Rechaza un lote completo antes de aceptar títulos desmesurados")
    func bookmarkLimits() {
        #expect(throws: ImportSafetyError.limitExceeded) {
            try ImportSafety.validateBookmarks([.init(url: "https://example.com", title: String(repeating: "a", count: ImportSafety.maximumShortFieldBytes + 1), folder: "")])
        }
    }

    @Test("La profundidad acumulada no se reinicia al alcanzar una rama ya visitada")
    func sharedParentDepth() {
        var parents: [String: String] = [:]
        for n in 0...ImportSafety.maximumDepth { parents["\(n)"] = "\(n + 1)" }
        #expect(throws: ImportSafetyError.limitExceeded) { try ImportSafety.validateParents(parents) }
    }

    @Test("HTML profundo y campos enormes rechazan todo el archivo")
    func htmlBoundaries() {
        let html = String(repeating: "<H3>Carpeta</H3>", count: ImportSafety.maximumDepth + 1) + "<A HREF=\"https://example.com\">Enlace</A>"
        #expect(throws: ImportSafetyError.limitExceeded) { try NetscapeHTMLImporter.parseChecked(html) }
        #expect(NetscapeHTMLImporter.parse(html).isEmpty)
    }

    @Test("Chromium conserva las carpetas y rechaza el archivo profundo completo")
    func chromiumPreflight() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Bookmarks")
        let valid = #"{"roots":{"bookmark_bar":{"type":"folder","children":[{"type":"folder","name":"Recursos","children":[{"type":"url","name":"Swift","url":"https://swift.org"}]}]}}}"#
        try Data(valid.utf8).write(to: file)
        let browser = DetectedBrowser(browser: .chrome, fileURLs: [file], count: 1)
        #expect(try BrowserImporter.parseChecked(browser) == [.init(url: "https://swift.org", title: "Swift", folder: "Recursos")])
        let deep = String(repeating: "[", count: ImportSafety.maximumDepth + 1) + "0" + String(repeating: "]", count: ImportSafety.maximumDepth + 1)
        try Data(deep.utf8).write(to: file)
        #expect(throws: ImportSafetyError.limitExceeded) { try BrowserImporter.parseChecked(browser) }
        #expect(BrowserImporter.parse(browser).isEmpty)
    }
}
