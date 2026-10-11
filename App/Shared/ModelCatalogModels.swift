import Foundation

enum ModelCatalogProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case huggingFace, civitai
    var id: String { rawValue }
    var title: String { self == .huggingFace ? "Hugging Face" : "Civitai" }
    var host: String { self == .huggingFace ? "huggingface.co" : "civitai.com" }
    var symbol: String { self == .huggingFace ? "cpu" : "photo.on.rectangle.angled" }
    var tokenSettingsURL: URL? { URL(string: "https://\(host)/\(self == .huggingFace ? "settings/tokens" : "user/account")") }
}

enum ModelCatalogConnectionStatus: Sendable, Equatable {
    case checking, absent, available, authorizationRequired, unavailable, accountUnavailable, accessUnverified
    var canUseAccount: Bool { self == .available }
    var hasSavedCredential: Bool { [.available, .authorizationRequired, .accountUnavailable].contains(self) }
    var message: String {
        switch self {
        case .checking: "Catálogo público · comprobando el acceso al Llavero"
        case .absent: "Catálogo público · conecta tu cuenta para acceder a sus permisos"
        case .available: "Conectado · visibilidad según los permisos de tu cuenta"
        case .authorizationRequired: "Cuenta guardada · acceso al Llavero pendiente · catálogo público disponible"
        case .unavailable: "Llavero no disponible · catálogo público disponible"
        case .accountUnavailable: "Cuenta sin validar · catálogo público disponible · revisa la clave y los permisos"
        case .accessUnverified: "Catálogo público · acceso de cuenta sin comprobar"
        }
    }
}

struct ModelCatalogCredentialRead: Sendable {
    let status: ModelCatalogConnectionStatus
    let token: String?
    static func keychain(status: Int32, data: Data?) -> Self {
        switch status {
        case 0:
            guard let data, let token = String(data: data, encoding: .utf8), ModelCatalogRequest.validToken(token) else { return .init(status: .unavailable, token: nil) }
            return .init(status: .available, token: token)
        case -25300: return .init(status: .absent, token: nil)
        case -25308, -25293, -128: return .init(status: .authorizationRequired, token: nil)
        default: return .init(status: .unavailable, token: nil)
        }
    }
}

struct ModelCatalogCredentialAccess: Sendable {
    typealias Reader = @Sendable (ModelCatalogProvider, Bool) -> ModelCatalogCredentialRead
    let reader: Reader
    private var authorizedTokens: [ModelCatalogProvider: String] = [:]
    private var statuses: [ModelCatalogProvider: ModelCatalogConnectionStatus] = [:]
    private var pendingProbes: [ModelCatalogProvider: UUID] = [:]
    private var currentProbes: [ModelCatalogProvider: UUID] = [:]

    init(reader: @escaping Reader) {
        self.reader = reader
    }

    func background(_ provider: ModelCatalogProvider) -> ModelCatalogCredentialRead {
        .init(status: status(provider), token: authorizedTokens[provider])
    }

    mutating func beginProbe(_ provider: ModelCatalogProvider) -> UUID? {
        guard statuses[provider] == nil, pendingProbes[provider] == nil else { return nil }
        let ticket = UUID()
        pendingProbes[provider] = ticket; currentProbes[provider] = ticket; statuses[provider] = .checking
        return ticket
    }

    func isCurrentProbe(_ provider: ModelCatalogProvider, ticket: UUID) -> Bool { currentProbes[provider] == ticket }

    @discardableResult mutating func completeProbe(_ provider: ModelCatalogProvider, ticket: UUID, result: ModelCatalogCredentialRead) -> Bool {
        guard pendingProbes[provider] == ticket else { return false }
        pendingProbes[provider] = nil
        guard currentProbes[provider] == ticket else { return false }
        currentProbes[provider] = nil
        if result.status == .available {
            guard let token = result.token, ModelCatalogRequest.validToken(token) else { statuses[provider] = .unavailable; return true }
            authorizedTokens[provider] = token
        } else { authorizedTokens[provider] = nil }
        statuses[provider] = result.status
        return true
    }

    mutating func invalidateProbe(_ provider: ModelCatalogProvider) {
        currentProbes[provider] = nil
    }

    mutating func authorizationFailed(_ provider: ModelCatalogProvider, status: ModelCatalogConnectionStatus) {
        guard self.status(provider) != .available, !status.canUseAccount else { return }
        invalidateProbe(provider)
        authorizedTokens[provider] = nil; statuses[provider] = status
    }

    mutating func mutationOutcomeUnverified(_ provider: ModelCatalogProvider) {
        invalidateProbe(provider)
        authorizedTokens[provider] = nil; statuses[provider] = .accessUnverified
    }

    mutating func authorized(_ provider: ModelCatalogProvider, token: String) throws {
        guard ModelCatalogRequest.validToken(token) else { throw ModelCatalogError.invalidToken }
        invalidateProbe(provider)
        authorizedTokens[provider] = token; statuses[provider] = .available
    }

    mutating func forget(_ provider: ModelCatalogProvider) {
        invalidateProbe(provider)
        authorizedTokens[provider] = nil; statuses[provider] = .absent
    }

    func status(_ provider: ModelCatalogProvider) -> ModelCatalogConnectionStatus { statuses[provider] ?? .checking }
}

final class ModelCatalogCredentialOperation: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var isValid = true
    private var mutationStarted = false
    func invalidate() { lock.lock(); isValid = false; lock.unlock() }
    func check() throws {
        lock.lock(); let valid = isValid; lock.unlock()
        guard valid else { throw CancellationError() }
    }
    func beginMutation() throws {
        lock.lock(); defer { lock.unlock() }
        guard isValid else { throw CancellationError() }
        mutationStarted = true
    }
    var hasStartedMutation: Bool { lock.lock(); defer { lock.unlock() }; return mutationStarted }
}

enum ModelCatalogCivitaiSite: String, CaseIterable, Codable, Sendable {
    case standard, red
    var host: String { self == .standard ? "civitai.com" : "civitai.red" }
    var title: String { self == .standard ? "Civitai" : "Civitai RED" }
}

enum ModelCatalogContentRating: String, Codable, Sendable {
    case pg, pg13, r, x, xxx, blocked, unknown
    var title: String {
        switch self { case .pg: "PG"; case .pg13: "PG-13"; case .r: "R"; case .x: "X"; case .xxx: "XXX"; case .blocked: "Bloqueado"; case .unknown: "Sin clasificación publicada" }
    }
    static func decode(level: Any?, legacy: Any? = nil) -> Self {
        if let number = level as? Int {
            for (bit, rating) in [(32, Self.blocked), (16, .xxx), (8, .x), (4, .r), (2, .pg13), (1, .pg)] where number & bit != 0 { return rating }
        }
        if let label = level as? String {
            switch label.lowercased() { case "none", "pg", "1": return .pg; case "pg13", "pg-13", "soft", "2": return .pg13; case "r", "mature", "4": return .r; case "x", "8": return .x; case "xxx", "16": return .xxx; case "blocked", "32": return .blocked; default: break }
        }
        if let value = legacy as? Bool { return value ? .r : .pg }
        if let value = legacy as? String { return decode(level: value) }
        return .unknown
    }
}

enum ModelCatalogAdultFilter: String, CaseIterable, Codable, Sendable {
    case exclude, all, only
    var title: String { switch self { case .exclude: "Excluir NSFW"; case .all: "Todo"; case .only: "Solo NSFW" } }
    var browsingLevel: String { switch self { case .exclude: "3"; case .all: "31"; case .only: "28" } }
    func allows(_ rating: ModelCatalogContentRating, provider: ModelCatalogProvider) -> Bool {
        guard rating != .blocked else { return false }
        switch self {
        case .all: return true
        case .exclude: return rating == .pg || rating == .pg13 || (provider == .huggingFace && rating == .unknown)
        case .only: return [.r, .x, .xxx].contains(rating)
        }
    }
}

struct ModelCatalogFilters: Equatable, Sendable {
    var pageSize = 60
    var query = ""
    var author = ""
    var sort = ""
    var descending = true
    var tags = ""
    var task = ""
    var library = ""
    var license = ""
    var language = ""
    var datasets = ""
    var apps = ""
    var inferenceProviders = ""
    var parameters = ""
    var gated = ""
    var warm = false
    var types = ""
    var baseModels = ""
    var period = "AllTime"
    var checkpointType = ""
    var fileFormats = ""
    var modelIDs = ""
    var versionIDs = ""
    var status = ""
    var availability = ""
    var periodMode = ""
    var adultFilter: ModelCatalogAdultFilter = .exclude
    var civitaiSite: ModelCatalogCivitaiSite = .standard
    var includeAdult: Bool {
        get { adultFilter != .exclude }
        set { adultFilter = newValue ? .all : .exclude }
    }
    var flags: [String: String] = [:]
    var requireCreditOptional = false
    var requireDerivatives = false
    var requireDifferentLicenses = false
    var commercialUse = ""

    static func terms(_ value: String) -> [String] {
        var seen: Set<String> = []
        return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

struct ModelCatalogPreview: Identifiable, Hashable, Codable, Sendable {
    let url: URL
    var isAdult: Bool
    var kind: ModelCatalogMediaKind = .image
    var identifier: String?
    var fullSizeURL: URL?
    var thumbnailURL: URL?
    var originalURL: URL?
    var sourceURL: URL?
    var title = ""
    var author: String?
    var width: Int?
    var height: Int?
    var createdAt: String?
    var versionIDs: [String] = []
    var parameters: [ModelCatalogParameter] = []
    var contentRating: ModelCatalogContentRating = .unknown
    var rawMetadata: Data?
    var id: String { identifier ?? url.absoluteString }

    func applyingContentRating(_ rating: ModelCatalogContentRating) -> Self {
        guard rating != .unknown, contentRating != .blocked else { return self }
        var result = self
        result.contentRating = rating
        result.isAdult = [.r, .x, .xxx, .blocked].contains(rating)
        return result
    }
}

enum ModelCatalogMediaKind: String, Hashable, Codable, Sendable { case image, video, audio }

struct ModelCatalogParameter: Identifiable, Hashable, Codable, Sendable {
    let name: String
    let value: String
    var id: String { name }
}

enum ModelCatalogCommunityKind: String, CaseIterable, Sendable {
    case images, spaces, discussions
    var title: String {
        switch self { case .images: "Galería de la comunidad"; case .spaces: "Spaces vinculados"; case .discussions: "Conversaciones" }
    }
}

struct ModelCatalogCommunityFilters: Hashable, Sendable {
    var sort = ""
    var period = "AllTime"
    var mediaType = ""
    var author = ""
    var query = ""
    var discussionType = "all"
    var status = "all"
    var requiringMetadata = false
}

struct ModelCatalogPost: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let url: URL
    var author: String?
    var body = ""
    var createdAt: String?
    var status: String?
    var sdk: String?
    var likes: Int?
    var comments: Int?
    var number: Int?
    var media: [ModelCatalogPreview] = []
    var unavailableMediaCount = 0
    var rawMetadata: Data?
    var contentRating: ModelCatalogContentRating?

    func applyingContentRating(_ rating: ModelCatalogContentRating) -> Self {
        var result = self
        result.contentRating = rating == .unknown ? contentRating ?? .unknown : rating
        result.media = media.map { $0.applyingContentRating(rating) }
        return result
    }

    func representativePreview(provider: ModelCatalogProvider, adultFilter: ModelCatalogAdultFilter) -> ModelCatalogPreview? {
        media.first { adultFilter.allows($0.contentRating, provider: provider) }
    }
}

struct ModelCatalogCommunityPage: Sendable {
    var media: [ModelCatalogPreview] = []
    var posts: [ModelCatalogPost] = []
    var nextURL: URL?
    var total: Int?
    var unavailableMediaCount = 0
}

struct ModelCatalogMarkdownMedia: Sendable {
    var media: [ModelCatalogPreview] = []
    var unavailableCount = 0
}

struct ModelCatalogFile: Identifiable, Hashable, Sendable {
    let name: String
    var sizeBytes: Int64?
    var sizeIsApproximate = false
    var format: String?
    var scan: String?
    var downloadURL: URL?
    var sha256: String?
    var rawMetadata: Data?
    var id: String { name }
}

struct ModelCatalogVersion: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let revision: String?
    let baseModel: String?
    let createdAt: String?
    let description: String
    let trainedWords: [String]
    let files: [ModelCatalogFile]
    let previews: [ModelCatalogPreview]
    var rawMetadata: Data?
}

struct ModelCatalogItem: Identifiable, Hashable, Sendable {
    let id: String
    let provider: ModelCatalogProvider
    let title: String
    let author: String?
    let kind: String?
    let library: String?
    let description: String
    let tags: [String]
    let licenses: [String]
    let downloads: Int?
    let likes: Int?
    let lastModified: String?
    let isPrivate: Bool
    let gated: String?
    let isAdult: Bool
    let versions: [ModelCatalogVersion]
    let allowsNoCredit: Bool?
    let allowsDerivatives: Bool?
    let allowsDifferentLicenses: Bool?
    let commercialUses: [String]
    let availability: String?
    var examples: [ModelCatalogPost] = []
    var contentRating: ModelCatalogContentRating = .unknown
    var civitaiSite: ModelCatalogCivitaiSite = .standard
    var rawMetadata: Data?

    static func snapshot(provider: ModelCatalogProvider, id: String, title: String, author: String?, site: ModelCatalogCivitaiSite, rating: ModelCatalogContentRating) -> Self {
        .init(id: id, provider: provider, title: title, author: author, kind: nil, library: nil, description: "", tags: [], licenses: [], downloads: nil, likes: nil, lastModified: nil, isPrivate: false, gated: nil, isAdult: [.r, .x, .xxx].contains(rating), versions: [], allowsNoCredit: nil, allowsDerivatives: nil, allowsDifferentLicenses: nil, commercialUses: [], availability: nil, contentRating: rating, civitaiSite: site)
    }

    func bookmarkURL(version: ModelCatalogVersion? = nil) -> URL? {
        guard let base = ModelCatalogRequest.modelURL(provider: provider, id: id, site: civitaiSite) else { return nil }
        guard let version else { return base }
        if provider == .huggingFace {
            return base.appendingPathComponent("tree").appendingPathComponent(version.revision ?? version.name)
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "modelVersionId", value: version.id)]
        return components?.url
    }

    func visiblePreviews(includeAdult: Bool, version: ModelCatalogVersion? = nil) -> [ModelCatalogPreview] {
        (version?.previews ?? versions.flatMap(\.previews)).filter { includeAdult || !$0.isAdult }
    }

    func visiblePreviews(adultFilter: ModelCatalogAdultFilter, version: ModelCatalogVersion? = nil) -> [ModelCatalogPreview] {
        (version?.previews ?? versions.flatMap(\.previews)).filter { adultFilter.allows($0.contentRating, provider: provider) }
    }

    func licenses(for version: ModelCatalogVersion?) -> [String] {
        metadataMatches(version: version) ? licenses : []
    }

    func tags(for version: ModelCatalogVersion?) -> [String] {
        metadataMatches(version: version) ? tags : []
    }

    func metadataMatches(version: ModelCatalogVersion?) -> Bool {
        guard provider == .huggingFace, let version else { return true }
        guard let revision = version.revision else { return false }
        return versions.first?.revision == revision
    }
}

struct ModelCatalogPage: Sendable {
    let items: [ModelCatalogItem]
    let nextURL: URL?
    let total: Int?
}

struct ModelCatalogTaxonomy: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let kind: String
}

enum ModelCatalogError: LocalizedError, Equatable {
    case unsafeURL, invalidResponse, tooLarge, cancelled
    case http(Int, retryAfter: String?)
    case keychain, keychainAccessRequired, credentialBusy, invalidToken
    case connection, timeout, unsupportedMedia, mediaTooLarge
    var errorDescription: String? {
        switch self {
        case .unsafeURL: "El proveedor devolvió una dirección no permitida."
        case .invalidResponse: "El catálogo devolvió una respuesta que no se puede leer."
        case .tooLarge: "La respuesta supera el tamaño permitido. Reduce los filtros o vuelve a intentarlo."
        case .cancelled: "La consulta se ha cancelado."
        case .keychain: "No se pudo acceder al Llavero de macOS."
        case .keychainAccessRequired: "El acceso de cuenta no está disponible todavía. Abre Cuenta para autorizar el Llavero o revisar la clave. El catálogo público sigue disponible."
        case .credentialBusy: "Hay una operación del Llavero pendiente para este proveedor. Espera a que termine antes de guardar o eliminar otra clave. El catálogo público sigue disponible."
        case .invalidToken: "La clave debe contener solo caracteres visibles, sin espacios ni saltos de línea."
        case .connection: "No se pudo conectar con el proveedor. Comprueba la conexión a Internet y vuelve a intentarlo."
        case .timeout: "El proveedor ha tardado demasiado en responder. Vuelve a intentarlo."
        case .unsupportedMedia: "macOS no puede reproducir el formato de esta muestra. Puedes consultar la fuente original."
        case .mediaTooLarge: "Esta muestra supera el límite de reproducción de Stacklume: 64 MiB o 4096 px. Puedes consultar la fuente original."
        case .http(let code, let retry):
            switch code {
            case 401: "El proveedor no reconoce la clave. Conecta una clave válida para esa cuenta."
            case 403: "El proveedor ha denegado el acceso. Comprueba permisos, contenido restringido, región y ajustes de la cuenta."
            case 404: "Este modelo o revisión no está disponible para tu cuenta."
            case 429: "El proveedor ha limitado las consultas.\(retry.map { " Reintenta después de \($0)." } ?? " Espera y vuelve a intentarlo.")"
            case 500...599: "El catálogo no está disponible temporalmente (HTTP \(code)). Vuelve a intentarlo."
            default: "La consulta no se pudo completar (HTTP \(code)). Revisa los filtros."
            }
        }
    }

    static func transportError(_ code: URLError.Code) -> any Error {
        switch code {
        case .cancelled: CancellationError()
        case .timedOut: ModelCatalogError.timeout
        case .cannotParseResponse, .badServerResponse: ModelCatalogError.invalidResponse
        default: ModelCatalogError.connection
        }
    }
}
