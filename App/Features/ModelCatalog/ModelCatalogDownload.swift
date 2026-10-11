import Foundation
import CryptoKit

struct ModelCatalogDownloadSelection: Identifiable, Sendable {
    let id = UUID()
    let provider: ModelCatalogProvider
    let url: URL
    let filename: String
    var expectedBytes: Int64?
    var sizeIsApproximate = false
    var sha256: String?
    var sourceURL: URL?
    var license = ""

    static func file(_ file: ModelCatalogFile, model: ModelCatalogItem, version: ModelCatalogVersion) -> Self? {
        guard let url = ModelCatalogRequest.fileDownloadURL(model: model, version: version, file: file) else { return nil }
        return .init(provider: model.provider, url: url, filename: URL(fileURLWithPath: file.name).lastPathComponent, expectedBytes: file.sizeBytes, sizeIsApproximate: file.sizeIsApproximate, sha256: file.sha256, sourceURL: model.bookmarkURL(version: version), license: model.licenses(for: version).joined(separator: ", "))
    }
    static func sample(_ sample: ModelCatalogPreview, provider: ModelCatalogProvider) -> Self? {
        guard let url = ModelCatalogRequest.downloadInitialURL((sample.originalURL ?? sample.fullSizeURL ?? sample.url).absoluteString, provider: provider) else { return nil }
        let ext = sample.kind == .video ? "mp4" : sample.kind == .audio ? "m4a" : "jpg"
        let name = url.lastPathComponent.isEmpty ? "muestra" : url.lastPathComponent
        return .init(provider: provider, url: url, filename: URL(fileURLWithPath: name).pathExtension.isEmpty ? name + "." + ext : name, sourceURL: sample.sourceURL)
    }
}

struct ModelCatalogDownloadProgress: Sendable { let received: Int64; let expected: Int64? }

enum ModelCatalogDownloadError: LocalizedError {
    case insufficientSpace, sizeMismatch, checksumMismatch, redirectedAccess, invalidFile, busy
    var errorDescription: String? {
        switch self {
        case .insufficientSpace: "No hay espacio suficiente en el disco elegido para este archivo."
        case .sizeMismatch: "El tamaño descargado no coincide con los metadatos del proveedor. El archivo no se ha guardado."
        case .checksumMismatch: "La huella SHA-256 no coincide con la publicada. El archivo no se ha guardado."
        case .redirectedAccess: "El proveedor ha redirigido la descarga a una página de acceso o a un almacenamiento todavía no permitido. Comprueba los permisos y términos en la fuente original."
        case .invalidFile: "El proveedor devolvió una página de error en lugar del archivo."
        case .busy: "Hay dos descargas en curso. Espera a que termine una o cancélala antes de añadir otra."
        }
    }
}

enum ModelCatalogDownloads {
    static let capacity = ModelCatalogCapacityLedger()
    private static let store = StagingStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Stacklume/ModelCatalogDownloads", isDirectory: true))
    static func purgeOnLaunch() { store.purge() }
    static func purgeOnTermination() { store.purge() }

    static func download(_ selection: ModelCatalogDownloadSelection, to destination: URL, request: URLRequest, progress: @escaping @Sendable (ModelCatalogDownloadProgress) -> Void) async throws -> URL {
        guard destination.isFileURL, request.url == selection.url, request.value(forHTTPHeaderField: "Cookie") == nil,
              ModelCatalogRequest.downloadInitialURL(selection.url.absoluteString, provider: selection.provider) != nil else { throw ModelCatalogError.unsafeURL }
        let parent = destination.deletingLastPathComponent()
        let values = try parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let filesystem = try FileManager.default.attributesOfFileSystem(forPath: parent.path)
        let available = values.volumeAvailableCapacityForImportantUsage ?? (filesystem[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard available > 0, selection.expectedBytes.map({ $0 >= 0 && $0 < available }) ?? true else { throw ModelCatalogDownloadError.insufficientSpace }
        let reservation = UUID()
        let volume = try parent.resourceValues(forKeys: [.volumeURLKey]).volume?.path ?? parent.path
        try capacity.reserve(reservation, volume: volume, remaining: selection.expectedBytes ?? 0, available: available)
        defer { capacity.release(reservation) }
        let stage = try store.reserve(beside: destination)
        defer { store.remove(stage) }
        let delegate = try ModelCatalogDownloadDelegate(selection: selection, destination: destination, stage: stage, availableBytes: available, reservation: reservation, progress: progress)
        store.register(stage) { delegate.cancel() }
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false; c.httpCookieStorage = nil; c.urlCredentialStorage = nil; c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData; c.timeoutIntervalForRequest = 45; c.timeoutIntervalForResource = 24 * 60 * 60
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: c, delegate: delegate, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { delegate.begin(session.dataTask(with: request), continuation: $0) }
        } onCancel: { delegate.cancel() }
    }

    struct Stage: Codable, Sendable {
        let id: UUID
        let directory: URL
        var file: URL { directory.appendingPathComponent("download.part") }
    }

    // Solo registra ubicaciones locales elegidas por el usuario, nunca URLs remotas
    // ni claves. La purga reconoce el UUID y no borra contenido ajeno.
    final class StagingStore: @unchecked Sendable {
        private let directory: URL
        private let lock = NSLock()
        private var active: [UUID: @Sendable () -> Void] = [:]
        init(directory: URL) { self.directory = directory }
        private var registry: URL { directory.appendingPathComponent("pending.json") }
        private func read() throws -> [Stage] {
            guard FileManager.default.fileExists(atPath: registry.path) else { return [] }
            guard (try registry.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 <= 65_536 else { throw ModelCatalogError.invalidResponse }
            let entries = try JSONDecoder().decode([Stage].self, from: Data(contentsOf: registry))
            guard entries.count <= 32, entries.allSatisfy({ $0.directory.isFileURL && $0.directory.lastPathComponent == ".stacklume-download-\($0.id.uuidString)" }) else { throw ModelCatalogError.invalidResponse }
            return entries
        }
        private func write(_ entries: [Stage]) throws {
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard (try directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw ModelCatalogError.unsafeURL }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try JSONEncoder().encode(entries).write(to: registry, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: registry.path)
        }
        func reserve(beside destination: URL) throws -> Stage {
            lock.lock(); defer { lock.unlock() }
            var entries = try read(); guard entries.count < 2 else { throw ModelCatalogDownloadError.busy }
            let id = UUID(); let stage = Stage(id: id, directory: destination.deletingLastPathComponent().appendingPathComponent(".stacklume-download-\(id.uuidString)", isDirectory: true))
            try FileManager.default.createDirectory(at: stage.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: stage.file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { try? FileManager.default.removeItem(at: stage.directory); throw ModelCatalogError.invalidResponse }
            entries.append(stage)
            do { try write(entries) } catch { clean(stage); throw error }
            return stage
        }
        func register(_ stage: Stage, cancel: @escaping @Sendable () -> Void) { lock.lock(); active[stage.id] = cancel; lock.unlock() }
        func remove(_ stage: Stage) {
            lock.lock(); defer { lock.unlock() }
            active[stage.id] = nil; clean(stage)
            if let entries = try? read() { try? write(entries.filter { $0.id != stage.id }) }
        }
        func purge() {
            lock.lock(); let callbacks = Array(active.values); active.removeAll(); lock.unlock()
            callbacks.forEach { $0() }
            lock.lock(); defer { lock.unlock() }
            guard let entries = try? read() else { return }
            entries.forEach(clean); try? write([])
        }
        private func clean(_ stage: Stage) {
            let manager = FileManager.default
            guard stage.directory.isFileURL, stage.directory.lastPathComponent == ".stacklume-download-\(stage.id.uuidString)",
                  (try? stage.directory.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { return }
            try? manager.removeItem(at: stage.file)
            if let children = try? manager.contentsOfDirectory(atPath: stage.directory.path), children.isEmpty { try? manager.removeItem(at: stage.directory) }
        }
    }
}

// Cada bloque de red se escribe en el disco elegido y actualiza SHA-256. Nunca
// existe un Data con el archivo completo, ni un instalador de modelos implícito.
private final class ModelCatalogDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, any Error>?
    private var networkTask: URLSessionDataTask?
    private var cancelled = false
    private var finished = false
    private var failure: (any Error)?
    private var handle: FileHandle?
    private var digest = SHA256()
    private var received: Int64 = 0
    private var expected: Int64?
    private var lastProgress = Date.distantPast
    let selection: ModelCatalogDownloadSelection
    let destination: URL
    let stage: ModelCatalogDownloads.Stage
    let availableBytes: Int64
    let reservation: UUID
    let progress: @Sendable (ModelCatalogDownloadProgress) -> Void

    init(selection: ModelCatalogDownloadSelection, destination: URL, stage: ModelCatalogDownloads.Stage, availableBytes: Int64, reservation: UUID, progress: @escaping @Sendable (ModelCatalogDownloadProgress) -> Void) throws {
        self.selection = selection; self.destination = destination; self.stage = stage; self.availableBytes = availableBytes; self.reservation = reservation; self.progress = progress
        handle = try FileHandle(forWritingTo: stage.file)
    }
    func begin(_ task: URLSessionDataTask, continuation: CheckedContinuation<URL, any Error>) {
        lock.lock(); self.continuation = continuation; networkTask = task; let shouldCancel = cancelled; lock.unlock()
        if shouldCancel { task.cancel(); complete(.failure(CancellationError())) } else { task.resume() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let task = networkTask; try? handle?.close(); handle = nil; lock.unlock()
        task?.cancel()
    }
    private func complete(_ result: Result<URL, any Error>) {
        lock.lock(); guard !finished else { lock.unlock(); return }; finished = true
        let continuation = continuation; self.continuation = nil; networkTask = nil; try? handle?.close(); handle = nil; lock.unlock()
        continuation?.resume(with: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard request.httpMethod == "GET", let original = task.originalRequest?.url,
              ModelCatalogRequest.downloadInitialURL(original.absoluteString, provider: selection.provider) != nil,
              let target = request.url, ModelCatalogRequest.downloadRedirectURL(target.absoluteString, provider: selection.provider) != nil else {
            lock.lock(); failure = ModelCatalogDownloadError.redirectedAccess; lock.unlock(); completionHandler(nil); return
        }
        var clean = request
        if selection.provider == .huggingFace, target.host?.lowercased() == "huggingface.co", target.path.hasPrefix("/api/resolve-cache/"), !ModelCatalogRequest.mayRetainDownloadAuthorization(original: original, redirect: target) {
            lock.lock(); failure = ModelCatalogDownloadError.redirectedAccess; lock.unlock(); completionHandler(nil); return
        }
        if selection.provider != .huggingFace || !ModelCatalogRequest.mayRetainDownloadAuthorization(original: original, redirect: target) { clean.setValue(nil, forHTTPHeaderField: "Authorization") }
        clean.setValue(nil, forHTTPHeaderField: "Cookie"); completionHandler(clean)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse, let url = http.url, ModelCatalogRequest.downloadRedirectURL(url.absoluteString, provider: selection.provider) != nil else { throw ModelCatalogError.invalidResponse }
            guard (200...299).contains(http.statusCode) else { throw ModelCatalogError.http(http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After").map { String($0.prefix(80)) }) }
            guard ModelCatalogRequest.acceptsDownloadMIME(http.mimeType, filename: selection.filename) else { throw ModelCatalogDownloadError.invalidFile }
            let encoded = !(http.value(forHTTPHeaderField: "Content-Encoding").map { $0.lowercased() == "identity" } ?? true)
            let expected = !encoded && http.expectedContentLength > 0 ? http.expectedContentLength : nil
            if let expected {
                try ModelCatalogDownloads.capacity.resize(reservation, remaining: expected, available: ModelCatalogCapacityLedger.available(at: destination.deletingLastPathComponent()))
            }
            guard (expected ?? 0) <= availableBytes else { throw ModelCatalogDownloadError.insufficientSpace }
            lock.lock(); self.expected = expected; let failure = failure; let cancelled = cancelled; lock.unlock()
            if let failure { throw failure }; if cancelled { throw CancellationError() }
            completionHandler(.allow)
        } catch { lock.lock(); failure = error; lock.unlock(); completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if cancelled || failure != nil { lock.unlock(); dataTask.cancel(); return }
        do {
            guard Int64(data.count) <= availableBytes - received else { throw ModelCatalogDownloadError.insufficientSpace }
            guard let handle else { throw CancellationError() }
            try ModelCatalogDownloads.capacity.write(reservation, bytes: Int64(data.count), available: {
                try ModelCatalogCapacityLedger.available(at: self.destination.deletingLastPathComponent())
            }) { try handle.write(contentsOf: data) }
            digest.update(data: data); received += Int64(data.count)
            let emit = Date().timeIntervalSince(lastProgress) >= 0.15
            if emit { lastProgress = Date() }
            let update = ModelCatalogDownloadProgress(received: received, expected: expected)
            lock.unlock(); if emit { progress(update) }
        } catch { failure = error; lock.unlock(); dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        do {
            if let failure { throw failure }; if cancelled { throw CancellationError() }
            if let error = error as? URLError { throw ModelCatalogError.transportError(error.code) }; if let error { throw error }
            guard ModelCatalogRequest.matchesDownloadSize(received: received, expected: selection.expectedBytes, approximate: selection.sizeIsApproximate), expected.map({ $0 == received }) ?? true else { throw ModelCatalogDownloadError.sizeMismatch }
            if let expectedHash = selection.sha256, expectedHash.count == 64, expectedHash.allSatisfy(\.isHexDigit) {
                guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == expectedHash.lowercased() else { throw ModelCatalogDownloadError.checksumMismatch }
            }
            try handle?.synchronize(); try handle?.close(); handle = nil
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: stage.file, options: [.usingNewMetadataOnly]) }
            else { try FileManager.default.moveItem(at: stage.file, to: destination) }
            let update = ModelCatalogDownloadProgress(received: received, expected: received)
            lock.unlock(); progress(update); complete(.success(destination))
        } catch { lock.unlock(); complete(.failure(error)) }
    }
}

/// Reserva el espacio restante por volumen y serializa la comprobación con la
/// escritura; dos descargas no pueden comprometer los mismos bytes libres.
final class ModelCatalogCapacityLedger: @unchecked Sendable {
    private struct Entry { let volume: String; var remaining: Int64 }
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    static func available(at directory: URL) throws -> Int64 {
        let values = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        return max(0, (values[.systemFreeSize] as? NSNumber)?.int64Value ?? 0)
    }

    func reserve(_ id: UUID, volume: String, remaining: Int64, available: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        guard remaining >= 0, entries[id] == nil else { throw ModelCatalogDownloadError.insufficientSpace }
        try check(volume: volume, excluding: id, needed: remaining, available: available)
        entries[id] = Entry(volume: volume, remaining: remaining)
    }

    func resize(_ id: UUID, remaining: Int64, available: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[id], remaining >= 0 else { throw ModelCatalogDownloadError.insufficientSpace }
        try check(volume: entry.volume, excluding: id, needed: remaining, available: available)
        entries[id]?.remaining = remaining
    }

    func write(_ id: UUID, bytes: Int64, available: () throws -> Int64, operation: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[id], bytes >= 0 else { throw ModelCatalogDownloadError.insufficientSpace }
        try check(volume: entry.volume, excluding: id, needed: max(bytes, entry.remaining), available: available())
        try operation()
        entries[id]?.remaining = max(0, entry.remaining - bytes)
    }

    func release(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        entries[id] = nil
    }

    private func check(volume: String, excluding id: UUID, needed: Int64, available: Int64) throws {
        var remaining = available
        for (otherID, entry) in entries where otherID != id && entry.volume == volume {
            guard entry.remaining <= remaining else { throw ModelCatalogDownloadError.insufficientSpace }
            remaining -= entry.remaining
        }
        guard needed <= remaining else { throw ModelCatalogDownloadError.insufficientSpace }
    }
}
