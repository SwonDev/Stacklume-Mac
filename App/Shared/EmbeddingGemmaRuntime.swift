import Foundation
import Darwin
import CryptoKit

/// Proceso privado: el usuario final no necesita instalar intérpretes ni servidores.
actor EmbeddingGemmaRuntime {
    static let shared = EmbeddingGemmaRuntime()
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Stacklume/EmbeddingGemma2", isDirectory: true)
    static let corpus = root.appendingPathComponent("corpus", isDirectory: true)

    struct Status: Decodable, Sendable {
        let phase: String
        let message: String?
        let port: Int?
        let revision: String?
    }
    private struct Manifest: Decodable {
        let version: String
        let sha256: String
        let revision: String
    }
    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }
    private struct Endpoint: Sendable { let url: URL; let token: String }
    private var process: Process?
    private var endpoint: Endpoint?
    private var preparation: Task<Endpoint, Error>?
    private var stopping: Task<Void, Never>?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForResource = 900
        return URLSession(configuration: config)
    }()

    func ensureReady() async throws {
        _ = try await connection()
    }

    /// La barra de menús no termina una preparación pendiente iniciada por la biblioteca.
    func cancelPreparation() {
        guard endpoint == nil else { return }
        preparation?.cancel()
        if process?.isRunning == true { process?.terminate() }
    }

    /// Cierra únicamente el proceso privado de Stacklume. Así también se detiene
    /// un trabajo cuya creación llegó al servidor pero cuya respuesta fue cancelada.
    func stopBackgroundRuntime() {
        preparation?.cancel()
        guard let child = process, child.isRunning else { endpoint = nil; return }
        endpoint = nil
        child.terminate()
        stopping = Task {
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while child.isRunning, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if child.isRunning {
                let pid = child.processIdentifier
                // El servidor crea su propia sesión antes de lanzar workers.
                // Nunca enviar señales a un grupo heredado de otro programa.
                if getpgid(pid) == pid { kill(-pid, SIGKILL) }
                else { kill(pid, SIGKILL) }
            }
            while child.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        }
    }

    /// Devuelve la RAM del worker; el servidor y el índice siguen disponibles.
    func releaseModelMemory() async throws {
        guard let endpoint, process?.isRunning == true else { return }
        var request = URLRequest(url: endpoint.url.appendingPathComponent("stacklume/release"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        struct Result: Decodable { let released: Bool }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              (try? JSONDecoder().decode(Result.self, from: data))?.released == true else {
            throw RuntimeError.message("El motor de búsqueda todavía está liberando memoria. Reintenta la carga del chat.")
        }
    }

    private func connection() async throws -> Endpoint {
        if let stopping { await stopping.value; self.stopping = nil }
        try Task.checkCancellation()
        if let endpoint, process?.isRunning == true { return endpoint }
        if let preparation { return try await preparation.value }
        let task = Task { try await self.prepare() }
        preparation = task
        do {
            let value = try await task.value
            endpoint = value
            preparation = nil
            return value
        } catch {
            preparation = nil
            throw error
        }
    }

    private func prepare() async throws -> Endpoint {
        #if !arch(arm64)
        throw RuntimeError.message("EmbeddingGemma 2 necesita un Mac con Apple Silicon.")
        #else
        try PrivateFileIO.ensureDirectory(Self.root)
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("EmbeddingRuntime"),
              let manifestData = try? Data(contentsOf: resources.appendingPathComponent("manifest.json")) else {
            throw RuntimeError.message("Esta instalación no contiene el runtime de búsqueda. Reinstala Stacklume.")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        let runtime = Self.root.appendingPathComponent("runtime-\(manifest.version)", isDirectory: true)
        let python = runtime.appendingPathComponent("python/bin/python3.12")
        if !FileManager.default.isExecutableFile(atPath: python.path) {
            await MultimodalSearchService.shared.setStatus("Instalando búsqueda inteligente…", busy: true)
            let archive = resources.appendingPathComponent("runtime.tar.gz")
            let handle = try FileHandle(forReadingFrom: archive)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: block)
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == manifest.sha256 else { throw RuntimeError.message("El runtime descargado está dañado.") }
            let staging = Self.root.appendingPathComponent("install-\(UUID().uuidString)", isDirectory: true)
            try PrivateFileIO.ensureDirectory(staging)
            defer { try? FileManager.default.removeItem(at: staging) }
            try await runExecutable(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xzf", archive.path, "-C", staging.path])
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: runtime.path) { try FileManager.default.removeItem(at: runtime) }
            try FileManager.default.moveItem(at: staging.appendingPathComponent("runtime"), to: runtime)
        }
        let token = UUID().uuidString + UUID().uuidString
        let statusURL = Self.root.appendingPathComponent("status.json")
        try? FileManager.default.removeItem(at: statusURL)
        let logURL = Self.root.appendingPathComponent("server.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let log = try FileHandle(forWritingTo: logURL)
        try log.seekToEnd()
        let child = Process()
        child.executableURL = python
        child.arguments = [runtime.appendingPathComponent("stacklume_server.py").path]
        child.currentDirectoryURL = runtime
        // No hereda tokens HF, PYTHONPATH ni configuraciones de otros asistentes.
        child.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": runtime.appendingPathComponent("python/bin").path + ":/usr/bin:/bin",
            "PYTHONHOME": runtime.appendingPathComponent("python").path,
            "PYTHONPATH": runtime.path,
            "PYTHONNOUSERSITE": "1", "PYTHONUNBUFFERED": "1",
            "EGEMMA_HOME": Self.root.path,
            "STACKLUME_PARENT_PID": String(ProcessInfo.processInfo.processIdentifier),
            "STACKLUME_EMBEDDING_TOKEN": token,
            "TOKENIZERS_PARALLELISM": "false", "LANG": "es_ES.UTF-8"
        ]
        child.standardOutput = log
        child.standardError = log
        try Task.checkCancellation()
        try child.run()
        try? log.close()
        process = child
        var ready = false
        defer { if !ready, child.isRunning { child.terminate() } }
        for _ in 0..<7_200 {
            try Task.checkCancellation()
            guard child.isRunning else { throw RuntimeError.message("La búsqueda inteligente no pudo arrancar. Reintenta en Ajustes › IA.") }
            if let data = try? Data(contentsOf: statusURL), let status = try? JSONDecoder().decode(Status.self, from: data) {
                if status.phase == "failed" {
                    child.terminate()
                    throw RuntimeError.message(status.message ?? "No se pudo descargar el modelo.")
                }
                if status.phase == "ready", let port = status.port, status.revision == manifest.revision,
                   (1...65_535).contains(port), let url = URL(string: "http://127.0.0.1:\(port)") {
                    ready = true
                    return Endpoint(url: url, token: token)
                }
                await MultimodalSearchService.shared.setStatus(status.message ?? "Preparando búsqueda…", busy: true)
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        child.terminate()
        throw RuntimeError.message("La descarga no ha terminado. Comprueba la conexión y reintenta.")
        #endif
    }

    func request<T: Decodable & Sendable>(_ path: String, body: Data? = nil, method: String? = nil, as type: T.Type) async throws -> T {
        let endpoint = try await connection()
        var request = URLRequest(url: endpoint.url.appendingPathComponent(path))
        request.httpMethod = method ?? (body == nil ? "GET" : "POST")
        request.httpBody = body
        request.timeoutInterval = 900
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
            throw RuntimeError.message(message ?? "El motor de búsqueda no pudo completar la operación.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func runExecutable(_ url: URL, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let child = Process()
            child.executableURL = url
            child.arguments = arguments
            child.terminationHandler = { process in
                if process.terminationStatus == 0 { continuation.resume() }
                else { continuation.resume(throwing: RuntimeError.message("No se pudo instalar el runtime.")) }
            }
            do { try child.run() } catch { continuation.resume(throwing: error) }
        }
    }

    enum RuntimeError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { value } else { nil } }
    }
}
