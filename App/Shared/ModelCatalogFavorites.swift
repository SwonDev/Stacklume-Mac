import Foundation

enum ModelCatalogFavoriteKind: String, Codable, Sendable {
    case model, sample, post, comment, widget
    var title: String { switch self { case .model: "Modelo"; case .sample: "Muestra"; case .post: "Publicación"; case .comment: "Comentario"; case .widget: "Ejemplo de la ficha" } }
}

struct ModelCatalogFavorite: Identifiable, Codable, Hashable, Sendable {
    let provider: ModelCatalogProvider
    let modelID: String
    let title: String
    let author: String?
    let site: ModelCatalogCivitaiSite
    let createdAt: Date
    var contentRating: ModelCatalogContentRating = .unknown
    var kind: ModelCatalogFavoriteKind?
    var modelRef: String?
    var modelTitle: String?
    var sampleID: String?
    var sourceURL: URL?
    var media: ModelCatalogPreview?
    var post: ModelCatalogPost?
    var id: String {
        guard let kind, kind != .model else { return provider.rawValue + ":" + modelID }
        if kind == .widget { return provider.rawValue + ":" + modelID + ":widget:" + (sampleID ?? "") }
        let identity = kind == .sample ? (sampleID ?? canonicalSource) : canonicalSource + ":" + (sampleID ?? "")
        return provider.rawValue + ":" + kind.rawValue + ":" + identity
    }
    private var canonicalSource: String { (sourceURL?.absoluteString ?? "").replacingOccurrences(of: "https://civitai.red/", with: "https://civitai.com/") }
    var url: URL? { sourceURL ?? ModelCatalogRequest.modelURL(provider: provider, id: modelID, site: site) }
    var isModel: Bool { kind == nil || kind == .model }
    var modelSnapshot: ModelCatalogItem { .snapshot(provider: provider, id: modelID, title: modelTitle ?? title, author: author, site: site, rating: contentRating) }

    static func sample(_ sample: ModelCatalogPreview, model: ModelCatalogItem) -> Self {
        .init(provider: model.provider, modelID: model.id, title: sample.title.isEmpty ? "Muestra · " + model.title : sample.title, author: sample.author, site: model.civitaiSite, createdAt: .now, contentRating: sample.contentRating, kind: .sample, modelRef: model.id, modelTitle: model.title, sampleID: sample.id, sourceURL: sample.sourceURL ?? model.bookmarkURL(), media: sample)
    }
    static func publication(_ post: ModelCatalogPost, model: ModelCatalogItem) -> Self {
        let isSpace = model.provider == .huggingFace && post.url.path.hasPrefix("/spaces/")
        let sourceRating = post.contentRating ?? (isSpace ? post.rawMetadata.map(ModelCatalogDecoding.huggingFacePublishedContentRating) ?? .unknown : model.contentRating)
        return .init(provider: model.provider, modelID: model.id, title: post.title, author: post.author, site: model.civitaiSite, createdAt: .now, contentRating: sourceRating, kind: post.id.hasPrefix("widget:") ? .widget : (post.number == nil && post.url.path.contains("/discussions/") ? .comment : .post), modelRef: model.id, modelTitle: model.title, sampleID: post.id, sourceURL: post.url, post: post.applyingContentRating(sourceRating))
    }
}

enum ModelCatalogFavorites {
    static let defaultsKey = "stacklume.modelCatalog.favorites.v1"
    static let maximumEntries = 10_000
    static let maximumJSONBytes = 8 * 1_024 * 1_024

    static func decode(_ data: Data) throws -> [ModelCatalogFavorite] {
        guard data.count <= maximumJSONBytes else { throw ModelCatalogError.tooLarge }
        let entries = try JSONDecoder().decode([ModelCatalogFavorite].self, from: data)
        guard entries.count <= maximumEntries, entries.allSatisfy(valid) else { throw ModelCatalogError.invalidResponse }
        return merge([], entries.map(restoringSpaceClassification))
    }

    private static func restoringSpaceClassification(_ entry: ModelCatalogFavorite) -> ModelCatalogFavorite {
        guard entry.provider == .huggingFace, entry.url?.path.hasPrefix("/spaces/") == true,
              entry.contentRating != .blocked else { return entry }
        let declared = [entry.post?.rawMetadata, entry.media?.rawMetadata].compactMap { $0 }
            .map(ModelCatalogDecoding.huggingFacePublishedContentRating).first { $0 != .unknown }
        guard let rating = declared ?? entry.post?.contentRating, rating != .unknown else { return entry }
        var result = entry
        result.contentRating = rating
        result.post = entry.post?.applyingContentRating(rating)
        result.media = entry.media?.applyingContentRating(rating)
        return result
    }

    private static func valid(_ entry: ModelCatalogFavorite) -> Bool {
        guard ModelCatalogRequest.modelURL(provider: entry.provider, id: entry.modelID, site: entry.site) != nil,
              entry.modelRef == nil || entry.modelRef == entry.modelID, entry.title.utf8.count <= 8_192,
              (entry.modelTitle?.utf8.count ?? 0) <= 8_192, (entry.author?.utf8.count ?? 0) <= 1_024,
              (entry.sampleID?.utf8.count ?? 0) <= 8_192, let source = entry.url,
              source.scheme == "https", source.user == nil, source.password == nil,
              source.port == nil || source.port == 443, source.absoluteString.utf8.count <= 16_384 else { return false }
        let hosts = entry.provider == .huggingFace ? ["huggingface.co"] : ["civitai.com", "civitai.red"]
        guard hosts.contains(source.host?.lowercased() ?? ""), !source.path.contains(".."),
              !(URLComponents(url: source, resolvingAgainstBaseURL: false)?.queryItems ?? []).contains(where: { ["token", "api_key", "apikey", "authorization", "key"].contains($0.name.lowercased()) }) else { return false }
        if entry.provider == .civitai {
            let parts = source.path.split(separator: "/").map(String.init)
            guard parts.count >= 2, (parts[0] == "models" && parts[1] == entry.modelID) || (parts[0] == "images" && parts.count == 2 && Int64(parts[1]) != nil && entry.kind == .sample) else { return false }
        } else {
            let modelPath = "/" + entry.modelID
            let parts = source.path.split(separator: "/").map(String.init)
            let discussion = source.path.hasPrefix(modelPath + "/discussions/") && Int64(parts.last ?? "") != nil
            let space = parts.count == 3 && parts.first == "spaces" && (entry.kind == .post || entry.kind == .sample)
            guard source.path == modelPath || source.path.hasPrefix(modelPath + "/tree/") || discussion || space else { return false }
        }
        if entry.isModel { return entry.sourceURL == nil || entry.sourceURL == ModelCatalogRequest.modelURL(provider: entry.provider, id: entry.modelID, site: entry.site) }
        guard entry.sampleID?.isEmpty == false else { return false }
        if let media = entry.media {
            guard ModelCatalogRequest.mediaURL(media.url.absoluteString, provider: entry.provider, kind: media.kind) != nil else { return false }
            for candidate in [media.originalURL, media.fullSizeURL, media.thumbnailURL].compactMap({ $0 }) {
                guard ModelCatalogRequest.downloadInitialURL(candidate.absoluteString, provider: entry.provider) != nil else { return false }
            }
        }
        if let post = entry.post { guard post.url == source, post.media.allSatisfy({ validMedia($0, provider: entry.provider) }) else { return false } }
        if entry.kind == .widget { return source == ModelCatalogRequest.modelURL(provider: entry.provider, id: entry.modelID, site: entry.site) && entry.post != nil }
        if entry.kind == .sample { return entry.media != nil }
        return entry.post != nil
    }

    private static func validMedia(_ media: ModelCatalogPreview, provider: ModelCatalogProvider) -> Bool {
        guard ModelCatalogRequest.mediaURL(media.url.absoluteString, provider: provider, kind: media.kind) != nil else { return false }
        return [media.originalURL, media.fullSizeURL, media.thumbnailURL].compactMap { $0 }.allSatisfy { ModelCatalogRequest.downloadInitialURL($0.absoluteString, provider: provider) != nil }
    }

    @discardableResult static func toggle(_ favorite: ModelCatalogFavorite, defaults: UserDefaults = .standard) throws -> Bool {
        var entries = try load(defaults: defaults)
        let result: Bool
        if let index = entries.firstIndex(where: { $0.id == favorite.id }) { entries.remove(at: index); result = false }
        else { entries.insert(favorite, at: 0); result = true }
        try set(entries, defaults: defaults); return result
    }

    static func merge(_ current: [ModelCatalogFavorite], _ incoming: [ModelCatalogFavorite]) -> [ModelCatalogFavorite] {
        var seen: Set<String> = []
        return (current + incoming).filter { seen.insert($0.id).inserted }.sorted { $0.createdAt > $1.createdAt }
    }

    static func encode(_ entries: [ModelCatalogFavorite]) throws -> Data {
        guard entries.count <= maximumEntries else { throw ModelCatalogError.tooLarge }
        let data = try JSONEncoder().encode(entries)
        guard data.count <= maximumJSONBytes else { throw ModelCatalogError.tooLarge }
        return data
    }

    static func load(defaults: UserDefaults = .standard) throws -> [ModelCatalogFavorite] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return try decode(data)
    }

    static func exportJSON(defaults: UserDefaults = .standard) -> Data? { defaults.data(forKey: defaultsKey) }

    static func mergeJSON(_ data: Data, defaults: UserDefaults = .standard) throws {
        let entries = merge(try load(defaults: defaults), try decode(data))
        defaults.set(try encode(entries), forKey: defaultsKey)
    }

    static func set(_ entries: [ModelCatalogFavorite], defaults: UserDefaults = .standard) throws {
        let data = try encode(entries); _ = try decode(data)
        defaults.set(data, forKey: defaultsKey)
    }
}
