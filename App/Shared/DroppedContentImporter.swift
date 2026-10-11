import Foundation
import UniformTypeIdentifiers
import AVFoundation

/// Documento local ya leído y validado fuera del `MainActor`, listo para persistir.
struct PreparedDroppedDocument: Sendable, Equatable {
    let title: String
    let author: String?
    let kind: String
    let data: Data
}

struct DroppedContentRejection: Sendable, Equatable {
    let name: String
    let reason: String
}

/// Resultado inmutable de preparar un drop de Finder. Ningún `@Model` cruza actores.
struct DroppedContentPreparation: Sendable, Equatable {
    let webURLs: [URL]
    let documents: [PreparedDroppedDocument]
    let rejections: [DroppedContentRejection]
    let omittedItemCount: Int

    var handledCount: Int { webURLs.count + documents.count }
}

/// Prepara de forma segura enlaces y archivos soltados desde Finder.
///
/// El trabajo de disco y la validación de PDFs/imágenes/EPUB se ejecutan fuera del actor
/// principal. Los límites evitan que un drop accidental de una carpeta enorme o de
/// archivos desmesurados bloquee la ventana o agote la memoria.
enum DroppedContentImporter {
    static let maximumItemCount = 200
    static let maximumInternetLocationBytes = 1 * 1_024 * 1_024
    static let maximumAggregateDocumentBytes = 256 * 1_024 * 1_024
    static let maximumWebURLLength = 16_384

    static func prepare(_ urls: [URL]) async -> DroppedContentPreparation {
        let accepted = Array(urls.prefix(maximumItemCount))
        let omitted = max(0, urls.count - accepted.count)
        let task = Task.detached(priority: .userInitiated) {
            await prepareSynchronously(accepted, omittedItemCount: omitted)
        }
        return await task.value
    }

    /// Parseo autocontenido para poder cubrir con tests las ubicaciones de Internet
    /// de macOS (`.webloc`) y Windows (`.url`) sin tocar el sistema de archivos.
    static func internetLocationURL(from data: Data, fileExtension: String) -> URL? {
        switch fileExtension.lowercased() {
        case "webloc":
            guard data.count <= maximumInternetLocationBytes,
                  let propertyList = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                  ),
                  let dictionary = propertyList as? [String: Any],
                  let raw = dictionary["URL"] as? String else { return nil }
            return validatedWebURL(raw)
        case "url":
            guard data.count <= maximumInternetLocationBytes else { return nil }
            let encodings: [String.Encoding] = [.utf8, .utf16, .unicode, .windowsCP1252]
            guard let text = encodings.lazy.compactMap({ String(data: data, encoding: $0) }).first else {
                return nil
            }
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let separator = trimmed.firstIndex(of: "=") else { continue }
                let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
                guard key.caseInsensitiveCompare("URL") == .orderedSame else { continue }
                return validatedWebURL(String(trimmed[trimmed.index(after: separator)...]))
            }
            return nil
        default:
            return nil
        }
    }

    static func validatedWebURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maximumWebURLLength,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              let url = components.url else { return nil }
        return url
    }

    /// Lectura acotada compartida con el selector del editor. No confía únicamente en
    /// `fileSize`: algunos proveedores de archivos no lo informan o lo hacen tarde.
    static func documentData(from url: URL) -> Data? {
        boundedData(from: url, maximumBytes: DocumentTextExtractor.maximumInputBytes)
    }

    private static func prepareSynchronously(
        _ urls: [URL],
        omittedItemCount: Int
    ) async -> DroppedContentPreparation {
        var webURLs: [URL] = []
        var documents: [PreparedDroppedDocument] = []
        var rejections: [DroppedContentRejection] = []
        var seenWebKeys = Set<String>()
        var aggregateDocumentBytes = 0

        for url in urls {
            if Task.isCancelled { break }
            if let webURL = validatedWebURL(url.absoluteString) {
                appendWebURL(webURL, to: &webURLs, seenKeys: &seenWebKeys)
                continue
            }
            guard url.isFileURL else {
                rejections.append(.init(name: url.lastPathComponent, reason: "Esquema no compatible"))
                continue
            }

            let name = url.lastPathComponent.isEmpty ? "Archivo" : url.lastPathComponent
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                rejections.append(.init(name: name, reason: "Las carpetas no se importan"))
                continue
            }

            let fileExtension = url.pathExtension.lowercased()
            if fileExtension == "webloc" || fileExtension == "url" {
                guard (values?.fileSize ?? 0) <= maximumInternetLocationBytes,
                      let data = boundedData(from: url, maximumBytes: maximumInternetLocationBytes),
                      let webURL = internetLocationURL(from: data, fileExtension: fileExtension) else {
                    rejections.append(.init(name: name, reason: "Ubicación de Internet no válida"))
                    continue
                }
                appendWebURL(webURL, to: &webURLs, seenKeys: &seenWebKeys)
                continue
            }

            let type = UTType(filenameExtension: fileExtension)
            let kind: String?
            if type?.conforms(to: .pdf) == true {
                kind = "pdf"
            } else if type?.conforms(to: .image) == true {
                kind = "image"
            } else if type?.conforms(to: .epub) == true {
                kind = "epub"
            } else if type?.conforms(to: .audio) == true {
                kind = "audio"
            } else if type?.conforms(to: .movie) == true {
                kind = "video"
            } else {
                kind = nil
            }
            guard let kind else {
                rejections.append(.init(name: name, reason: "Tipo de archivo no compatible"))
                continue
            }

            let declaredSize = values?.fileSize ?? 0
            guard declaredSize <= DocumentTextExtractor.maximumInputBytes else {
                rejections.append(.init(
                    name: name,
                    reason: "Supera \(DocumentTextExtractor.maximumInputMegabytes) MB"
                ))
                continue
            }
            guard aggregateDocumentBytes + declaredSize <= maximumAggregateDocumentBytes else {
                rejections.append(.init(name: name, reason: "El lote supera el límite de memoria"))
                continue
            }
            let remainingBatchBytes = maximumAggregateDocumentBytes - aggregateDocumentBytes
            let maximumReadBytes = min(DocumentTextExtractor.maximumInputBytes, remainingBatchBytes)
            guard let data = boundedData(from: url, maximumBytes: maximumReadBytes), !data.isEmpty else {
                rejections.append(.init(name: name, reason: "No se pudo leer o supera el límite"))
                continue
            }
            guard aggregateDocumentBytes + data.count <= maximumAggregateDocumentBytes else {
                rejections.append(.init(name: name, reason: "El lote supera el límite de memoria"))
                continue
            }
            let epubMetadata: EPUBBookMetadata?
            do {
                if kind == "epub" {
                    epubMetadata = try EPUBDocumentReader.metadata(data: data)
                } else if kind == "audio" || kind == "video" {
                    let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: kind == "audio" ? .audio : .video)
                    guard !tracks.isEmpty else { throw DocumentTextExtractionError.invalidDocument }
                    epubMetadata = nil
                } else {
                    try DocumentTextExtractor.validate(data: data, kind: kind)
                    epubMetadata = nil
                }
            } catch {
                rejections.append(.init(name: name, reason: error.localizedDescription))
                continue
            }

            aggregateDocumentBytes += data.count
            let filenameTitle = url.deletingPathExtension().lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackTitle = kind == "epub" ? "Libro" : "Documento"
            let title = epubMetadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = title.flatMap { $0.isEmpty ? nil : $0 }
                ?? (filenameTitle.isEmpty ? fallbackTitle : filenameTitle)
            documents.append(.init(
                title: resolvedTitle,
                author: epubMetadata?.author,
                kind: kind,
                data: data
            ))
        }

        return DroppedContentPreparation(
            webURLs: webURLs,
            documents: documents,
            rejections: rejections,
            omittedItemCount: omittedItemCount
        )
    }

    private static func appendWebURL(
        _ url: URL,
        to urls: inout [URL],
        seenKeys: inout Set<String>
    ) {
        let key = CanonicalURL.key(url.absoluteString)
        if seenKeys.insert(key).inserted { urls.append(url) }
    }

    /// Lee como máximo `maximumBytes + 1`, incluso cuando el sistema de archivos no
    /// informa del tamaño. Evita materializar en memoria un archivo gigante disfrazado.
    private static func boundedData(from url: URL, maximumBytes: Int) -> Data? {
        guard maximumBytes > 0,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var data = Data()
        let chunkSize = 1 * 1_024 * 1_024
        do {
            while data.count <= maximumBytes {
                let remaining = maximumBytes - data.count + 1
                guard let chunk = try handle.read(upToCount: min(chunkSize, remaining)),
                      !chunk.isEmpty else { return data }
                data.append(chunk)
                if data.count > maximumBytes { return nil }
            }
            return data
        } catch {
            return nil
        }
    }
}
