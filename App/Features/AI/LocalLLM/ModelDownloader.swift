import Foundation

/// Descarga los archivos de un modelo de Hugging Face con `URLSession` (progreso
/// real por bytes), a un directorio local. Sustituye al descargador de
/// swift-huggingface, que en iOS crea la estructura pero no baja los archivos.
actor ModelDownloader {
    private static let maximumManifestBytes = 8 * 1_024 * 1_024
    private static let maximumFileCount = 4_096
    private static let maximumFileBytes: Int64 = 32 * 1_024 * 1_024 * 1_024
    private static let maximumModelBytes: Int64 = 64 * 1_024 * 1_024 * 1_024

    struct RemoteFile: Sendable {
        let name: String
        let size: Int64
    }

    enum DownloadError: LocalizedError {
        case badFileList
        case fileFailed(String)
        var errorDescription: String? {
            switch self {
            case .badFileList: "No se pudo obtener la lista de archivos del modelo."
            case .fileFailed(let f): "Fallo al descargar \(f)."
            }
        }
    }

    /// Lista los archivos del repo (con tamaño) vía la API pública de HF.
    func fileList(repoID: String, revision: String? = nil) async throws -> [RemoteFile] {
        guard Self.isValidRepositoryID(repoID),
              revision == nil || Self.isValidRevision(revision!),
              let encodedRepo = repoID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://huggingface.co/api/models/\(encodedRepo)\(revision.map { "/revision/" + $0 } ?? "")?blobs=true")
        else {
            throw DownloadError.badFileList
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        guard let result = try? await ExternalHTTPClient.shared.data(
            for: request,
            maximumBytes: Self.maximumManifestBytes,
            allowedMIMEPrefixes: ["application/json"]
        ),
        let info = try? JSONDecoder().decode(ModelInfo.self, from: result.data),
        info.siblings.count <= Self.maximumFileCount else {
            throw DownloadError.badFileList
        }
        // Solo los archivos necesarios para inferencia (excluye git/README/licencia).
        let excluded = [".gitattributes", "README.md", "LICENSE"]
        let files = info.siblings
            .filter { !excluded.contains($0.rfilename) && !$0.rfilename.hasSuffix(".md") }
            .compactMap { sibling -> RemoteFile? in
                guard let size = sibling.size,
                      size >= 0,
                      size <= Self.maximumFileBytes,
                      Self.isSafeRelativePath(sibling.rfilename)
                else {
                    return nil
                }
                return RemoteFile(name: sibling.rfilename, size: size)
            }
        guard files.count == info.siblings.filter({
            !excluded.contains($0.rfilename) && !$0.rfilename.hasSuffix(".md")
        }).count else {
            throw DownloadError.badFileList
        }
        return files
    }

    /// Descarga el modelo al directorio `dir` (creándolo). Reporta progreso 0–1
    /// ponderado por bytes. Salta archivos ya descargados con el tamaño correcto.
    func download(repoID: String, revision: String? = nil, to dir: URL,
                  progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        let files = try await fileList(repoID: repoID, revision: revision)
        guard !files.isEmpty else { throw DownloadError.badFileList }
        try PrivateFileIO.ensureDirectory(dir)

        let totalBytes = try Self.totalSize(of: files)
        var completedBytes: Int64 = 0

        for file in files {
            // Defensa contra path traversal: el nombre viene del JSON de Hugging Face;
            // rechaza rutas con ".." o absolutas, y verifica que el destino queda DENTRO
            // del directorio del modelo.
            guard Self.isSafeRelativePath(file.name) else {
                throw DownloadError.fileFailed(file.name)
            }
            let dest = dir.appendingPathComponent(file.name)
            let rootPath = dir.standardizedFileURL.path.hasSuffix("/")
                ? dir.standardizedFileURL.path
                : dir.standardizedFileURL.path + "/"
            guard dest.standardizedFileURL.path.hasPrefix(rootPath) else {
                throw DownloadError.fileFailed(file.name)
            }
            // ¿Ya descargado con el tamaño correcto? → saltar.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
               let existing = attrs[.size] as? Int64, file.size > 0, existing == file.size {
                completedBytes += file.size
                progress(Double(completedBytes) / Double(totalBytes))
                continue
            }
            // Subdirectorios si el nombre los tiene.
            try PrivateFileIO.ensureDirectory(dest.deletingLastPathComponent())

            guard let encodedRepo = repoID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let encodedName = file.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let fileURL = URL(
                    string: "https://huggingface.co/\(encodedRepo)/resolve/\(revision ?? "main")/\(encodedName)"
                  )
            else {
                throw DownloadError.fileFailed(file.name)
            }
            let base = completedBytes
            try await downloadFile(from: fileURL, to: dest, expectedSize: file.size) { written, _ in
                progress(Double(base + written) / Double(totalBytes))
            }
            completedBytes += file.size
            progress(Double(completedBytes) / Double(totalBytes))
        }
        return dir
    }

    /// Descarga un archivo con progreso por bytes (URLSessionDownloadTask + delegate).
    private func downloadFile(from url: URL, to destination: URL, expectedSize: Int64,
                              onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> Void {
        guard StacklumeAutomationPolicy.allowsAutomaticNetworkURL(url),
              let host = url.host(),
              await Task.detached(priority: .utility, operation: {
                  AssistantHostResolver.hasOnlyPublicAddresses(host)
              }).value
        else {
            throw DownloadError.fileFailed(destination.lastPathComponent)
        }
        try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(destination: destination,
                                            expectedSize: expectedSize,
                                            onProgress: onProgress, continuation: continuation)
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForResource = 3600   // hasta 1 h para archivos grandes
            config.waitsForConnectivity = true
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.urlCache = nil
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            delegate.session = session
            session.downloadTask(with: request).resume()
        }
    }

    private static func isValidRepositoryID(_ repoID: String) -> Bool {
        let parts = repoID.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, repoID.count <= 200 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return parts.allSatisfy {
            !$0.isEmpty && String($0).unicodeScalars.allSatisfy(allowed.contains)
        }
    }

    private static func isValidRevision(_ revision: String) -> Bool {
        revision.count == 40 && revision.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("\\"),
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func totalSize(of files: [RemoteFile]) throws -> Int64 {
        var total: Int64 = 0
        for file in files {
            let (next, overflow) = total.addingReportingOverflow(file.size)
            guard !overflow, next <= maximumModelBytes else { throw DownloadError.badFileList }
            total = next
        }
        return max(total, 1)
    }
}

private struct ModelInfo: Decodable {
    let siblings: [Sibling]
    struct Sibling: Decodable {
        let rfilename: String
        let size: Int64?
    }
}

/// Delegate de descarga: reporta progreso, mueve el archivo terminado al destino
/// y reanuda la continuation.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let expectedSize: Int64
    let onProgress: @Sendable (Int64, Int64) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    var session: URLSession?

    init(destination: URL, expectedSize: Int64,
         onProgress: @escaping @Sendable (Int64, Int64) -> Void,
         continuation: CheckedContinuation<Void, Error>) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.onProgress = onProgress
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if expectedSize > 0, totalBytesWritten > expectedSize {
            downloadTask.cancel()
            finish(throwing: ModelDownloader.DownloadError.fileFailed(destination.lastPathComponent))
            return
        }
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            let received = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            guard expectedSize == 0 ? received == 0 : received == expectedSize else {
                throw ModelDownloader.DownloadError.fileFailed(destination.lastPathComponent)
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
            finish()
        } catch {
            finish(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let destination = request.url,
              StacklumeAutomationPolicy.allowsAutomaticNetworkURL(destination),
              destination.host().map(AssistantHostResolver.hasOnlyPublicAddresses) == true,
              !(task.currentRequest?.url?.scheme?.lowercased() == "https"
                  && destination.scheme?.lowercased() != "https")
        else {
            completionHandler(nil)
            return
        }
        var safeRequest = request
        safeRequest.setValue(nil, forHTTPHeaderField: "Authorization")
        safeRequest.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        safeRequest.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(safeRequest)
    }

    private func finish(throwing error: Error? = nil) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
        session?.finishTasksAndInvalidate()
    }
}
