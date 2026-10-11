import Foundation

private final class ModelCatalogRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // La API no necesita redirecciones. Se rechazan incluso dentro del proveedor
        // para que una respuesta nunca pueda reenviar su Bearer a otra ruta.
        completionHandler(nil)
    }
}

private final class ModelCatalogMediaRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    let provider: ModelCatalogProvider
    let kind: ModelCatalogMediaKind
    init(provider: ModelCatalogProvider, kind: ModelCatalogMediaKind) { self.provider = provider; self.kind = kind }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard task.originalRequest?.value(forHTTPHeaderField: "Cookie") == nil,
              let original = task.originalRequest?.url, ModelCatalogRequest.mediaURL(original.absoluteString, provider: provider, kind: kind) != nil,
              task.originalRequest?.value(forHTTPHeaderField: "Authorization") == nil || (provider == .huggingFace && ModelCatalogRequest.mayAuthenticateMediaURL(original)),
              request.httpMethod == "GET", let url = request.url,
              ModelCatalogRequest.redirectedMediaURL(url.absoluteString, provider: provider, kind: kind) != nil else { completionHandler(nil); return }
        var clean = request
        if !ModelCatalogRequest.mayRetainMediaAuthorization(original: original, redirect: url) { clean.setValue(nil, forHTTPHeaderField: "Authorization") }
        clean.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(clean)
    }
}

actor ModelCatalogClient {
    private struct ForegroundCredentialRead {
        let id = UUID()
        var observer: (attemptID: UUID, continuation: CheckedContinuation<ModelCatalogCredentialRead, any Error>)?
    }
    static let shared = ModelCatalogClient()
    private let credentials = ModelCatalogCredentials()
    private var credentialAccess: ModelCatalogCredentialAccess
    private let credentialContinuity: ModelCatalogCredentialContinuity
    private var authorizationAttempts: [ModelCatalogProvider: ModelCatalogCredentialOperation] = [:]
    private let credentialQueues: [ModelCatalogProvider: DispatchQueue]
    private let foregroundCredentialQueues: [ModelCatalogProvider: DispatchQueue]
    private var foregroundReads: [ModelCatalogProvider: ForegroundCredentialRead] = [:]
    private var credentialMutations: [ModelCatalogProvider: UUID] = [:]
    private let credentialValidator: (@Sendable (ModelCatalogProvider, String) async throws -> String?)?
    private let credentialWriter: (@Sendable (ModelCatalogProvider, String) throws -> Void)?
    private let credentialDeleter: (@Sendable (ModelCatalogProvider) throws -> Void)?
    private var connectionListeners: [ModelCatalogProvider: [UUID: AsyncStream<ModelCatalogConnectionStatus>.Continuation]] = [:]
    private let session: URLSession
    private let usesStoredCredentials: Bool
    private var imageCredential: String?
    private var imageGeneration = UUID()
    private var imageCache: [URL: Data] = [:]
    private var imageCacheBytes = 0
    private var activeImageLoads = 0
    private var waitingImageLoads: [(UUID, CheckedContinuation<Void, any Error>)] = []

    init(usesStoredCredentials: Bool = true, credentialReader: ModelCatalogCredentialAccess.Reader? = nil, credentialValidator: (@Sendable (ModelCatalogProvider, String) async throws -> String?)? = nil, credentialWriter: (@Sendable (ModelCatalogProvider, String) throws -> Void)? = nil, credentialDeleter: (@Sendable (ModelCatalogProvider) throws -> Void)? = nil, credentialContinuity: ModelCatalogCredentialContinuity? = nil) {
        self.usesStoredCredentials = usesStoredCredentials
        self.credentialValidator = credentialValidator
        self.credentialWriter = credentialWriter
        self.credentialDeleter = credentialDeleter
        self.credentialContinuity = credentialContinuity ?? (credentialReader == nil ? ModelCatalogCredentials.continuity : .injectedReader)
        credentialQueues = Dictionary(uniqueKeysWithValues: ModelCatalogProvider.allCases.map { ($0, DispatchQueue(label: "com.swondev.stacklume.model-catalog.credential.\($0.rawValue)", qos: .utility)) })
        foregroundCredentialQueues = Dictionary(uniqueKeysWithValues: ModelCatalogProvider.allCases.map { ($0, DispatchQueue(label: "com.swondev.stacklume.model-catalog.credential.foreground.\($0.rawValue)", qos: .userInitiated)) })
        let store = ModelCatalogCredentials()
        credentialAccess = .init(reader: credentialReader ?? { provider, interactive in store.read(provider, allowingInteraction: interactive) })
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false; c.httpCookieStorage = nil
        c.urlCredentialStorage = nil; c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.timeoutIntervalForRequest = 20; c.timeoutIntervalForResource = 40
        c.httpMaximumConnectionsPerHost = 3
        session = URLSession(configuration: c, delegate: ModelCatalogRedirectPolicy(), delegateQueue: nil)
    }

    func isConnected(_ provider: ModelCatalogProvider) throws -> Bool {
        connectionStatus(provider).canUseAccount
    }

    func connectionStatus(_ provider: ModelCatalogProvider) -> ModelCatalogConnectionStatus {
        guard usesStoredCredentials else { return .absent }
        startCredentialProbe(provider)
        return credentialAccess.background(provider).status
    }

    private func backgroundToken(_ provider: ModelCatalogProvider) -> String? {
        guard usesStoredCredentials else { return nil }
        startCredentialProbe(provider)
        return credentialAccess.background(provider).token
    }

    func connectionChanges(_ provider: ModelCatalogProvider) -> AsyncStream<ModelCatalogConnectionStatus> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            connectionListeners[provider, default: [:]][id] = continuation
            continuation.yield(connectionStatus(provider))
            continuation.onTermination = { [weak self] _ in Task { await self?.removeConnectionListener(provider, id: id) } }
        }
    }

    private func removeConnectionListener(_ provider: ModelCatalogProvider, id: UUID) {
        connectionListeners[provider]?[id] = nil
        if connectionListeners[provider]?.isEmpty == true { connectionListeners[provider] = nil }
    }

    private func publishConnection(_ provider: ModelCatalogProvider) {
        let status = credentialAccess.status(provider)
        for continuation in connectionListeners[provider]?.values ?? [:].values { continuation.yield(status) }
    }

    private func startCredentialProbe(_ provider: ModelCatalogProvider) {
        guard let ticket = credentialAccess.beginProbe(provider), let queue = credentialQueues[provider] else { return }
        guard credentialContinuity.allowsBackgroundRead(provider) else {
            _ = credentialAccess.completeProbe(provider, ticket: ticket, result: .init(status: .accessUnverified, token: nil))
            publishConnection(provider)
            return
        }
        let reader = credentialAccess.reader
        Task.detached { [weak self] in
            let result = await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: reader(provider, false)) }
            }
            await self?.completeCredentialProbe(provider, ticket: ticket, result: result)
        }
    }

    private func completeCredentialProbe(_ provider: ModelCatalogProvider, ticket: UUID, result: ModelCatalogCredentialRead) async {
        var outcome = result
        if credentialAccess.isCurrentProbe(provider, ticket: ticket), let token = result.token {
            do { _ = try await validate(provider, token: token) }
            catch { outcome = .init(status: .accountUnavailable, token: nil) }
        }
        guard credentialAccess.completeProbe(provider, ticket: ticket, result: outcome) else { return }
        if outcome.status == .authorizationRequired { credentialContinuity.invalidate(provider) }
        if provider == .huggingFace, outcome.status == .available { invalidateImages(); imageCredential = outcome.token }
        publishConnection(provider)
    }

    private func beginAuthorization(_ provider: ModelCatalogProvider) -> ModelCatalogCredentialOperation {
        authorizationAttempts[provider]?.invalidate()
        foregroundReads[provider]?.observer?.continuation.resume(throwing: CancellationError())
        foregroundReads[provider]?.observer = nil
        let attempt = ModelCatalogCredentialOperation()
        authorizationAttempts[provider] = attempt
        credentialAccess.invalidateProbe(provider)
        return attempt
    }

    private func foregroundRead(_ provider: ModelCatalogProvider, attempt: ModelCatalogCredentialOperation) async throws -> ModelCatalogCredentialRead {
        if foregroundReads[provider] == nil {
            guard let queue = foregroundCredentialQueues[provider] else { throw ModelCatalogError.keychain }
            let reader = credentialAccess.reader
            let pending = ForegroundCredentialRead()
            foregroundReads[provider] = pending
            queue.async { [weak self] in
                let result = reader(provider, true)
                Task { await self?.completeForegroundRead(provider, id: pending.id, result: result) }
            }
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                foregroundReads[provider]?.observer = (attempt.id, continuation)
            }
        } onCancel: { [weak self] in Task { await self?.cancelForegroundObserver(provider, attemptID: attempt.id) } }
    }

    private func completeForegroundRead(_ provider: ModelCatalogProvider, id: UUID, result: ModelCatalogCredentialRead) {
        guard let pending = foregroundReads[provider], pending.id == id else { return }
        foregroundReads[provider] = nil
        pending.observer?.continuation.resume(returning: result)
    }

    private func cancelForegroundObserver(_ provider: ModelCatalogProvider, attemptID: UUID) {
        guard foregroundReads[provider]?.observer?.attemptID == attemptID else { return }
        foregroundReads[provider]?.observer?.continuation.resume(throwing: CancellationError())
        foregroundReads[provider]?.observer = nil
    }

    private func mutateCredential(_ provider: ModelCatalogProvider, attempt: ModelCatalogCredentialOperation, operation: @escaping @Sendable () throws -> Void) async throws {
        guard credentialMutations[provider] == nil, let queue = foregroundCredentialQueues[provider] else { throw ModelCatalogError.credentialBusy }
        let id = UUID(); credentialMutations[provider] = id
        let continuity = credentialContinuity
        defer { if credentialMutations[provider] == id { credentialMutations[provider] = nil } }
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    queue.async {
                        do { try attempt.beginMutation(); continuity.invalidate(provider); try operation(); try attempt.check(); continuation.resume() }
                        catch { continuation.resume(throwing: error) }
                    }
                }
            } onCancel: { [weak self] in
                attempt.invalidate()
                Task { await self?.cancelCredentialMutation(provider, attemptID: attempt.id) }
            }
            try Task.checkCancellation()
        } catch {
            if authorizationAttempts[provider]?.id == attempt.id { publishMutationFailure(provider, attempt: attempt) }
            throw error
        }
    }

    private func cancelCredentialMutation(_ provider: ModelCatalogProvider, attemptID: UUID) {
        guard let attempt = authorizationAttempts[provider], attempt.id == attemptID else { return }
        publishMutationFailure(provider, attempt: attempt)
    }

    private func publishMutationFailure(_ provider: ModelCatalogProvider, attempt: ModelCatalogCredentialOperation) {
        if attempt.hasStartedMutation {
            credentialAccess.mutationOutcomeUnverified(provider)
            if provider == .huggingFace { invalidateImages(); imageCredential = nil }
        } else { credentialAccess.authorizationFailed(provider, status: .accessUnverified) }
        publishConnection(provider)
    }

    func authorizeAccess(_ provider: ModelCatalogProvider) async throws -> String? {
        guard usesStoredCredentials else { throw ModelCatalogError.keychain }
        guard credentialMutations[provider] == nil else { throw ModelCatalogError.credentialBusy }
        try Task.checkCancellation()
        let attempt = beginAuthorization(provider)
        let result: ModelCatalogCredentialRead
        do { result = try await foregroundRead(provider, attempt: attempt) }
        catch {
            if authorizationAttempts[provider]?.id == attempt.id {
                credentialAccess.authorizationFailed(provider, status: .accessUnverified)
                publishConnection(provider)
            }
            throw error
        }
        guard authorizationAttempts[provider]?.id == attempt.id else { throw CancellationError() }
        if Task.isCancelled {
            credentialAccess.authorizationFailed(provider, status: result.token == nil ? result.status : .authorizationRequired)
            publishConnection(provider)
            throw CancellationError()
        }
        guard let token = result.token else {
            if result.status == .authorizationRequired { credentialContinuity.invalidate(provider) }
            credentialAccess.authorizationFailed(provider, status: result.status)
            publishConnection(provider)
            if result.status == .authorizationRequired { throw ModelCatalogError.keychainAccessRequired }
            throw ModelCatalogError.keychain
        }
        let name: String?
        do { name = try await validate(provider, token: token); try Task.checkCancellation() }
        catch {
            if authorizationAttempts[provider]?.id == attempt.id {
                credentialAccess.authorizationFailed(provider, status: Task.isCancelled ? .authorizationRequired : .accountUnavailable)
                publishConnection(provider)
            }
            throw error
        }
        guard authorizationAttempts[provider]?.id == attempt.id else { throw CancellationError() }
        try attempt.check()
        try credentialAccess.authorized(provider, token: token)
        credentialContinuity.recordAuthorizedRead(provider)
        if provider == .huggingFace { invalidateImages(); imageCredential = token }
        publishConnection(provider)
        return name
    }

    func disconnect(_ provider: ModelCatalogProvider) async throws {
        guard credentialMutations[provider] == nil else { throw ModelCatalogError.credentialBusy }
        let attempt = beginAuthorization(provider), store = credentials, deleter = credentialDeleter
        do {
            try await mutateCredential(provider, attempt: attempt) {
                if let deleter { try deleter(provider) } else { try store.delete(provider) }
            }
            try Task.checkCancellation()
            guard authorizationAttempts[provider]?.id == attempt.id else { throw CancellationError() }
            credentialAccess.forget(provider)
            if provider == .huggingFace { invalidateImages(); imageCredential = nil }
            publishConnection(provider)
        } catch {
            if authorizationAttempts[provider]?.id == attempt.id {
                publishMutationFailure(provider, attempt: attempt)
            }
            throw error
        }
    }

    func connect(_ provider: ModelCatalogProvider, token: String) async throws -> String? {
        guard credentialMutations[provider] == nil else { throw ModelCatalogError.credentialBusy }
        let attempt = beginAuthorization(provider), store = credentials, writer = credentialWriter
        do {
            let name = try await validate(provider, token: token)
            try Task.checkCancellation()
            guard authorizationAttempts[provider]?.id == attempt.id else { throw CancellationError() }
            try await mutateCredential(provider, attempt: attempt) {
                if let writer { try writer(provider, token) } else { try store.save(token, provider: provider) }
            }
            let read = try await foregroundRead(provider, attempt: attempt)
            guard read.status == .available, read.token == token else { throw ModelCatalogError.keychain }
            try Task.checkCancellation()
            guard authorizationAttempts[provider]?.id == attempt.id else { throw CancellationError() }
            try attempt.check()
            try credentialAccess.authorized(provider, token: token)
            credentialContinuity.recordAuthorizedRead(provider)
            if provider == .huggingFace { invalidateImages(); imageCredential = token }
            publishConnection(provider)
            return name
        } catch {
            if authorizationAttempts[provider]?.id == attempt.id {
                publishMutationFailure(provider, attempt: attempt)
            }
            throw error
        }
    }

    private func validate(_ provider: ModelCatalogProvider, token: String) async throws -> String? {
        guard ModelCatalogRequest.validToken(token) else { throw ModelCatalogError.invalidToken }
        if let credentialValidator { return try await credentialValidator(provider, token) }
        let url: URL
        if provider == .huggingFace {
            guard let value = URL(string: "https://huggingface.co/api/whoami-v2") else { throw ModelCatalogError.unsafeURL }
            url = value
        } else {
            var filters = ModelCatalogFilters(); filters.flags["favorites"] = "true"
            url = try ModelCatalogRequest.searchURL(provider: provider, filters: filters)
        }
        let response = try await response(url: url, provider: provider, token: token)
        guard let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { throw ModelCatalogError.invalidResponse }
        if provider == .civitai, object["items"] as? [Any] == nil { throw ModelCatalogError.invalidResponse }
        try Task.checkCancellation()
        return provider == .huggingFace ? object["name"] as? String : nil
    }

    func search(provider: ModelCatalogProvider, filters: ModelCatalogFilters, pageURL: URL? = nil) async throws -> ModelCatalogPage {
        let url = try pageURL ?? ModelCatalogRequest.searchURL(provider: provider, filters: filters)
        let result = try await response(url: url, provider: provider)
        return try ModelCatalogDecoding.page(data: result.data, provider: provider, filters: filters, currentURL: url, link: result.http.value(forHTTPHeaderField: "Link"))
    }

    func detail(_ item: ModelCatalogItem) async throws -> ModelCatalogItem {
        let url = try ModelCatalogRequest.detailURL(provider: item.provider, id: item.id, site: item.civitaiSite)
        let result = try await response(url: url, provider: item.provider)
        return try ModelCatalogDecoding.detail(data: result.data, provider: item.provider, site: item.civitaiSite)
    }

    func favoriteDetail(_ favorite: ModelCatalogFavorite) async throws -> ModelCatalogItem {
        let url = try ModelCatalogRequest.detailURL(provider: favorite.provider, id: favorite.modelID, site: favorite.site)
        let result = try await response(url: url, provider: favorite.provider)
        return try ModelCatalogDecoding.detail(data: result.data, provider: favorite.provider, site: favorite.site)
    }

    func revision(_ item: ModelCatalogItem, version: ModelCatalogVersion) async throws -> ModelCatalogItem {
        guard item.provider == .huggingFace else { return item }
        let base = try ModelCatalogRequest.detailURL(provider: item.provider, id: item.id)
        let result = try await response(url: revisionURL(base, revision: version.revision ?? version.name), provider: item.provider)
        return try ModelCatalogDecoding.detail(data: result.data, provider: item.provider)
    }

    private func revisionURL(_ base: URL, revision: String) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw ModelCatalogError.unsafeURL }
        components.path += "/revision/" + revision
        guard let url = components.url else { throw ModelCatalogError.unsafeURL }; return url
    }

    func civitaiVersion(_ item: ModelCatalogItem, version: ModelCatalogVersion) async throws -> ModelCatalogVersion {
        guard item.provider == .civitai, Int64(version.id) != nil,
              let url = URL(string: "https://\(item.civitaiSite.host)/api/v1/model-versions/\(version.id)") else { throw ModelCatalogError.unsafeURL }
        let result = try await response(url: url, provider: .civitai)
        return try ModelCatalogDecoding.civitaiVersion(data: result.data, modelID: item.id, versionID: version.id, site: item.civitaiSite)
    }

    func revisions(_ item: ModelCatalogItem) async throws -> [ModelCatalogVersion] {
        guard item.provider == .huggingFace else { return item.versions }
        let base = try ModelCatalogRequest.detailURL(provider: item.provider, id: item.id)
        let result = try await response(url: base.appendingPathComponent("refs"), provider: item.provider)
        return try ModelCatalogDecoding.huggingFaceRefs(data: result.data)
    }

    func readme(_ item: ModelCatalogItem, revision: String = "main") async throws -> String {
        guard item.provider == .huggingFace, let base = ModelCatalogRequest.modelURL(provider: item.provider, id: item.id) else { return "" }
        let url = base.appendingPathComponent("raw").appendingPathComponent(revision).appendingPathComponent("README.md")
        let result = try await response(url: url, provider: item.provider, maximumBytes: 512 * 1_024, isText: true)
        guard let text = String(data: result.data, encoding: .utf8) else { throw ModelCatalogError.invalidResponse }
        return text
    }

    func taxonomy() async throws -> [ModelCatalogTaxonomy] {
        guard let url = URL(string: "https://huggingface.co/api/models-tags-by-type") else { throw ModelCatalogError.unsafeURL }
        let result = try await response(url: url, provider: .huggingFace)
        return try ModelCatalogDecoding.huggingFaceTaxonomy(data: result.data)
    }

    func community(_ item: ModelCatalogItem, versionID: String?, kind: ModelCatalogCommunityKind, filters: ModelCatalogCommunityFilters, includeAdult: Bool, pageURL: URL? = nil, adultFilter: ModelCatalogAdultFilter? = nil) async throws -> ModelCatalogCommunityPage {
        let url = try pageURL ?? ModelCatalogRequest.communityURL(provider: item.provider, modelID: item.id, versionID: versionID, kind: kind, filters: filters, includeAdult: includeAdult, adultFilter: adultFilter, site: item.civitaiSite)
        let result = try await response(url: url, provider: item.provider)
        return try ModelCatalogDecoding.community(data: result.data, provider: item.provider, kind: kind, currentURL: url, link: result.http.value(forHTTPHeaderField: "Link"))
    }

    func discussionDetails(_ item: ModelCatalogItem, post: ModelCatalogPost) async throws -> Data {
        guard item.provider == .huggingFace, let number = post.number, number > 0 else { throw ModelCatalogError.unsafeURL }
        let base = try ModelCatalogRequest.detailURL(provider: item.provider, id: item.id)
        let result = try await response(url: base.appendingPathComponent("discussions").appendingPathComponent(String(number)), provider: item.provider)
        return result.data
    }

    func spaceMetadata(_ post: ModelCatalogPost) async throws -> Data {
        guard post.url.host == "huggingface.co", post.url.path.hasPrefix("/spaces/") else { throw ModelCatalogError.unsafeURL }
        var c = URLComponents(url: post.url, resolvingAgainstBaseURL: false)
        c?.path = "/api" + post.url.path; c?.query = nil
        guard let url = c?.url else { throw ModelCatalogError.unsafeURL }
        return try await response(url: url, provider: .huggingFace).data
    }

    func discussion(_ item: ModelCatalogItem, post: ModelCatalogPost) async throws -> [ModelCatalogPost] {
        guard item.provider == .huggingFace, let number = post.number, number > 0 else { throw ModelCatalogError.unsafeURL }
        let base = try ModelCatalogRequest.detailURL(provider: item.provider, id: item.id)
        let result = try await response(url: base.appendingPathComponent("discussions").appendingPathComponent(String(number)), provider: item.provider)
        return try ModelCatalogDecoding.discussionComments(data: result.data, source: post.url)
    }

    func spaceReadme(_ post: ModelCatalogPost, revision: String = "main") async throws -> String {
        guard post.url.host == "huggingface.co", post.url.path.hasPrefix("/spaces/"), !revision.isEmpty, !revision.contains("/"), !revision.contains("..") else { throw ModelCatalogError.unsafeURL }
        let url = post.url.appendingPathComponent("raw").appendingPathComponent(revision).appendingPathComponent("README.md")
        let result = try await response(url: url, provider: .huggingFace, maximumBytes: 512 * 1_024, isText: true)
        guard let value = String(data: result.data, encoding: .utf8) else { throw ModelCatalogError.invalidResponse }
        return value
    }

    func download(_ selection: ModelCatalogDownloadSelection, to destination: URL, progress: @escaping @Sendable (ModelCatalogDownloadProgress) -> Void) async throws -> URL {
        guard ModelCatalogRequest.downloadInitialURL(selection.url.absoluteString, provider: selection.provider) != nil else { throw ModelCatalogError.unsafeURL }
        var request = URLRequest(url: selection.url)
        request.setValue("Stacklume/1.0 (macOS; model catalog)", forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let authenticated = selection.provider == .huggingFace ? ModelCatalogRequest.mayAuthenticateFileURL(selection.url) : ["civitai.com", "civitai.red"].contains(selection.url.host ?? "") && selection.url.path.hasPrefix("/api/download/models/")
        if authenticated, let token = backgroundToken(selection.provider) { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        try Task.checkCancellation()
        do { return try await ModelCatalogDownloads.download(selection, to: destination, request: request, progress: progress) }
        catch { throw accessError(error, provider: selection.provider, hadAuthorization: request.value(forHTTPHeaderField: "Authorization") != nil) }
    }

    func sampleFile(_ media: ModelCatalogPreview, provider: ModelCatalogProvider) async throws -> URL {
        guard media.kind != .image, let url = ModelCatalogRequest.mediaURL(media.url.absoluteString, provider: provider, kind: media.kind) else { throw ModelCatalogError.unsafeURL }
        let request = try mediaRequest(url, provider: provider)
        let configuration = session.configuration; configuration.timeoutIntervalForResource = 60
        let mediaSession = URLSession(configuration: configuration, delegate: ModelCatalogMediaRedirectPolicy(provider: provider, kind: media.kind), delegateQueue: nil)
        defer { mediaSession.invalidateAndCancel() }
        let destination = try ModelCatalogTemporaryMedia.create(extension: url.pathExtension.isEmpty ? (media.kind == .video ? "mp4" : "m4a") : url.pathExtension)
        do {
            let (bytes, response) = try await mediaSession.bytes(for: request)
            guard let http = response as? HTTPURLResponse, let finalURL = http.url, ModelCatalogRequest.redirectedMediaURL(finalURL.absoluteString, provider: provider, kind: media.kind) != nil else { throw ModelCatalogError.invalidResponse }
            guard (200...299).contains(http.statusCode) else { throw accessError(ModelCatalogError.http(http.statusCode, retryAfter: nil), provider: provider, hadAuthorization: request.value(forHTTPHeaderField: "Authorization") != nil) }
            guard let mime = http.mimeType,
                  mime.hasPrefix(media.kind == .video ? "video/" : "audio/") || mime == "application/octet-stream" else { throw ModelCatalogError.invalidResponse }
            let maximum = ModelCatalogTemporaryMedia.maximumFileBytes
            guard http.expectedContentLength <= maximum else { throw ModelCatalogError.mediaTooLarge }
            let handle = try FileHandle(forWritingTo: destination); defer { try? handle.close() }
            var chunk = Data(); chunk.reserveCapacity(65_536); var total = 0
            for try await byte in bytes {
                try Task.checkCancellation(); guard total < maximum else { throw ModelCatalogError.mediaTooLarge }
                chunk.append(byte); total += 1
                if chunk.count == 65_536 { try handle.write(contentsOf: chunk); chunk.removeAll(keepingCapacity: true) }
            }
            if !chunk.isEmpty { try handle.write(contentsOf: chunk) }
            try Task.checkCancellation()
            return destination
        } catch {
            ModelCatalogTemporaryMedia.remove(destination)
            if let error = error as? URLError { throw ModelCatalogError.transportError(error.code) }
            throw error
        }
    }

    func sampleImageData(_ url: URL) async throws -> Data {
        guard ModelCatalogRequest.mayAuthenticateMediaURL(url), ModelCatalogRequest.mediaURL(url.absoluteString, provider: .huggingFace, kind: .image) != nil else { throw ModelCatalogError.unsafeURL }
        try await acquireImageLoad(); defer { releaseImageLoad() }
        let token = backgroundToken(.huggingFace)
        if token != imageCredential { invalidateImages(); imageCredential = token }
        let generation = imageGeneration
        if let cached = imageCache[url] { return cached }
        var request = URLRequest(url: url); request.timeoutInterval = 30
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let mediaSession = URLSession(configuration: session.configuration, delegate: ModelCatalogMediaRedirectPolicy(provider: .huggingFace, kind: .image), delegateQueue: nil)
        defer { mediaSession.invalidateAndCancel() }
        do {
            let (bytes, response) = try await mediaSession.bytes(for: request)
            guard let http = response as? HTTPURLResponse, let finalURL = http.url, ModelCatalogRequest.redirectedMediaURL(finalURL.absoluteString, provider: .huggingFace, kind: .image) != nil else { throw ModelCatalogError.invalidResponse }
            guard (200...299).contains(http.statusCode) else { throw accessError(ModelCatalogError.http(http.statusCode, retryAfter: nil), provider: .huggingFace, hadAuthorization: token != nil) }
            guard http.mimeType?.hasPrefix("image/") == true || http.mimeType == "application/octet-stream" else { throw ModelCatalogError.invalidResponse }
            let maximum = 24 * 1_024 * 1_024
            guard http.expectedContentLength <= maximum else { throw ModelCatalogError.tooLarge }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation(); guard data.count < maximum else { throw ModelCatalogError.tooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard generation == imageGeneration else { throw CancellationError() }
            if imageCacheBytes + data.count > 32 * 1_024 * 1_024 || imageCache.count >= 12 { imageCache.removeAll(); imageCacheBytes = 0 }
            imageCache[url] = data; imageCacheBytes += data.count
            return data
        } catch {
            if let error = error as? URLError { throw ModelCatalogError.transportError(error.code) }
            throw error
        }
    }

    private func mediaRequest(_ url: URL, provider: ModelCatalogProvider) throws -> URLRequest {
        var request = URLRequest(url: url); request.timeoutInterval = 30
        request.setValue("Stacklume/1.0 (macOS; model catalog)", forHTTPHeaderField: "User-Agent")
        if provider == .huggingFace, ModelCatalogRequest.mayAuthenticateMediaURL(url), let token = backgroundToken(provider) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func invalidateImages() {
        imageGeneration = UUID(); imageCache.removeAll(); imageCacheBytes = 0
    }

    private func acquireImageLoad() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if activeImageLoads < 2 { activeImageLoads += 1; return }
            try await withCheckedThrowingContinuation { waitingImageLoads.append((id, $0)) }
        } onCancel: {
            Task { await self.cancelWaitingImageLoad(id) }
        }
        if Task.isCancelled { releaseImageLoad(); throw CancellationError() }
    }

    private func releaseImageLoad() {
        if !waitingImageLoads.isEmpty { waitingImageLoads.removeFirst().1.resume() }
        else { activeImageLoads -= 1 }
    }

    private func cancelWaitingImageLoad(_ id: UUID) {
        guard let index = waitingImageLoads.firstIndex(where: { $0.0 == id }) else { return }
        waitingImageLoads.remove(at: index).1.resume(throwing: CancellationError())
    }

    private struct Response: Sendable {
        let data: Data
        let http: HTTPURLResponse
    }

    private func accessError(_ error: any Error, provider: ModelCatalogProvider, hadAuthorization: Bool) -> any Error {
        guard usesStoredCredentials, !hadAuthorization, [.checking, .authorizationRequired, .unavailable, .accountUnavailable, .accessUnverified].contains(credentialAccess.status(provider)),
              case ModelCatalogError.http(let code, _) = error, code == 401 || code == 403 else { return error }
        return ModelCatalogError.keychainAccessRequired
    }

    private func response(url: URL, provider: ModelCatalogProvider, token explicitToken: String? = nil, maximumBytes: Int = ModelCatalogRequest.maximumJSONBytes, isText: Bool = false) async throws -> Response {
        guard ModelCatalogRequest.isAllowedAPIURL(url, provider: provider) else { throw ModelCatalogError.unsafeURL }
        var request = URLRequest(url: url)
        request.setValue(isText ? "text/plain" : "application/json", forHTTPHeaderField: "Accept")
        request.setValue("Stacklume/1.0 (macOS; model catalog)", forHTTPHeaderField: "User-Agent")
        let token = explicitToken ?? backgroundToken(provider)
        if let token {
            guard ModelCatalogRequest.validToken(token) else { throw ModelCatalogError.invalidToken }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (bytes, raw) = try await session.bytes(for: request)
            guard let http = raw as? HTTPURLResponse, http.url == url else { throw ModelCatalogError.invalidResponse }
            guard (200...299).contains(http.statusCode) else {
                let retry = http.value(forHTTPHeaderField: "Retry-After").map { String($0.prefix(80)) }
                throw accessError(ModelCatalogError.http(http.statusCode, retryAfter: retry), provider: provider, hadAuthorization: token != nil)
            }
            if http.expectedContentLength > Int64(maximumBytes) { throw ModelCatalogError.tooLarge }
            if !isText, !(http.mimeType?.lowercased().contains("json") ?? false) { throw ModelCatalogError.invalidResponse }
            var data = Data(); data.reserveCapacity(min(maximumBytes, 256 * 1_024))
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumBytes else { throw ModelCatalogError.tooLarge }
                data.append(byte)
            }
            return Response(data: data, http: http)
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            throw ModelCatalogError.transportError(error.code)
        }
        catch let error as ModelCatalogError { throw error }
        catch { throw ModelCatalogError.invalidResponse }
    }
}
