import Foundation
import Markdown
import cmark_gfm

enum ModelCatalogDecoding {
    static func page(data: Data, provider: ModelCatalogProvider, filters: ModelCatalogFilters, currentURL: URL, link: String?) throws -> ModelCatalogPage {
        let raw = try JSONSerialization.jsonObject(with: data)
        let objects: [[String: Any]]
        var next: URL?
        var total: Int?
        if provider == .huggingFace {
            guard let array = raw as? [[String: Any]] else { throw ModelCatalogError.invalidResponse }
            objects = array
            next = ModelCatalogRequest.nextHuggingFaceURL(link: link, current: currentURL)
        } else {
            guard let object = raw as? [String: Any], let array = object["items"] as? [[String: Any]] else { throw ModelCatalogError.invalidResponse }
            objects = array
            let metadata = object["metadata"] as? [String: Any] ?? [:]
            total = metadata["totalItems"] as? Int
            if let cursor = scalar(metadata["nextCursor"]), !cursor.isEmpty {
                next = try ModelCatalogRequest.searchURL(provider: provider, filters: filters, cursor: cursor)
            } else if let raw = metadata["nextPage"] as? String, let url = URL(string: raw), url.host == currentURL.host, url.path == "/api/v1/models", ModelCatalogRequest.isAllowedAPIURL(url, provider: provider) {
                next = url
            }
            if next == currentURL { next = nil }
        }
        var seen: Set<String> = []
        let models = objects.compactMap { item($0, provider: provider, site: filters.civitaiSite) }.filter { seen.insert($0.id).inserted }
        return ModelCatalogPage(items: models, nextURL: next, total: total)
    }

    static func detail(data: Data, provider: ModelCatalogProvider, site: ModelCatalogCivitaiSite = .standard) throws -> ModelCatalogItem {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any], let model = item(raw, provider: provider, site: site) else { throw ModelCatalogError.invalidResponse }
        return model
    }

    static func huggingFaceRefs(data: Data) throws -> [ModelCatalogVersion] {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ModelCatalogError.invalidResponse }
        var seen: Set<String> = []
        return ["branches", "tags"].flatMap { raw[$0] as? [[String: Any]] ?? [] }.compactMap { value in
            guard let name = value["name"] as? String, seen.insert(name).inserted else { return nil }
            return ModelCatalogVersion(id: name, name: name, revision: value["targetCommit"] as? String ?? name, baseModel: nil, createdAt: nil, description: "", trainedWords: [], files: [], previews: [])
        }
    }

    static func huggingFaceTaxonomy(data: Data) throws -> [ModelCatalogTaxonomy] {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]] else { throw ModelCatalogError.invalidResponse }
        return raw.keys.sorted().flatMap { kind in
            (raw[kind] ?? []).compactMap { value -> ModelCatalogTaxonomy? in
                guard let id = value["id"] as? String else { return nil }
                return ModelCatalogTaxonomy(id: id, label: value["label"] as? String ?? id, kind: kind)
            }
        }
    }

    static func community(data: Data, provider: ModelCatalogProvider, kind: ModelCatalogCommunityKind, currentURL: URL, link: String?) throws -> ModelCatalogCommunityPage {
        let raw = try JSONSerialization.jsonObject(with: data)
        if provider == .civitai {
            guard let object = raw as? [String: Any], let items = object["items"] as? [[String: Any]] else { throw ModelCatalogError.invalidResponse }
            let metadata = object["metadata"] as? [String: Any] ?? [:]
            var next: URL?
            if let cursor = scalar(metadata["nextCursor"]), !cursor.isEmpty, var c = URLComponents(url: currentURL, resolvingAgainstBaseURL: false) {
                var fields = c.queryItems ?? []; fields.removeAll { $0.name == "cursor" || $0.name == "page" }
                fields.append(.init(name: "cursor", value: cursor)); c.queryItems = fields
                if let url = c.url, url != currentURL, ModelCatalogRequest.isAllowedAPIURL(url, provider: provider) { next = url }
            } else if let text = metadata["nextPage"] as? String, let url = URL(string: text), url.host == currentURL.host, url != currentURL, url.path == "/api/v1/images", ModelCatalogRequest.isAllowedAPIURL(url, provider: provider) { next = url }
            let media = previews(items, provider: provider, site: currentURL.host == "civitai.red" ? .red : .standard)
            return .init(media: media, nextURL: next, total: metadata["totalItems"] as? Int, unavailableMediaCount: items.count - media.count)
        }
        if kind == .spaces {
            guard let items = raw as? [[String: Any]] else { throw ModelCatalogError.invalidResponse }
            let posts = items.compactMap { value -> ModelCatalogPost? in
                guard let id = value["id"] as? String, ModelCatalogRequest.modelURL(provider: provider, id: id) != nil,
                      let url = URL(string: "https://huggingface.co/spaces/\(id)") else { return nil }
                let card = value["cardData"] as? [String: Any] ?? [:]
                let runtime = value["runtime"] as? [String: Any] ?? [:]
                var post = ModelCatalogPost(id: "space:\(id)", title: card["title"] as? String ?? id, url: url, author: value["author"] as? String, body: plainDescription(card["short_description"] as? String ?? ""), createdAt: value["lastModified"] as? String, status: runtime["stage"] as? String, sdk: value["sdk"] as? String, likes: value["likes"] as? Int)
                post.rawMetadata = metadata(value)
                if let text = card["thumbnail"] as? String, let image = ModelCatalogRequest.previewURL(text, provider: provider) {
                    post.media = [.init(url: image, isAdult: false, fullSizeURL: ModelCatalogRequest.enlargedPreviewURL(image, provider: provider), sourceURL: url, title: post.title, author: post.author, rawMetadata: post.rawMetadata)]
                }
                return post.applyingContentRating(huggingFaceContentRating(value))
            }
            return .init(posts: posts, nextURL: ModelCatalogRequest.nextHuggingFaceURL(link: link, current: currentURL, path: "/api/spaces"))
        }
        guard let object = raw as? [String: Any], let discussions = object["discussions"] as? [[String: Any]] else { throw ModelCatalogError.invalidResponse }
        let modelPath = currentURL.path.replacingOccurrences(of: "/api/models/", with: "/").replacingOccurrences(of: "/discussions", with: "")
        let posts = discussions.compactMap { value -> ModelCatalogPost? in
            guard let number = value["num"] as? Int, number > 0, let url = URL(string: "https://huggingface.co\(modelPath)/discussions/\(number)") else { return nil }
            let author = value["author"] as? [String: Any] ?? [:]
            return .init(id: "discussion:\(number)", title: String((value["title"] as? String ?? "Conversación \(number)").prefix(1_000)), url: url, author: author["name"] as? String, createdAt: value["createdAt"] as? String, status: value["status"] as? String, sdk: value["isPullRequest"] as? Bool == true ? "Pull request" : nil, comments: value["numComments"] as? Int, number: number, rawMetadata: metadata(value))
        }
        let count = object["count"] as? Int
        let start = object["start"] as? Int ?? 0
        var next: URL?
        if let count, start + discussions.count < count, var c = URLComponents(url: currentURL, resolvingAgainstBaseURL: false) {
            var fields = c.queryItems ?? []; let page = fields.first { $0.name == "p" }.flatMap { Int($0.value ?? "") } ?? 0
            fields.removeAll { $0.name == "p" }; fields.append(.init(name: "p", value: String(page + 1))); c.queryItems = fields; next = c.url
        }
        return .init(posts: posts, nextURL: next, total: count)
    }

    static func discussionComments(data: Data, source: URL) throws -> [ModelCatalogPost] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let events = object["events"] as? [[String: Any]] else { throw ModelCatalogError.invalidResponse }
        return events.compactMap { event in
            guard event["type"] as? String == "comment", let id = event["id"] as? String else { return nil }
            let data = event["data"] as? [String: Any] ?? [:]
            guard data["hidden"] as? Bool != true else { return nil }
            let latest = data["latest"] as? [String: Any] ?? [:]
            let author = event["author"] as? [String: Any] ?? [:]
            let text = latest["raw"] as? String ?? ""
            var post = ModelCatalogPost(id: id, title: author["name"] as? String ?? "Comentario", url: source, author: author["name"] as? String, body: text, createdAt: event["createdAt"] as? String)
            post.rawMetadata = metadata(event)
            let parsed = markdownMediaResult(text, source: source, author: post.author, rawMetadata: post.rawMetadata)
            post.media = parsed.media; post.unavailableMediaCount = parsed.unavailableCount
            return post
        }
    }

    static func markdownMedia(_ text: String, source: URL) -> [ModelCatalogPreview] {
        markdownMediaResult(text, source: source).media
    }

    static func huggingFaceRepositoryMetadata(data: Data) throws -> (revision: String, contentRating: ModelCatalogContentRating) {
        guard data.count <= ModelCatalogRequest.maximumJSONBytes,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ModelCatalogError.invalidResponse }
        return (value["sha"] as? String ?? "main", huggingFaceContentRating(value))
    }

    static func huggingFacePublishedContentRating(data: Data) -> ModelCatalogContentRating {
        guard data.count <= ModelCatalogRequest.maximumJSONBytes,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unknown }
        let direct = huggingFaceContentRating(value)
        guard direct == .unknown, let source = value["metadata"] as? [String: Any] else { return direct }
        return huggingFaceContentRating(source)
    }

    private static func huggingFaceContentRating(_ value: [String: Any]) -> ModelCatalogContentRating {
        let card = value["cardData"] as? [String: Any] ?? [:]
        let tags = (value["tags"] as? [String] ?? []) + (card["tags"] as? [String] ?? [])
        return tags.contains { ["nsfw", "not-for-all-audiences"].contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) } ? .r : .unknown
    }

    static func markdownMediaResult(_ text: String, source: URL, revision: String? = nil, rating: ModelCatalogContentRating = .unknown, author: String? = nil, rawMetadata: Data? = nil) -> ModelCatalogMarkdownMedia {
        var seen: Set<URL> = []
        var result = ModelCatalogMarkdownMedia()
        var payloadFields: [String: Any] = ["source": source.absoluteString, "text": text]
        if let revision { payloadFields["revision"] = revision }
        if let rawMetadata, let original = try? JSONSerialization.jsonObject(with: rawMetadata) { payloadFields["metadata"] = original }
        let payload = metadata(payloadFields)
        let sourceRating = rating == .unknown && source.host == "huggingface.co" && source.path.hasPrefix("/spaces/")
            ? rawMetadata.map(huggingFacePublishedContentRating) ?? .unknown : rating
        let mediaExtensions = ["jpeg", "jpg", "png", "webp", "gif", "avif", "heic", "bmp", "mp4", "webm", "mov", "mp3", "wav", "flac", "ogg", "m4a"]
        func appendMedia(_ raw: String, requiresPreview: Bool, publishedKind: ModelCatalogMediaKind? = nil) {
            guard raw.utf8.count <= 4_096 else { if requiresPreview { result.unavailableCount += 1 }; return }
            let ext = URL(string: raw)?.pathExtension.lowercased() ?? ""
            guard requiresPreview || publishedKind != nil || mediaExtensions.contains(ext) else { return }
            let kind: ModelCatalogMediaKind = publishedKind ?? (["mp4", "webm", "mov"].contains(ext) ? .video : ["mp3", "wav", "flac", "ogg", "m4a"].contains(ext) ? .audio : .image)
            let resolved: URL?
            if let relative = URLComponents(string: raw), relative.scheme == nil, relative.host == nil {
                if let asset = ModelCatalogRequest.readmeAssetURL(relative.path, source: source, revision: revision, kind: kind),
                   var destination = URLComponents(url: asset, resolvingAgainstBaseURL: false) {
                    destination.percentEncodedQuery = relative.percentEncodedQuery
                    destination.fragment = relative.fragment
                    resolved = destination.url.flatMap { ModelCatalogRequest.mediaURL($0.absoluteString, provider: .huggingFace, kind: kind) }
                } else { resolved = nil }
            } else { resolved = ModelCatalogRequest.readmeAssetURL(raw, source: source, revision: revision, kind: kind) }
            guard let url = resolved else { result.unavailableCount += 1; return }
            guard seen.insert(url).inserted else { return }
            result.media.append(.init(url: url, isAdult: [.r, .x, .xxx].contains(sourceRating), kind: kind, fullSizeURL: kind == .image ? url : nil, sourceURL: source, title: "Muestra de la publicación", author: author, contentRating: sourceRating, rawMetadata: payload))
        }
        var ignoredHTMLTag: String?
        var mediaContainers: [(name: String, kind: ModelCatalogMediaKind)] = []
        func scanHTML(_ html: String) {
            let bytes = Array(html.utf8)
            var cursor = 0
            func starts(_ value: String, at offset: Int) -> Bool {
                let pattern = Array(value.utf8)
                return offset + pattern.count <= bytes.count && bytes[offset..<(offset + pattern.count)].elementsEqual(pattern)
            }
            func advanceToEnd(_ suffix: String) {
                while cursor < bytes.count {
                    if starts(suffix, at: cursor) { cursor += suffix.utf8.count; return }
                    cursor += 1
                }
            }
            func isSpace(_ byte: UInt8) -> Bool { [9, 10, 12, 13, 32].contains(byte) }
            func isLetter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
            func isName(_ byte: UInt8) -> Bool { isLetter(byte) || (48...57).contains(byte) || [45, 46, 58, 95].contains(byte) }
            while cursor < bytes.count {
                guard bytes[cursor] == 60 else { cursor += 1; continue }
                if let ignored = ignoredHTMLTag {
                    var end = cursor + 2
                    if starts("</", at: cursor) {
                        while end < bytes.count, isName(bytes[end]) { end += 1 }
                    }
                    let closingName = starts("</", at: cursor) ? String(decoding: bytes[(cursor + 2)..<end], as: UTF8.self).lowercased() : ""
                    guard ignored != "plaintext", closingName == ignored, end < bytes.count,
                          isSpace(bytes[end]) || bytes[end] == 62 else { cursor += 1; continue }
                }
                if starts("<!--", at: cursor) {
                    cursor += 4
                    if starts(">", at: cursor) { cursor += 1; continue }
                    if starts("->", at: cursor) { cursor += 2; continue }
                    while cursor < bytes.count {
                        if starts("-->", at: cursor) { cursor += 3; break }
                        if starts("--!>", at: cursor) { cursor += 4; break }
                        cursor += 1
                    }
                    continue
                }
                if starts("<![CDATA[", at: cursor) { cursor += 9; advanceToEnd("]]>"); continue }
                if starts("<?", at: cursor) { cursor += 2; advanceToEnd("?>"); continue }
                if starts("<!", at: cursor) { cursor += 2; advanceToEnd(">"); continue }
                cursor += 1
                let closing = cursor < bytes.count && bytes[cursor] == 47
                if closing { cursor += 1 }
                let nameStart = cursor
                guard cursor < bytes.count, isLetter(bytes[cursor]) else { continue }
                while cursor < bytes.count, isName(bytes[cursor]) { cursor += 1 }
                let name = String(decoding: bytes[nameStart..<cursor], as: UTF8.self).lowercased()
                var attributes: [String: String] = [:]
                var complete = false
                while cursor < bytes.count {
                    while cursor < bytes.count, isSpace(bytes[cursor]) { cursor += 1 }
                    if cursor < bytes.count, bytes[cursor] == 62 { cursor += 1; complete = true; break }
                    if starts("/>", at: cursor) { cursor += 2; complete = true; break }
                    let attributeStart = cursor
                    guard cursor < bytes.count, isLetter(bytes[cursor]) || [58, 95].contains(bytes[cursor]) else { cursor += 1; continue }
                    while cursor < bytes.count, isName(bytes[cursor]) { cursor += 1 }
                    let attributeName = String(decoding: bytes[attributeStart..<cursor], as: UTF8.self).lowercased()
                    while cursor < bytes.count, isSpace(bytes[cursor]) { cursor += 1 }
                    guard cursor < bytes.count, bytes[cursor] == 61 else {
                        if attributes[attributeName] == nil { attributes[attributeName] = "" }
                        continue
                    }
                    cursor += 1
                    while cursor < bytes.count, isSpace(bytes[cursor]) { cursor += 1 }
                    let quote: UInt8? = cursor < bytes.count && [34, 39].contains(bytes[cursor]) ? bytes[cursor] : nil
                    if quote != nil { cursor += 1 }
                    let valueStart = cursor
                    while cursor < bytes.count {
                        if let quote { if bytes[cursor] == quote { break } }
                        else if isSpace(bytes[cursor]) || bytes[cursor] == 62 { break }
                        cursor += 1
                    }
                    let value = String(decoding: bytes[valueStart..<cursor], as: UTF8.self)
                    if quote != nil, cursor < bytes.count { cursor += 1 }
                    if attributes[attributeName] == nil { attributes[attributeName] = value }
                }
                guard complete else { continue }
                if let ignored = ignoredHTMLTag {
                    if closing && name == ignored { ignoredHTMLTag = nil }
                    continue
                }
                if !closing, ["script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes", "plaintext"].contains(name) { ignoredHTMLTag = name; continue }
                if ["video", "audio", "picture"].contains(name) {
                    if closing {
                        if let index = mediaContainers.lastIndex(where: { $0.name == name }) { mediaContainers.removeSubrange(index...) }
                    } else { mediaContainers.append((name, name == "video" ? .video : name == "audio" ? .audio : .image)) }
                }
                guard !closing, ["img", "video", "audio", "source", "a"].contains(name), let raw = attributes[name == "a" ? "href" : "src"] else { continue }
                guard raw.utf8.count <= 4_096 else { if name != "a" { result.unavailableCount += 1 }; continue }
                let destination = ModelCatalogHTMLAttribute.decode(raw)
                var publishedKind: ModelCatalogMediaKind?
                if name == "video" { publishedKind = .video }
                else if name == "audio" { publishedKind = .audio }
                else if name == "img" { publishedKind = .image }
                else if name == "source" {
                    publishedKind = ModelCatalogHTMLAttribute.mediaKind(attributes["type"] ?? "") ?? mediaContainers.last?.kind
                    if publishedKind == nil, !mediaExtensions.contains(URL(string: destination)?.pathExtension.lowercased() ?? "") {
                        result.unavailableCount += 1
                        continue
                    }
                }
                appendMedia(destination, requiresPreview: name != "a", publishedKind: publishedKind)
            }
        }
        enum Visit {
            case markup(any Markup)
            case link(String)
        }
        var pending: [Visit] = [.markup(Document(parsing: text, options: [.disableSmartOpts]))]
        while let next = pending.popLast() {
            switch next {
            case .link(let destination):
                if ignoredHTMLTag == nil { appendMedia(destination, requiresPreview: false) }
            case .markup(let markup):
                if markup is CodeBlock || markup is InlineCode { continue }
                if let html = markup as? HTMLBlock { scanHTML(html.rawHTML); continue }
                if let html = markup as? InlineHTML { scanHTML(html.rawHTML); continue }
                if ignoredHTMLTag == nil, let image = markup as? Markdown.Image {
                    appendMedia(image.source ?? "", requiresPreview: true)
                    continue
                }
                if let link = markup as? Markdown.Link, let destination = link.destination { pending.append(.link(destination)) }
                pending.append(contentsOf: markup.children.reversed().map { .markup($0) })
            }
        }
        return result
    }

    static func civitaiVersion(data: Data, modelID: String, versionID: String, site: ModelCatalogCivitaiSite) throws -> ModelCatalogVersion {
        guard data.count <= ModelCatalogRequest.maximumJSONBytes,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              scalar(value["modelId"]) == modelID, scalar(value["id"]) == versionID,
              let version = item(["id": modelID, "modelVersions": [value]], provider: .civitai, site: site)?.versions.first else { throw ModelCatalogError.invalidResponse }
        return version
    }

    static func plainDescription(_ raw: String) -> String {
        var value = raw
        for pattern in ["(?is)<(script|style)[^>]*>.*?</\\1>", "<[^>]+>"] {
            value = value.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        for (entity, text) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            value = value.replacingOccurrences(of: entity, with: text)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matchesLocalPermissions(_ item: ModelCatalogItem, filters: ModelCatalogFilters) -> Bool {
        (!filters.requireCreditOptional || item.allowsNoCredit == true)
        && (!filters.requireDerivatives || item.allowsDerivatives == true)
        && (!filters.requireDifferentLicenses || item.allowsDifferentLicenses == true)
        && (filters.commercialUse.isEmpty || item.commercialUses.contains(filters.commercialUse))
    }

    private static func scalar(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func item(_ value: [String: Any], provider: ModelCatalogProvider, site: ModelCatalogCivitaiSite) -> ModelCatalogItem? {
        guard let id = scalar(value["id"] ?? value["modelId"]), ModelCatalogRequest.modelURL(provider: provider, id: id) != nil else { return nil }
        let tags = (value["tags"] as? [String] ?? []).map { $0 }
        let card = value["cardData"] as? [String: Any] ?? [:]
        let creator = value["creator"] as? [String: Any] ?? [:]
        let stats = value["stats"] as? [String: Any] ?? [:]
        var licenses = tags.filter { $0.hasPrefix("license:") }.map { String($0.dropFirst(8)) }
        if let license = card["license"] as? String, !licenses.contains(license) { licenses.append(license) }
        if let names = card["license"] as? [String] { licenses += names.filter { !licenses.contains($0) } }
        var versions: [ModelCatalogVersion]
        if provider == .civitai {
            versions = (value["modelVersions"] as? [[String: Any]] ?? []).compactMap { v in
                guard let versionID = scalar(v["id"]) else { return nil }
                return ModelCatalogVersion(id: versionID, name: v["name"] as? String ?? versionID, revision: nil, baseModel: v["baseModel"] as? String, createdAt: v["createdAt"] as? String, description: plainDescription(v["description"] as? String ?? ""), trainedWords: v["trainedWords"] as? [String] ?? [], files: files(v["files"]), previews: previews(v["images"], provider: provider, site: site), rawMetadata: metadata(v))
            }
        } else {
            var images: [ModelCatalogPreview] = []
            if let raw = card["thumbnail"] as? String, let url = ModelCatalogRequest.previewURL(raw, provider: provider) { images.append(.init(url: url, isAdult: false, author: value["author"] as? String, rawMetadata: metadata(value))) }
            for widget in (value["widgetData"] as? [[String: Any]] ?? []) {
                if let output = widget["output"] as? [String: Any], let raw = output["url"] as? String, let url = ModelCatalogRequest.previewURL(raw, provider: provider) { images.append(.init(url: url, isAdult: false, rawMetadata: metadata(widget))) }
            }
            versions = [.init(id: "main", name: "main", revision: value["sha"] as? String, baseModel: (card["base_model"] as? String), createdAt: value["lastModified"] as? String, description: "", trainedWords: [], files: files(value["siblings"]), previews: images, rawMetadata: metadata(value))]
        }
        let modelRating: ModelCatalogContentRating = provider == .civitai ? .decode(level: value["nsfwLevel"], legacy: value["nsfw"]) : huggingFaceContentRating(value)
        if provider == .huggingFace {
            versions = versions.map { version in
                var previews = version.previews
                previews = previews.map { $0.applyingContentRating(modelRating) }
                return .init(id: version.id, name: version.name, revision: version.revision, baseModel: version.baseModel, createdAt: version.createdAt, description: version.description, trainedWords: version.trainedWords, files: version.files, previews: previews, rawMetadata: version.rawMetadata)
            }
        }
        var versionIDs: Set<String> = []
        versions = versions.filter { versionIDs.insert($0.id).inserted }
        return ModelCatalogItem(id: id, provider: provider, title: value["name"] as? String ?? id, author: value["author"] as? String ?? creator["username"] as? String, kind: value["pipeline_tag"] as? String ?? value["type"] as? String, library: value["library_name"] as? String, description: plainDescription(value["description"] as? String ?? card["description"] as? String ?? ""), tags: tags, licenses: licenses, downloads: value["downloads"] as? Int ?? stats["downloadCount"] as? Int, likes: value["likes"] as? Int ?? stats["favoriteCount"] as? Int, lastModified: value["lastModified"] as? String, isPrivate: value["private"] as? Bool ?? false, gated: (value["gated"] as? Bool).map { $0 ? "Restringido" : "" }.flatMap { $0.isEmpty ? nil : $0 } ?? value["gated"] as? String, isAdult: value["nsfw"] as? Bool ?? false, versions: versions, allowsNoCredit: value["allowNoCredit"] as? Bool, allowsDerivatives: value["allowDerivatives"] as? Bool, allowsDifferentLicenses: value["allowDifferentLicense"] as? Bool ?? value["allowDifferentLicenses"] as? Bool, commercialUses: value["allowCommercialUse"] as? [String] ?? (value["allowCommercialUse"] as? String).map { [$0] } ?? [], availability: value["availability"] as? String ?? value["mode"] as? String, examples: provider == .huggingFace ? widgetExamples(value["widgetData"] ?? card["widget"], modelID: id, revision: value["sha"] as? String ?? "main").map { $0.applyingContentRating(modelRating) } : [], contentRating: modelRating, civitaiSite: site, rawMetadata: metadata(value))
    }

    private static func files(_ raw: Any?) -> [ModelCatalogFile] {
        var names: Set<String> = []
        return (raw as? [[String: Any]] ?? []).compactMap { file in
            guard let name = file["name"] as? String ?? file["rfilename"] as? String, names.insert(name).inserted else { return nil }
            let meta = file["metadata"] as? [String: Any] ?? [:]
            let size = (file["sizeKB"] as? Double ?? file["sizeKb"] as? Double).flatMap { $0 >= 0 && $0 < Double(Int64.max) / 1024 ? Int64($0 * 1024) : nil } ?? file["size"] as? Int64
            return ModelCatalogFile(name: name, sizeBytes: size, sizeIsApproximate: file["sizeKB"] != nil || file["sizeKb"] != nil, format: meta["format"] as? String, scan: file["virusScanResult"] as? String, downloadURL: (file["downloadUrl"] as? String).flatMap(URL.init(string:)), sha256: (file["hashes"] as? [String: String])?["SHA256"] ?? (file["lfs"] as? [String: Any])?["sha256"] as? String, rawMetadata: metadata(file))
        }
    }

    private static func previews(_ raw: Any?, provider: ModelCatalogProvider, maximum: Int = Int.max, site: ModelCatalogCivitaiSite = .standard) -> [ModelCatalogPreview] {
        var urls: Set<URL> = []
        return (raw as? [[String: Any]] ?? []).prefix(maximum).compactMap { image in
            let kind: ModelCatalogMediaKind = image["type"] as? String == "video" ? .video : .image
            guard let text = image["url"] as? String, let url = ModelCatalogRequest.mediaURL(text, provider: provider, kind: kind), urls.insert(url).inserted else { return nil }
            let nsfw = image["nsfw"]
            let level = image["nsfwLevel"] ?? image["browsingLevel"]
            let safeLevel = (level as? Int).map { $0 <= 2 } ?? (level as? String).map { ["none", "pg", "pg13", "pg-13", "soft", "1", "2"].contains($0.lowercased()) }
            let safeLabel = (nsfw as? Bool).map { !$0 } ?? (nsfw as? String).map { ["none", "false", "pg"].contains($0.lowercased()) }
            let adult = safeLevel == false || safeLabel == false || (safeLevel == nil && safeLabel == nil)
            let identifier = scalar(image["id"])
            let source = identifier.flatMap { Int64($0) != nil ? URL(string: "https://\(site.host)/images/\($0)") : nil }
            let thumbnail = image["thumbnail"] as? String ?? (image["thumbnail"] as? [String: Any])?["url"] as? String
            return ModelCatalogPreview(url: url, isAdult: adult, kind: kind, identifier: identifier, fullSizeURL: kind == .image ? ModelCatalogRequest.enlargedPreviewURL(url, provider: provider) : nil, thumbnailURL: thumbnail.flatMap { ModelCatalogRequest.previewURL($0, provider: provider) }, originalURL: URL(string: text), sourceURL: source, title: image["title"] as? String ?? "Muestra\(identifier.map { " \($0)" } ?? "")", author: image["username"] as? String, width: image["width"] as? Int, height: image["height"] as? Int, createdAt: image["createdAt"] as? String, versionIDs: (image["modelVersionIds"] as? [Any] ?? []).compactMap(scalar), parameters: provider == .civitai ? civitaiParameters(image["meta"], imageID: identifier) : parameters(image["meta"]), contentRating: ModelCatalogContentRating.decode(level: level, legacy: nsfw), rawMetadata: metadata(image))
        }
    }

    private static func civitaiParameters(_ raw: Any?, imageID: String?) -> [ModelCatalogParameter] {
        guard let object = raw as? [String: Any] else { return [] }
        if Set(object.keys) == ["id", "meta"] {
            guard let imageID, scalar(object["id"]) == imageID else { return [] }
            return parameters(object["meta"])
        }
        return parameters(object)
    }

    private static func parameters(_ raw: Any?) -> [ModelCatalogParameter] {
        guard let object = raw as? [String: Any] else { return [] }
        return object.keys.sorted().compactMap { key in
            guard !["token", "api_key", "authorization", "url", "src"].contains(key.lowercased()), let value = object[key] else { return nil }
            let text: String
            if let string = value as? String { text = string }
            else if let number = value as? NSNumber { text = number.stringValue }
            else if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), let string = String(data: data, encoding: .utf8) { text = string }
            else { return nil }
            return .init(name: key, value: text)
        }
    }

    private static func widgetExamples(_ raw: Any?, modelID: String, revision: String) -> [ModelCatalogPost] {
        guard let source = ModelCatalogRequest.modelURL(provider: .huggingFace, id: modelID) else { return [] }
        return (raw as? [[String: Any]] ?? []).enumerated().map { index, widget in
            var post = ModelCatalogPost(id: "widget:\(index)", title: widget["example_title"] as? String ?? "Ejemplo \(index + 1)", url: source)
            post.author = widget["author"] as? String ?? widget["username"] as? String
            post.rawMetadata = metadata(widget)
            var fields = widget; fields["output"] = nil; fields["src"] = nil; fields["example_title"] = nil
            post.body = parameters(fields).map { "\($0.name): \($0.value)" }.joined(separator: "\n\n")
            let outputs = (widget["output"] as? [[String: Any]]) ?? (widget["output"] as? [String: Any]).map { [$0] } ?? []
            for output in outputs {
                if let text = output["url"] as? String {
                    let ext = URL(string: text)?.pathExtension.lowercased() ?? ""
                    let kind: ModelCatalogMediaKind = ["mp4", "webm", "mov"].contains(ext) ? .video : ["mp3", "wav", "flac", "ogg", "m4a"].contains(ext) ? .audio : .image
                    if let url = ModelCatalogRequest.widgetAssetURL(text, modelID: modelID, revision: revision, kind: kind) { post.media.append(.init(url: url, isAdult: false, kind: kind, fullSizeURL: kind == .image ? url : nil, sourceURL: source, title: post.title, author: post.author, parameters: parameters(fields), rawMetadata: post.rawMetadata)) }
                    else { post.unavailableMediaCount += 1 }
                } else { post.body += "\n\n" + parameters(output).map { "\($0.name): \($0.value)" }.joined(separator: "\n") }
            }
            if outputs.isEmpty, let output = widget["output"] { post.body += "\n\nSalida: " + String(describing: output) }
            if let text = widget["src"] as? String {
                let ext = URL(string: text)?.pathExtension.lowercased() ?? ""
                let kind: ModelCatalogMediaKind = ["mp3", "wav", "flac", "ogg", "m4a"].contains(ext) ? .audio : ["mp4", "webm", "mov"].contains(ext) ? .video : .image
                if let url = ModelCatalogRequest.widgetAssetURL(text, modelID: modelID, revision: revision, kind: kind) { post.media.append(.init(url: url, isAdult: false, kind: kind, sourceURL: source, title: post.title, author: post.author, parameters: parameters(fields), rawMetadata: post.rawMetadata)) }
                else { post.unavailableMediaCount += 1 }
            }
            return post
        }
    }

    private static func metadata(_ value: Any) -> Data? { try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) }
}

private enum ModelCatalogHTMLAttribute {
    // WHATWG entities.json fijado en la evidencia: estas 106 referencias admiten omitir «;».
    private static let legacyNames: Set<String> = [
        "AElig", "AMP", "Aacute", "Acirc", "Agrave", "Aring", "Atilde", "Auml", "COPY", "Ccedil",
        "ETH", "Eacute", "Ecirc", "Egrave", "Euml", "GT", "Iacute", "Icirc", "Igrave", "Iuml",
        "LT", "Ntilde", "Oacute", "Ocirc", "Ograve", "Oslash", "Otilde", "Ouml", "QUOT", "REG",
        "THORN", "Uacute", "Ucirc", "Ugrave", "Uuml", "Yacute", "aacute", "acirc", "acute", "aelig",
        "agrave", "amp", "aring", "atilde", "auml", "brvbar", "ccedil", "cedil", "cent", "copy",
        "curren", "deg", "divide", "eacute", "ecirc", "egrave", "eth", "euml", "frac12", "frac14",
        "frac34", "gt", "iacute", "icirc", "iexcl", "igrave", "iquest", "iuml", "laquo", "lt",
        "macr", "micro", "middot", "nbsp", "not", "ntilde", "oacute", "ocirc", "ograve", "ordf",
        "ordm", "oslash", "otilde", "ouml", "para", "plusmn", "pound", "quot", "raquo", "reg",
        "sect", "shy", "sup1", "sup2", "sup3", "szlig", "thorn", "times", "uacute", "ucirc",
        "ugrave", "uml", "uuml", "yacute", "yen", "yuml"
    ]
    private static let controlReplacements: [UInt32: UInt32] = [
        0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026,
        0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160,
        0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019,
        0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
        0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153,
        0x9E: 0x017E, 0x9F: 0x0178
    ]

    static func mediaKind(_ raw: String) -> ModelCatalogMediaKind? {
        let whitespace = CharacterSet(charactersIn: "\t\n\r ")
        let input = decode(raw).trimmingCharacters(in: whitespace)
        guard let separator = input.firstIndex(of: "/") else { return nil }
        let type = input[..<separator]
        var subtype = String(input[input.index(after: separator)...].prefix(while: { $0 != ";" }))
        while let last = subtype.unicodeScalars.last, whitespace.contains(last) { subtype.removeLast() }
        func token(_ value: some StringProtocol) -> Bool {
            !value.isEmpty && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || [33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126].contains($0)
            }
        }
        guard token(type), token(subtype) else { return nil }
        switch type.lowercased() {
        case "video": return .video
        case "audio": return .audio
        case "image": return .image
        default: return nil
        }
    }

    static func decode(_ raw: String) -> String {
        let bytes = Array(raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var cursor = 0
        func alphanumeric(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) }
        func named(_ name: String) -> [UInt8]? {
            let source = Array((name + ";").utf8)
            var buffer = cmark_strbuf()
            cmark_strbuf_init(cmark_get_default_mem_allocator(), &buffer, 16)
            defer { cmark_strbuf_free(&buffer) }
            let consumed = source.withUnsafeBufferPointer { houdini_unescape_ent(&buffer, $0.baseAddress, Int32($0.count)) }
            guard consumed == source.count, buffer.size > 0 else { return nil }
            return Array(UnsafeBufferPointer(start: buffer.ptr, count: Int(buffer.size)))
        }
        while cursor < bytes.count {
            guard bytes[cursor] == 38 else {
                if bytes[cursor] == 0 { output.append(contentsOf: [0xEF, 0xBF, 0xBD]) }
                else { output.append(bytes[cursor]) }
                cursor += 1
                continue
            }
            let begin = cursor + 1
            if begin < bytes.count, bytes[begin] == 35 {
                var end = begin + 1
                let hexadecimal = end < bytes.count && [88, 120].contains(bytes[end])
                if hexadecimal { end += 1 }
                let digitStart = end
                var codepoint: UInt32 = 0
                while end < bytes.count {
                    let byte = bytes[end]
                    let digit: UInt32
                    if (48...57).contains(byte) { digit = UInt32(byte - 48) }
                    else if hexadecimal, (65...70).contains(byte) { digit = UInt32(byte - 55) }
                    else if hexadecimal, (97...102).contains(byte) { digit = UInt32(byte - 87) }
                    else { break }
                    codepoint = min(0x110000, codepoint * (hexadecimal ? 16 : 10) + digit)
                    end += 1
                }
                if end > digitStart {
                    if end < bytes.count, bytes[end] == 59 { end += 1 }
                    if codepoint == 0 || codepoint > 0x10FFFF || (0xD800...0xDFFF).contains(codepoint) { codepoint = 0xFFFD }
                    codepoint = controlReplacements[codepoint] ?? codepoint
                    if let scalar = UnicodeScalar(codepoint) { output.append(contentsOf: String(scalar).utf8) }
                    cursor = end
                    continue
                }
            } else {
                var end = begin
                while end < bytes.count, end - begin < 32, alphanumeric(bytes[end]) { end += 1 }
                let name = String(decoding: bytes[begin..<end], as: UTF8.self)
                if end < bytes.count, bytes[end] == 59, let decoded = named(name) {
                    output.append(contentsOf: decoded)
                    cursor = end + 1
                    continue
                }
                while end > begin {
                    let candidate = String(decoding: bytes[begin..<end], as: UTF8.self)
                    if legacyNames.contains(candidate) {
                        if (end == bytes.count || (!alphanumeric(bytes[end]) && bytes[end] != 61)), let decoded = named(candidate) {
                            output.append(contentsOf: decoded)
                            cursor = end
                        }
                        break
                    }
                    end -= 1
                }
                if cursor == end, cursor >= begin { continue }
            }
            output.append(38)
            cursor += 1
        }
        return String(decoding: output, as: UTF8.self)
    }
}
