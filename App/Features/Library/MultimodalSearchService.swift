import Foundation
import SwiftData
import SwiftUI
import StacklumeCore

extension Notification.Name {
    static let stacklumeSearchContentDidChange = Notification.Name("stacklume.search.contentChanged")
}

@Observable
@MainActor
final class MultimodalSearchService {
    static let shared = MultimodalSearchService()
    var status = "Preparando búsqueda inteligente…"
    var busy = true
    var isReady = false
    var indexedCount = 0
    var revision: UInt = 0
    var error: String?
    var visualStatus = ""
    var visualFailures = 0
    private var pendingCovers = Set<URL>()
    private var attemptedCovers = Set<URL>()
    private var coverTask: Task<Void, Never>?
    private var pendingPages: [String] = []
    private var attemptedPages = Set<String>()
    private var pageTask: Task<Void, Never>?
    private var context: ModelContext?
    private var updateTask: Task<Void, Never>?
    private var indexingJobID: String?
    private var updateGeneration: UInt = 0
    private var synchronizedGeneration: UInt?
    private var queryCache: [String: [MultimodalSearchMatch]] = [:]
    private var vectorCache: [UUID: [Double]] = [:]
    private var vectorCacheTask = "document"
    private var entityFingerprint = ""
    private struct SnapshotRevision: Equatable {
        let stamp: Date
        let coverVersion: Int
        let imageURL: String?
        let kind: String?
        let sourceURL: String
    }
    private var snapshots: [UUID: SnapshotRevision] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        for name in [Notification.Name.stacklumeModelDidSave, .stacklumeSearchContentDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                let url = note.object as? URL
                Task { @MainActor in
                    if let url { self?.snapshots = self?.snapshots.filter { $0.value.imageURL != url.absoluteString && $0.value.sourceURL != url.absoluteString } ?? [:] }
                    self?.scheduleUpdate()
                }
            })
        }
    }

    func setStatus(_ text: String, busy: Bool) {
        status = text
        self.busy = busy
    }

    func attach(context: ModelContext) {
        self.context = context
        scheduleUpdate()
    }

    /// El primer turno del asistente espera el índice antes de ocupar la GPU con el
    /// LLM. La interfaz y la cancelación permanecen disponibles durante la preparación.
    func waitUntilReady() async throws {
        guard context != nil else {
            throw EmbeddingGemmaRuntime.RuntimeError.message("La biblioteca aún no está disponible.")
        }
        if !isReady, updateTask == nil { scheduleUpdate() }
        while !isReady {
            try Task.checkCancellation()
            guard updateTask != nil else {
                throw EmbeddingGemmaRuntime.RuntimeError.message(error ?? status)
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    func scheduleUpdate() {
        updateGeneration &+= 1
        queryCache.removeAll()
        guard !MenuBarController.shared.isMenuBarOnly else { return }
        guard updateTask == nil else { return }
        updateTask = Task(priority: .background) {
            await refresh()
            updateTask = nil
            if Task.isCancelled, !MenuBarController.shared.isMenuBarOnly { scheduleUpdate() }
        }
    }

    func suspendBackgroundWork() {
        updateGeneration &+= 1
        updateTask?.cancel()
        coverTask?.cancel()
        pageTask?.cancel()
        busy = false
        indexingJobID = nil
        Task { await EmbeddingGemmaRuntime.shared.stopBackgroundRuntime() }
    }

    func retry() async {
        error = nil
        attemptedCovers.removeAll()
        attemptedPages.removeAll()
        visualFailures = 0
        snapshots.removeAll()
        synchronizedGeneration = nil
        scheduleUpdate()
    }

    private func refresh() async {
        guard let context else { return }
        do {
            try await LocalAIRunner.shared.withEmbeddingSearch {
                try await EmbeddingGemmaRuntime.shared.ensureReady()
                repeat {
                    let generation = updateGeneration
                    error = nil
                    let entities = try context.fetch(FetchDescriptor<BookmarkCategory>()).map { $0.id.uuidString + $0.name }
                        + context.fetch(FetchDescriptor<Tag>()).map { $0.id.uuidString + $0.name }
                    let fingerprint = entities.sorted().joined(separator: "|")
                    if fingerprint != entityFingerprint { snapshots.removeAll(); entityFingerprint = fingerprint }
                    let links = try context.fetch(FetchDescriptor<Bookmark>(predicate: #Predicate { $0.deletedAt == nil }))
                    setStatus("Actualizando el índice de \(links.count) enlaces…", busy: true)
                    var ids = Set<UUID>()
                    var missingCovers = Set<URL>()
                    var pageURLs = Set<String>()
                    var missingPages: [String] = []
                    for (index, link) in links.enumerated() {
                        try Task.checkCancellation()
                        guard link.modelContext != nil, link.deletedAt == nil else { continue }
                        let id = link.id
                        ids.insert(id)
                        if !link.url.isEmpty { pageURLs.insert(link.url) }
                        let snapshot = SnapshotRevision(stamp: link.updatedAt,
                            coverVersion: CustomCoverStore.shared.currentVersion(for: id), imageURL: link.imageURL, kind: link.fileKind, sourceURL: link.url)
                        if snapshots[id] == snapshot { continue }
                        var parts = [link.title, link.url]
                        parts.append(contentsOf: [link.details, link.summary, link.notes, link.offlineText,
                                                   link.siteName, link.category?.name].compactMap { $0 })
                        parts.append(contentsOf: link.tags.map(\.name) + link.semanticTags)
                        parts.append(contentsOf: link.highlights.map(\.text))
                        parts.append(contentsOf: HighlightNoteStore.notes(for: link.highlights.map(\.id)))
                        let fileKind = link.fileKind
                        let fileData = ["pdf", "image", "audio", "video"].contains(fileKind ?? "") ? link.fileData : nil
                        let ext: String? = switch fileKind {
                        case "pdf": "pdf"
                        case "image": "png"
                        case "audio", "video": fileData.flatMap { LocalMediaFileFormat.fileExtension(for: $0, kind: fileKind ?? "") }
                            ?? (fileKind == "audio" ? "m4a" : "mp4")
                        default: nil
                        }
                        let attachment = ext == nil ? nil : fileData
                        let sourceURL = link.url
                        let imageURL = link.imageURL
                        let cover: Data?
                        if let custom = CustomCoverStore.shared.coverData(for: id) { cover = custom }
                        else if let raw = imageURL, let url = URL(string: raw) {
                            cover = await SecureImageCache.shared.cachedBytesForSearch(for: url)
                            if cover == nil { missingCovers.insert(url) }
                        } else { cover = nil }
                        let page = sourceURL.isEmpty ? nil : await EmbeddingGemmaCorpus.shared.pageSnapshot(for: sourceURL)
                        if page == nil, let url = URL(string: sourceURL),
                           StacklumeAutomationPolicy.allowsAutomaticNetworkURL(url), CoverEnsurer.allowsSnapshot(of: sourceURL) {
                            missingPages.append(sourceURL)
                        }
                        let document = EmbeddingGemmaDocument(id: id,
                            text: parts.joined(separator: "\n"), cover: cover,
                            attachment: attachment, attachmentExtension: ext, pageSnapshot: page)
                        try await EmbeddingGemmaCorpus.shared.write(document)
                        if generation == updateGeneration { snapshots[id] = snapshot }
                        if index % 16 == 0 { await Task.yield() }
                    }
                    try await EmbeddingGemmaCorpus.shared.purge(except: ids)
                    try await EmbeddingGemmaCorpus.shared.purgePageSnapshots(except: pageURLs)
                    snapshots = snapshots.filter { ids.contains($0.key) }
                    struct Job: Decodable, Sendable {
                        let id: String
                        let status: String
                        let failed: Int
                    }
                    let body = try JSONEncoder().encode(IndexRequest(path: EmbeddingGemmaRuntime.corpus.path))
                    var job = try await EmbeddingGemmaRuntime.shared.request("index", body: body, as: Job.self)
                    indexingJobID = job.id
                    if Task.isCancelled {
                        struct Result: Decodable, Sendable { let cancelled: Bool }
                        _ = try? await EmbeddingGemmaRuntime.shared.request("jobs/\(job.id)", method: "DELETE", as: Result.self)
                        throw CancellationError()
                    }
                    while job.status == "queued" || job.status == "running" {
                        try await Task.sleep(for: .seconds(1))
                        job = try await EmbeddingGemmaRuntime.shared.request("jobs/\(job.id)", as: Job.self)
                    }
                    guard job.status == "done" || job.status == "completed" else {
                        throw EmbeddingGemmaRuntime.RuntimeError.message("El índice no terminó: \(job.status).")
                    }
                    indexingJobID = nil
                    synchronizedGeneration = generation
                    indexedCount = ids.count
                    revision &+= 1
                    queryCache.removeAll()
                    vectorCache.removeAll()
                    isReady = true
                    scheduleCoverDownloads(missingCovers)
                    schedulePageCaptures(missingPages)
                    if job.failed > 0 {
                        error = "\(job.failed) archivos no pudieron indexarse. Puedes reintentar en Ajustes › IA."
                    }
                } while synchronizedGeneration != updateGeneration
                isReady = true
                setStatus("Listo · \(indexedCount) enlaces · Texto, imagen, audio, vídeo y PDF", busy: false)
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            setStatus("Búsqueda literal disponible. \(error.localizedDescription)", busy: false)
        }
    }

    /// La adquisición de portadas nunca retrasa el índice de texto ni los adjuntos locales.
    private func scheduleCoverDownloads(_ urls: Set<URL>) {
        pendingCovers.formUnion(urls.subtracting(attemptedCovers))
        guard coverTask == nil, !pendingCovers.isEmpty else { return }
        coverTask = Task(priority: .background) {
            while !pendingCovers.isEmpty, !Task.isCancelled {
                let batch = Array(pendingCovers.prefix(4))
                pendingCovers.subtract(batch)
                await withTaskGroup(of: Bool.self) { group in
                    for url in batch {
                        group.addTask { await Self.acquireCover(url) }
                    }
                    for await success in group where !success { visualFailures += 1 }
                }
                if Task.isCancelled { pendingCovers.formUnion(batch); break }
                attemptedCovers.formUnion(batch)
            }
            coverTask = nil
            if !MenuBarController.shared.isMenuBarOnly { scheduleCoverDownloads([]) }
        }
    }

    private nonisolated static func acquireCover(_ url: URL) async -> Bool {
        await SecureImageCache.shared.bytesForSearch(for: url) != nil
    }

    private func schedulePageCaptures(_ urls: [String]) {
        let queued = Set(pendingPages)
        pendingPages.append(contentsOf: urls.filter { !attemptedPages.contains($0) && !queued.contains($0) })
        guard pageTask == nil, !pendingPages.isEmpty else { return }
        pageTask = Task(priority: .background) {
            while !pendingPages.isEmpty, !Task.isCancelled {
                await UserActivityMonitor.shared.waitUntilIdle()
                while !LocalAIRunner.canRunBackgroundWork, !Task.isCancelled {
                    visualStatus = "Capturas en pausa para dar prioridad al chat y a la memoria del Mac"
                    try? await Task.sleep(for: .seconds(1))
                }
                guard !Task.isCancelled else { break }
                let raw = pendingPages.removeFirst()
                guard !attemptedPages.contains(raw) else { continue }
                visualStatus = "Preparando aspecto de páginas · \(pendingPages.count + 1) pendientes"
                if CoverAutoFiller.isEnabled, let context {
                    let links = (try? context.fetch(FetchDescriptor<Bookmark>(predicate: #Predicate {
                        $0.deletedAt == nil && $0.url == raw
                    }))) ?? []
                    for link in links where link.fileKind == nil && !CoverEnsurer.hasCover(link) {
                        _ = await CoverEnsurer.ensure(for: link, in: context, useCachedSnapshot: true)
                    }
                }
                let captured = await PageSnapshotService.snapshot(of: raw, useCached: true)
                if Task.isCancelled { pendingPages.insert(raw, at: 0); break }
                attemptedPages.insert(raw)
                if captured == nil { visualFailures += 1 }
            }
            visualStatus = "Aspecto de páginas actualizado"
            pageTask = nil
            if !MenuBarController.shared.isMenuBarOnly { schedulePageCaptures([]) }
        }
    }

    private struct IndexRequest: Encodable {
        let path: String
        let collection = "stacklume-library"
        let wait = 0
    }
    private struct Query: Encodable {
        let query: String?
        let file: String?
        let task: String
        let ids: [UUID]?
        let k = 200
    }
    private struct Response: Decodable, Sendable {
        struct Hit: Decodable, Sendable {
            let path: String
            let score: Double
            let modality: String
            let location: String?
            let preview: String
        }
        let results: [Hit]
    }

    func search(_ text: String, file: URL? = nil, task: String = "query", allowedIDs: [UUID]? = nil) async throws -> [MultimodalSearchMatch] {
        let scoped = file?.startAccessingSecurityScopedResource() ?? false
        defer { if scoped { file?.stopAccessingSecurityScopedResource() } }
        if let file {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= DocumentTextExtractor.maximumInputBytes else {
                throw EmbeddingGemmaRuntime.RuntimeError.message("El archivo de consulta debe ser local y no superar 64 MB.")
            }
        }
        try Task.checkCancellation()
        guard isReady else { throw EmbeddingGemmaRuntime.RuntimeError.message(error ?? "La búsqueda inteligente se está preparando.") }
        let scopeKey = allowedIDs?.map(\.uuidString).sorted().joined(separator: ",") ?? "*"
        let key = "\(revision)|\(task)|\(text)|\(file?.path ?? "")|\(scopeKey)"
        if file == nil, let cached = queryCache[key] { return cached }
        let body = try JSONEncoder().encode(Query(query: text.isEmpty ? nil : text, file: file?.path, task: task, ids: allowedIDs))
        let response = try await LocalAIRunner.shared.withEmbeddingSearch {
            try await EmbeddingGemmaRuntime.shared.request("stacklume/search", body: body, as: Response.self)
        }
        try Task.checkCancellation()
        var used = Set<UUID>()
        let candidates = response.results.compactMap { hit -> MultimodalSearchMatch? in
            guard hit.score.isFinite, hit.score >= 0.30,
                  let id = MultimodalSearchRanking.bookmarkID(from: hit.path, corpus: EmbeddingGemmaRuntime.corpus),
                  used.insert(id).inserted else { return nil }
            return MultimodalSearchMatch(bookmarkID: id, score: hit.score, modality: hit.modality,
                                        location: hit.location, preview: hit.preview)
        }
        let matches = MultimodalSearchRanking.relevant(candidates)
        if file == nil {
            if queryCache.count > 100 { queryCache.removeAll() }
            queryCache[key] = matches
        }
        return matches
    }

    func hybrid(_ links: [Bookmark], query: String, matches: [MultimodalSearchMatch], limit: Int = Int.max, includeLiteral: Bool = true) -> [Bookmark] {
        let parsed = SearchQuery.parse(query)
        let scoped = links.filter { $0.deletedAt == nil && parsed.matches($0) }
        let literal = includeLiteral ? scoped.filter { parsed.lexicalMatches($0) } : []
        let ids = MultimodalSearchRanking.merge(literal: literal.map(\.id), semantic: matches,
                                                allowed: Set(scoped.map(\.id)), limit: limit)
        let byID = Dictionary(scoped.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    func vectors(for ids: [UUID], task: String = "document") async throws -> [UUID: [Double]] {
        try Task.checkCancellation()
        guard isReady else { throw EmbeddingGemmaRuntime.RuntimeError.message(error ?? status) }
        let expectedRevision = revision
        if vectorCacheTask != task { vectorCache.removeAll(); vectorCacheTask = task }
        struct Request: Encodable { let ids: [UUID]; let task: String }
        struct Response: Decodable, Sendable { let revision: String; let embeddings: [String: [Double]] }
        let missing = ids.filter { vectorCache[$0] == nil }
        for start in stride(from: 0, to: missing.count, by: 256) {
            try Task.checkCancellation()
            let batch = Array(missing[start..<min(missing.count, start + 256)])
            let body = try JSONEncoder().encode(Request(ids: batch, task: task))
            let result: Response
            if task == "document" {
                result = try await EmbeddingGemmaRuntime.shared.request("stacklume/vectors", body: body, as: Response.self)
            } else {
                result = try await LocalAIRunner.shared.withEmbeddingSearch {
                    try await EmbeddingGemmaRuntime.shared.request("stacklume/vectors", body: body, as: Response.self)
                }
            }
            guard result.revision == "1a4ffddb7905d3f63486748deabe091a01fb6201" else { continue }
            guard vectorCacheTask == task, revision == expectedRevision else { throw CancellationError() }
            for (rawID, vector) in result.embeddings {
                if let id = UUID(uuidString: rawID), vector.count == 768, vector.allSatisfy(\.isFinite) { vectorCache[id] = vector }
            }
        }
        guard revision == expectedRevision, vectorCacheTask == task else { throw CancellationError() }
        return Dictionary(ids.compactMap { id in vectorCache[id].map { (id, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    func labelScores(for ids: [UUID], labels: [String], task: String) async throws -> [UUID: [(String, Double)]] {
        let vectors = try await vectors(for: ids, task: task)
        struct Request: Encodable { let inputs: [String]; let task: String; let dimensions = 768 }
        struct Response: Decodable, Sendable { let embeddings: [[Double]] }
        let response = try await LocalAIRunner.shared.withEmbeddingSearch {
            try await EmbeddingGemmaRuntime.shared.request("embed",
                body: JSONEncoder().encode(Request(inputs: labels, task: task)), as: Response.self)
        }
        guard response.embeddings.count == labels.count, response.embeddings.allSatisfy({ $0.count == 768 && $0.allSatisfy(\.isFinite) }) else { return [:] }
        return vectors.mapValues { vector in
            zip(labels, response.embeddings).map { label, other in
                (label, zip(vector, other).reduce(0) { $0 + $1.0 * $1.1 })
            }.sorted { $0.1 > $1.1 }
        }
    }
}
