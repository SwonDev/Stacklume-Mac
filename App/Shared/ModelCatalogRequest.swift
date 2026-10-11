import Foundation

enum ModelCatalogRequest {
    static let pageSize = 30
    static let maximumJSONBytes = 8 * 1_024 * 1_024
    static let civitaiFlags = ["favorites", "hidden", "primaryFileOnly", "supportsGeneration", "needsReview", "earlyAccess", "paidAccess", "hidePaid", "onSale", "fromPlatform", "followed", "newCreators", "archived"]

    static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4_096 && value.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
    }

    static func isAllowedAPIURL(_ url: URL, provider: ModelCatalogProvider) -> Bool {
        let allowedHosts: Set<String> = provider == .huggingFace ? ["huggingface.co"] : ["civitai.com", "civitai.red"]
        guard url.scheme == "https", allowedHosts.contains(url.host()?.lowercased() ?? ""),
              url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              url.fragment == nil, url.absoluteString.utf8.count <= 16_384,
              !url.path.contains("..") else { return false }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard !query.contains(where: { ["token", "api_key", "apikey", "key", "authorization"].contains($0.name.lowercased()) }) else { return false }
        if provider == .civitai {
            return url.path == "/api/v1/models" || url.path.hasPrefix("/api/v1/models/") || url.path == "/api/v1/tags" || url.path.hasPrefix("/api/v1/model-versions/") || url.path == "/api/v1/images"
        }
        return url.path == "/api/models" || url.path.hasPrefix("/api/models/") || url.path == "/api/spaces" || url.path.hasPrefix("/api/spaces/") || url.path == "/api/models-tags-by-type" || url.path == "/api/whoami-v2" || ((url.path.contains("/resolve/") || url.path.contains("/raw/")) && url.lastPathComponent == "README.md")
    }

    static func modelURL(provider: ModelCatalogProvider, id: String, site: ModelCatalogCivitaiSite = .standard) -> URL? {
        guard !id.isEmpty, id.utf8.count <= 300 else { return nil }
        if provider == .civitai {
            guard id.allSatisfy(\.isNumber), Int64(id) != nil else { return nil }
            return URL(string: "https://\(site.host)/models/\(id)")
        }
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }) else { return nil }
        return URL(string: "https://huggingface.co/\(id)")
    }

    static func searchURL(provider: ModelCatalogProvider, filters f: ModelCatalogFilters, cursor: String? = nil) throws -> URL {
        var c = URLComponents()
        c.scheme = "https"; c.host = provider == .civitai ? f.civitaiSite.host : provider.host
        c.path = provider == .huggingFace ? "/api/models" : "/api/v1/models"
        var q = [URLQueryItem(name: "limit", value: String(ModelCatalogResultWindow.validatedPageSize(f.pageSize)))]
        func add(_ name: String, _ value: String) {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { q.append(URLQueryItem(name: name, value: text)) }
        }
        func multiple(_ name: String, _ value: String, prefix: String = "") {
            for text in ModelCatalogFilters.terms(value) { add(name, text.hasPrefix(prefix) ? text : prefix + text) }
        }
        add(provider == .huggingFace ? "search" : "query", f.query)
        add(provider == .huggingFace ? "author" : "username", f.author)
        add("sort", f.sort.isEmpty ? (provider == .huggingFace ? "trendingScore" : "Most Downloaded") : f.sort)
        if let cursor { add("cursor", cursor) }
        if provider == .huggingFace {
            add("direction", f.descending ? "-1" : "1")
            add("pipeline_tag", f.task)
            multiple("filter", f.tags); multiple("filter", f.library)
            multiple("filter", f.license, prefix: "license:")
            multiple("filter", f.language); multiple("filter", f.datasets, prefix: "dataset:")
            multiple("apps", f.apps); multiple("inference_provider", f.inferenceProviders)
            add("num_parameters", f.parameters); add("gated", f.gated)
            if f.warm { add("inference", "warm") }
            for field in ["author", "downloads", "likes", "tags", "pipeline_tag", "library_name", "lastModified", "gated", "private", "sha", "cardData"] { add("expand", field) }
        } else {
            add("tag", f.tags); multiple("types", f.types); multiple("baseModels", f.baseModels)
            add("period", f.period); add("periodMode", f.periodMode)
            add("checkpointType", f.checkpointType); multiple("fileFormats", f.fileFormats)
            if ModelCatalogFilters.terms(f.fileFormats).count == 1 { multiple("fileFormats", f.fileFormats) }
            multiple("allowCommercialUse", f.commercialUse)
            add("ids", f.modelIDs); add("modelVersionIds", f.versionIDs)
            multiple("status", f.status); add("availability", f.availability)
            if f.adultFilter != .all { add("nsfw", f.adultFilter == .only ? "true" : "false") }
            for name in civitaiFlags { if let value = f.flags[name], ["true", "false"].contains(value) { add(name, value) } }
        }
        c.queryItems = q
        guard let url = c.url, isAllowedAPIURL(url, provider: provider) else { throw ModelCatalogError.unsafeURL }
        return url
    }

    static func detailURL(provider: ModelCatalogProvider, id: String, site: ModelCatalogCivitaiSite = .standard) throws -> URL {
        guard let model = modelURL(provider: provider, id: id, site: site) else { throw ModelCatalogError.unsafeURL }
        guard var c = URLComponents(url: model, resolvingAgainstBaseURL: false) else { throw ModelCatalogError.unsafeURL }
        c.path = (provider == .huggingFace ? "/api/models/" : "/api/v1/models/") + id
        if provider == .huggingFace { c.queryItems = [URLQueryItem(name: "blobs", value: "true")] }
        guard let url = c.url else { throw ModelCatalogError.unsafeURL }
        return url
    }

    static func nextHuggingFaceURL(link: String?, current: URL, path: String = "/api/models") -> URL? {
        guard let link else { return nil }
        for part in link.components(separatedBy: ",") {
            guard part.contains("rel=\"next\"") || part.contains("rel=next"),
                  let begin = part.firstIndex(of: "<"), let end = part[begin...].firstIndex(of: ">"),
                  let url = URL(string: String(part[part.index(after: begin)..<end])),
                  url != current, url.path == path, isAllowedAPIURL(url, provider: .huggingFace) else { continue }
            return url
        }
        return nil
    }

    static func previewURL(_ raw: String, provider: ModelCatalogProvider) -> URL? {
        mediaURL(raw, provider: provider, kind: .image)
    }

    static func mediaURL(_ raw: String, provider: ModelCatalogProvider, kind: ModelCatalogMediaKind) -> URL? {
        guard raw.utf8.count <= 4_096, var c = URLComponents(string: raw), c.scheme == "https",
              c.user == nil, c.password == nil, c.port == nil || c.port == 443,
              let host = c.host?.lowercased() else { return nil }
        let hosts: Set<String> = provider == .civitai ? ["image.civitai.com", "images.civitai.com", "imagecache.civitai.com", "blobs-b2.civitai.com"] : ["huggingface.co", "cdn-uploads.huggingface.co", "cdn-thumbnails.huggingface.co", "cdn-media.huggingface.co"]
        let ext = URL(string: raw)?.pathExtension.lowercased() ?? ""
        guard hosts.contains(host), !["svg", "html", "htm", "js", "m3u8"].contains(ext), !c.path.contains("..") else { return nil }
        if kind == .image, ["mp4", "webm", "mov", "mp3", "wav", "flac", "ogg", "m4a"].contains(ext) { return nil }
        let publicBlob = provider == .civitai && host == "blobs-b2.civitai.com" && c.path.hasPrefix("/file/blobs-managed-public/")
        c.fragment = nil
        let publishedOpaqueHubFile = provider == .huggingFace && ext.isEmpty && c.url.map(mayAuthenticateFileURL) == true
        if kind == .video, !["mp4", "webm", "mov"].contains(ext), !publicBlob, !publishedOpaqueHubFile { return nil }
        if kind == .audio, !["mp3", "wav", "flac", "ogg", "m4a", "mp4"].contains(ext), !publishedOpaqueHubFile { return nil }
        let query = c.queryItems ?? []
        guard !query.contains(where: { ["token", "api_key", "apikey", "authorization", "signature", "x-amz-signature"].contains($0.name.lowercased()) }) else { return nil }
        if provider == .civitai, kind == .image { resizeCivitai(&c, pixels: 640) }
        return c.url
    }

    // Destinos exactos publicados en Hub models-downloading y .well-known/meta.json.
    // Las firmas temporales pertenecen al almacenamiento; nunca son claves de la API.
    private static let huggingFaceStorageHosts: Set<String> = [
        "cdn-lfs.hf.co", "cdn-lfs-us-1.hf.co", "cdn-lfs-eu-1.hf.co",
        "transfer.xethub.hf.co", "transfer.xethub-eu.hf.co",
        "cas-server.xethub.hf.co", "cas-server.xethub-eu.hf.co",
        "aws.cdn.hf.co", "us.aws.cdn.hf.co", "us-east-1.aws.cdn.hf.co",
        "us-west-2.aws.cdn.hf.co", "eu-west-3.aws.cdn.hf.co", "ap-southeast-1.aws.cdn.hf.co",
        "us.gcp.cdn.hf.co", "us-east1.us.gcp.cdn.hf.co", "us-central1.us.gcp.cdn.hf.co",
        "us-west4.us.gcp.cdn.hf.co", "europe-west4.us.gcp.cdn.hf.co", "asia-southeast1.us.gcp.cdn.hf.co"
    ]

    static func redirectedMediaURL(_ raw: String, provider: ModelCatalogProvider, kind: ModelCatalogMediaKind) -> URL? {
        if let original = mediaURL(raw, provider: provider, kind: kind) { return original }
        if provider == .huggingFace, kind != .image,
           let url = URL(string: raw), url.pathExtension.isEmpty,
           isHuggingFaceFileCacheURL(url), mediaURL(raw, provider: provider, kind: .image) != nil { return url }
        guard provider == .huggingFace, raw.utf8.count <= 16_384,
              let c = URLComponents(string: raw), c.scheme == "https",
              c.user == nil, c.password == nil, c.port == nil || c.port == 443,
              c.fragment == nil, let host = c.host?.lowercased(),
              huggingFaceStorageHosts.contains(host), !c.path.isEmpty, !c.path.contains("..") else { return nil }
        let names = (c.queryItems ?? []).map { $0.name.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "") }
        guard !names.contains(where: { ["token", "apikey", "authorization", "accesstoken", "hftoken", "civitaiapikey"].contains($0) }) else { return nil }
        return c.url
    }

    static func downloadInitialURL(_ raw: String, provider: ModelCatalogProvider) -> URL? {
        guard raw.utf8.count <= 16_384, let c = URLComponents(string: raw), c.scheme == "https", c.user == nil, c.password == nil,
              c.port == nil || c.port == 443, c.fragment == nil, !c.path.contains(".."), let url = c.url else { return nil }
        let names = (c.queryItems ?? []).map { $0.name.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "") }
        guard !names.contains(where: { ["token", "apikey", "key", "authorization", "accesstoken", "hftoken", "civitaiapikey", "signature", "xamzsignature", "xamzsecuritytoken"].contains($0) }) else { return nil }
        if provider == .huggingFace, mayAuthenticateFileURL(url) { return url }
        if provider == .civitai, ["civitai.com", "civitai.red"].contains(c.host?.lowercased() ?? "") {
            let parts = c.path.split(separator: "/")
            guard parts.count == 4, parts[0] == "api", parts[1] == "download", parts[2] == "models", Int64(parts[3]) != nil,
                  (c.queryItems ?? []).allSatisfy({ ["type", "format", "size", "fp", "quantType", "fileId"].contains($0.name) }) else { return nil }
            return url
        }
        for kind in [ModelCatalogMediaKind.image, .video, .audio] where mediaURL(raw, provider: provider, kind: kind) != nil { return url }
        return nil
    }

    static func downloadRedirectURL(_ raw: String, provider: ModelCatalogProvider) -> URL? {
        if let initial = downloadInitialURL(raw, provider: provider) { return initial }
        if provider == .huggingFace {
            if let url = URL(string: raw), isHuggingFaceFileCacheURL(url) { return url }
            return redirectedMediaURL(raw, provider: provider, kind: .image)
        }
        // Host exacto del almacenamiento firmado devuelto por /api/download/models,
        // verificado públicamente junto al resolver oficial fijado en CAPABILITIES.md.
        guard let c = URLComponents(string: raw), c.scheme == "https", c.user == nil, c.password == nil,
              c.port == nil || c.port == 443, c.fragment == nil, raw.utf8.count <= 16_384,
              c.host?.lowercased() == "civitai-delivery-worker-prod.5ac0637cfd0766c97916cefa3764fbdf.r2.cloudflarestorage.com",
              !c.path.isEmpty, !c.path.contains(".."), let url = c.url else { return nil }
        let names = (c.queryItems ?? []).map { $0.name.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "") }
        guard !names.contains(where: { ["token", "apikey", "authorization", "accesstoken", "civitaiapikey"].contains($0) }) else { return nil }
        return url
    }

    static func matchesDownloadSize(received: Int64, expected: Int64?, approximate: Bool) -> Bool {
        guard received >= 0 else { return false }
        guard let expected else { return true }; guard expected >= 0 else { return false }
        let difference = received >= expected ? received - expected : expected - received
        return difference <= (approximate ? 1_024 : 0)
    }

    static func fileDownloadURL(model: ModelCatalogItem, version: ModelCatalogVersion, file: ModelCatalogFile) -> URL? {
        if model.provider == .civitai {
            guard let source = file.downloadURL, downloadInitialURL(source.absoluteString, provider: .civitai) != nil,
                  var components = URLComponents(url: source, resolvingAgainstBaseURL: false) else { return nil }
            if ["civitai.com", "civitai.red"].contains(components.host ?? "") { components.host = model.civitaiSite.host }
            return components.url.flatMap { downloadInitialURL($0.absoluteString, provider: .civitai) }
        }
        guard let base = modelURL(provider: .huggingFace, id: model.id), !file.name.isEmpty,
              file.name.utf8.count <= 4_096, !file.name.hasPrefix("/"),
              file.name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              let revision = version.revision, !revision.isEmpty, !revision.contains("/"), revision != ".", revision != ".." else { return nil }
        let url = base.appendingPathComponent("resolve").appendingPathComponent(revision).appendingPathComponent(file.name)
        return downloadInitialURL(url.absoluteString, provider: .huggingFace)
    }

    static func mayAuthenticateMediaURL(_ url: URL) -> Bool {
        guard url.host?.lowercased() == "huggingface.co",
              mediaURL(url.absoluteString, provider: .huggingFace, kind: .image) != nil || mediaURL(url.absoluteString, provider: .huggingFace, kind: .video) != nil || mediaURL(url.absoluteString, provider: .huggingFace, kind: .audio) != nil else { return false }
        return mayAuthenticateFileURL(url)
    }

    static func mayRetainMediaAuthorization(original: URL, redirect: URL) -> Bool {
        guard mayAuthenticateMediaURL(original),
              mediaURL(redirect.absoluteString, provider: .huggingFace, kind: .image) != nil || mediaURL(redirect.absoluteString, provider: .huggingFace, kind: .video) != nil || mediaURL(redirect.absoluteString, provider: .huggingFace, kind: .audio) != nil else { return false }
        return mayRetainDownloadAuthorization(original: original, redirect: redirect)
    }

    private static func isSafeHuggingFaceFileURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host?.lowercased() == "huggingface.co", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.fragment == nil, url.absoluteString.utf8.count <= 16_384,
              !url.path.contains(".."), !url.path.contains("//") else { return false }
        let names = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { $0.name.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "") }
        return !names.contains { ["token", "apikey", "key", "authorization", "accesstoken", "hftoken", "signature", "xamzsignature", "xamzsecuritytoken"].contains($0) }
    }

    static func mayAuthenticateFileURL(_ url: URL) -> Bool {
        guard isSafeHuggingFaceFileURL(url) else { return false }
        let parts = url.path.split(separator: "/").map(String.init)
        let namespace = ["datasets", "spaces"].contains(parts.first ?? "") ? 1 : 0
        guard let resolve = parts.firstIndex(of: "resolve"), resolve == namespace + 1 || resolve == namespace + 2,
              parts.count > resolve + 2,
              modelURL(provider: .huggingFace, id: parts[namespace..<resolve].joined(separator: "/")) != nil,
              ![".", ".."].contains(parts[resolve + 1]) else { return false }
        return parts.dropFirst(resolve + 2).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isHuggingFaceFileCacheURL(_ url: URL) -> Bool {
        guard isSafeHuggingFaceFileURL(url) else { return false }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 6, Array(parts.prefix(2)) == ["api", "resolve-cache"], ["models", "datasets", "spaces"].contains(parts[2]) else { return false }
        for repoCount in [1, 2] {
            let commitIndex = 3 + repoCount
            guard parts.count > commitIndex + 1 else { continue }
            if modelURL(provider: .huggingFace, id: parts[3..<commitIndex].joined(separator: "/")) != nil,
               parts[commitIndex].count == 40, parts[commitIndex].allSatisfy({ $0.isASCII && $0.isHexDigit }),
               parts.dropFirst(commitIndex + 1).allSatisfy({ $0 != "." && $0 != ".." }) { return true }
        }
        return false
    }

    static func mayRetainDownloadAuthorization(original: URL, redirect: URL) -> Bool {
        guard mayAuthenticateFileURL(original), isHuggingFaceFileCacheURL(redirect) else { return false }
        let start = original.path.split(separator: "/").map(String.init)
        let end = redirect.path.split(separator: "/").map(String.init)
        let namespace = start.first == "datasets" || start.first == "spaces" ? 1 : 0
        let kind = namespace == 0 ? "models" : start[0]
        guard let resolve = start.firstIndex(of: "resolve") else { return false }
        let repo = Array(start[namespace..<resolve]), commitIndex = 3 + repo.count
        guard end.count > commitIndex + 1, Array(end.prefix(3)) == ["api", "resolve-cache", kind],
              Array(end[3..<commitIndex]) == repo, Array(end.dropFirst(commitIndex + 1)) == Array(start.dropFirst(resolve + 2)) else { return false }
        let revision = start[resolve + 1]
        return revision.count != 40 || !revision.allSatisfy({ $0.isHexDigit && $0.isASCII }) || revision == end[commitIndex]
    }

    static func acceptsDownloadMIME(_ mime: String?, filename: String) -> Bool {
        guard ["text/html", "application/xhtml+xml"].contains(mime?.lowercased() ?? "") else { return true }
        return ["html", "htm", "xhtml"].contains(URL(fileURLWithPath: filename).pathExtension.lowercased())
    }

    static func enlargedPreviewURL(_ url: URL, provider: ModelCatalogProvider) -> URL? {
        guard let safe = previewURL(url.absoluteString, provider: provider), var c = URLComponents(url: safe, resolvingAgainstBaseURL: false) else { return nil }
        if provider == .civitai { resizeCivitai(&c, pixels: 4096) }
        return c.url
    }

    static func civitaiVideoStillURL(_ video: URL) -> URL? {
        guard let safe = mediaURL(video.absoluteString, provider: .civitai, kind: .video),
              safe.host?.lowercased() == "image.civitai.com",
              var components = URLComponents(url: safe, resolvingAgainstBaseURL: false) else { return nil }
        var parts = components.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty,
              parts[3].contains("="), ["mp4", "webm", "mov"].contains(safe.pathExtension.lowercased()) else { return nil }
        // videoStillEdgeOptions del CDN oficial pide un JPEG del mismo vídeo; conserva el desenfoque publicado.
        let replaced: Set<String> = ["anim", "transcode", "width", "height", "original", "optimized"]
        var options = parts[3].split(separator: ",").map(String.init).filter {
            !replaced.contains(String($0.split(separator: "=", maxSplits: 1).first ?? ""))
        }
        options += ["anim=false", "transcode=true", "width=640", "optimized=true"]
        parts[3] = options.joined(separator: ",")
        parts[4] = (parts[4] as NSString).deletingPathExtension + ".jpeg"
        components.path = parts.joined(separator: "/")
        return components.url.flatMap { previewURL($0.absoluteString, provider: .civitai) }
    }

    private static func resizeCivitai(_ components: inout URLComponents, pixels: Int) {
        var parts = components.path.components(separatedBy: "/")
        guard let index = parts.firstIndex(where: { $0.contains("=") }) else { return }
        var options = parts[index].components(separatedBy: ",").filter { !$0.hasPrefix("width=") && !$0.hasPrefix("original=") }
        options.append("width=\(pixels)"); parts[index] = options.joined(separator: ","); components.path = parts.joined(separator: "/")
    }

    static func widgetAssetURL(_ raw: String, modelID: String, revision: String, kind: ModelCatalogMediaKind) -> URL? {
        guard let source = modelURL(provider: .huggingFace, id: modelID) else { return nil }
        return readmeAssetURL(raw, source: source, revision: revision, kind: kind)
    }

    static func readmeAssetURL(_ raw: String, source: URL, revision: String? = nil, kind: ModelCatalogMediaKind) -> URL? {
        if raw.hasPrefix("https://") { return mediaURL(raw, provider: .huggingFace, kind: kind) }
        guard isSafeHuggingFaceFileURL(source), !raw.hasPrefix("/"), !raw.contains(":"), !raw.contains("\\"),
              !raw.split(separator: "/").contains("..") else { return nil }
        var decoded = raw
        for _ in 0..<2 {
            decoded = decoded.removingPercentEncoding ?? decoded
            guard !decoded.split(separator: "/").contains(".."), !decoded.contains("\\"), !decoded.hasPrefix("/") else { return nil }
        }
        let parts = source.path.split(separator: "/").map(String.init)
        let namespace = ["datasets", "spaces"].contains(parts.first ?? "") ? 1 : 0
        let marker = parts.firstIndex { ["tree", "blob", "resolve", "raw"].contains($0) }
        let repoEnd = marker ?? parts.count
        guard repoEnd == namespace + 1 || repoEnd == namespace + 2,
              modelURL(provider: .huggingFace, id: parts[namespace..<repoEnd].joined(separator: "/")) != nil else { return nil }
        let selectedRevision = revision ?? marker.flatMap { parts.count > $0 + 1 ? parts[$0 + 1] : nil } ?? "main"
        guard !selectedRevision.isEmpty, !selectedRevision.contains("/"), !selectedRevision.contains("..") else { return nil }
        let path = raw.hasPrefix("./") ? String(raw.dropFirst(2)) : raw
        guard !path.isEmpty, path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              let base = URL(string: "https://huggingface.co/" + parts.prefix(repoEnd).joined(separator: "/")) else { return nil }
        var url = base.appendingPathComponent("resolve").appendingPathComponent(selectedRevision)
        if let marker, parts[marker] != "tree", parts.count > marker + 3 {
            for folder in parts[(marker + 2)..<(parts.count - 1)] { url.appendPathComponent(folder) }
        }
        url.appendPathComponent(path)
        return mediaURL(url.absoluteString, provider: .huggingFace, kind: kind)
    }

    static func communityURL(provider: ModelCatalogProvider, modelID: String, versionID: String?, kind: ModelCatalogCommunityKind, filters: ModelCatalogCommunityFilters, includeAdult: Bool, cursor: String? = nil, adultFilter: ModelCatalogAdultFilter? = nil, site: ModelCatalogCivitaiSite = .standard) throws -> URL {
        guard modelURL(provider: provider, id: modelID) != nil else { throw ModelCatalogError.unsafeURL }
        var c = URLComponents(); c.scheme = "https"; c.host = provider == .civitai ? site.host : provider.host
        var q: [URLQueryItem] = []
        func add(_ name: String, _ value: String?) {
            if let value, !value.isEmpty { q.append(.init(name: name, value: value)) }
        }
        if provider == .civitai {
            guard kind == .images, versionID == nil || (versionID?.allSatisfy(\.isNumber) ?? false) else { throw ModelCatalogError.unsafeURL }
            c.path = "/api/v1/images"
            add("limit", String(pageSize)); add("modelId", modelID); add("modelVersionId", versionID)
            add("cursor", cursor); add("sort", versionID == nil ? "Newest" : (filters.sort.isEmpty ? "Most Reactions" : filters.sort))
            add("period", filters.period); add("type", filters.mediaType); add("username", filters.author)
            add("withMeta", "true")
            let adult = adultFilter ?? (includeAdult ? .all : .exclude)
            add("browsingLevel", adult.browsingLevel)
            if adult == .exclude { add("nsfw", "false") }
            if filters.requiringMetadata { add("requiringMeta", "true") }
        } else if kind == .spaces {
            c.path = "/api/spaces"; add("models", modelID); add("limit", String(pageSize))
            add("sort", filters.sort.isEmpty ? "likes" : filters.sort); add("author", filters.author); add("search", filters.query)
            for field in ["author", "cardData", "runtime", "sdk", "likes", "lastModified", "tags"] { add("expand", field) }
        } else if kind == .discussions {
            c.path = "/api/models/\(modelID)/discussions"
            add("p", cursor ?? "0"); add("type", filters.discussionType); add("status", filters.status)
            add("sort", filters.sort.isEmpty ? "recently-created" : filters.sort); add("author", filters.author); add("search", filters.query)
        } else { throw ModelCatalogError.unsafeURL }
        c.queryItems = q
        guard let url = c.url, isAllowedAPIURL(url, provider: provider) else { throw ModelCatalogError.unsafeURL }
        return url
    }
}
