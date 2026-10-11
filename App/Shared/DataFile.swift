import SwiftUI
import UniformTypeIdentifiers

/// Documento genérico de datos para exportar con `fileExporter`.
struct DataFile: FileDocument {
    static var readableContentTypes: [UTType] { writableContentTypes }
    /// DEBE incluir TODOS los tipos que se pasan a `fileExporter(contentType:)`. Si falta
    /// uno (antes faltaban CSV y Markdown), la exportación de ese formato falla o sale mal
    /// tipada porque `fileExporter` exige que el tipo esté entre los escribibles.
    static var writableContentTypes: [UTType] {
        var types: [UTType] = [.json, .html, .pdf, .commaSeparatedText, .plainText]
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        return types
    }
    var data: Data
    init(_ data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
