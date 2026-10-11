import Foundation

enum ModelCatalogResultWindow {
    static let maximumItems = 300
    static let pageSizes = [30, 60, 100]
    static func validatedPageSize(_ value: Int) -> Int { pageSizes.contains(value) ? value : 60 }
    static func canAppend(count: Int, pageSize: Int) -> Bool { count + validatedPageSize(pageSize) <= maximumItems }
    static func appending(_ page: [ModelCatalogItem], to current: [ModelCatalogItem]) throws -> [ModelCatalogItem] {
        var seen: Set<String> = []
        let merged = (current + page).filter { seen.insert($0.provider.rawValue + ":" + $0.id).inserted }
        guard merged.count <= maximumItems else { throw ModelCatalogError.tooLarge }
        return merged
    }
}

struct ModelCatalogResultSummary: Sendable {
    let kind: String?
    let baseModel: String?
    let versionName: String?
    let revision: String?
    let otherBaseModels: [String]
    let otherVersionCount: Int

    init(item: ModelCatalogItem, version: ModelCatalogVersion? = nil) {
        let first = version ?? item.versions.first
        let card: [String: Any]? = item.provider == .huggingFace && item.metadataMatches(version: version)
            ? item.rawMetadata.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["cardData"] as? [String: Any]
            : nil
        let publishedBases = card?["base_model"] as? [String] ?? (card?["base_model"] as? String).map { [$0] } ?? []
        let primaryBase = first?.baseModel ?? publishedBases.first
        kind = item.kind; baseModel = primaryBase; versionName = first?.name; revision = first?.revision
        var seen: Set<String> = []
        otherBaseModels = (item.versions.compactMap(\.baseModel) + publishedBases).filter { $0 != primaryBase && seen.insert($0).inserted }
        otherVersionCount = max(0, item.versions.count - (first == nil ? 0 : 1))
    }

    var versionLabel: String? {
        guard let versionName else { return nil }
        return "Versión: " + versionName + (revision.flatMap { $0 != versionName ? " · " + String($0.prefix(8)) : nil } ?? "")
    }
    var otherBasesLabel: String? {
        guard !otherBaseModels.isEmpty else { return nil }
        return "Otras bases: " + otherBaseModels.prefix(2).joined(separator: ", ") + (otherBaseModels.count > 2 ? " y \(otherBaseModels.count - 2) más" : "")
    }
}

enum ModelCatalogPreviewSize: String, CaseIterable, Identifiable, Sendable {
    case compact, comfortable, large
    var id: String { rawValue }
    var title: String { switch self { case .compact: "Compactas"; case .comfortable: "Medianas"; case .large: "Grandes" } }
    var minimumCardWidth: CGFloat { switch self { case .compact: 220; case .comfortable: 290; case .large: 360 } }
    var maximumCardWidth: CGFloat { minimumCardWidth + 100 }
    var previewHeight: CGFloat { switch self { case .compact: 180; case .comfortable: 240; case .large: 300 } }
    var rowPreviewSize: CGFloat { switch self { case .compact: 72; case .comfortable: 100; case .large: 132 } }
    func cardWidth(in viewport: CGFloat) -> CGFloat { min(minimumCardWidth, max(1, viewport)) }
}

struct ModelCatalogCoverCandidates: Sendable {
    let media: [ModelCatalogPreview]
    let urls: [URL]

    init(item: ModelCatalogItem, adultFilter: ModelCatalogAdultFilter) {
        var seenMedia: Set<String> = []
        media = (item.visiblePreviews(adultFilter: adultFilter) + item.examples.flatMap(\.media).filter {
            adultFilter.allows($0.contentRating, provider: item.provider)
        }).filter { seenMedia.insert($0.id).inserted }
        var seenURLs: Set<URL> = []
        urls = media.flatMap { ModelCatalogPreviewCandidates(media: $0, provider: item.provider).urls }
            .filter { seenURLs.insert($0).inserted }
    }
}

struct ModelCatalogPreviewCandidates: Sendable {
    let urls: [URL]

    init(media: ModelCatalogPreview, provider: ModelCatalogProvider? = nil) {
        let huggingFaceHosts: Set<String> = ["huggingface.co", "cdn-uploads.huggingface.co", "cdn-thumbnails.huggingface.co", "cdn-media.huggingface.co"]
        let resolvedProvider = provider ?? (huggingFaceHosts.contains(media.url.host?.lowercased() ?? "") ? .huggingFace : .civitai)
        let published: [URL?] = media.kind == .image
            ? [media.thumbnailURL, media.url, media.originalURL, media.fullSizeURL]
            : [media.thumbnailURL, media.kind == .video && resolvedProvider == .civitai
                ? ModelCatalogRequest.civitaiVideoStillURL(media.url) : nil]
        var seen: Set<URL> = []
        urls = published.compactMap { $0 }.compactMap {
            ModelCatalogRequest.previewURL($0.absoluteString, provider: resolvedProvider)
        }.filter { seen.insert($0).inserted }
    }
}
