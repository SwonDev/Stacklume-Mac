import Foundation

struct XPostAuthorEvidence: Codable, Equatable, Sendable {
    let handle: String
    let profileURL: String
    let sourceURL: String
    let resourceURL: String
    let context: String
    let chain: [String]
    let checkedAt: Date

    init?(handle: String, profileURL: URL, sourceURL: URL, resourceURL: URL,
          context: String, chain: [URL], checkedAt: Date = Date()) {
        guard XPostAuthorPolicy.profileHandle(profileURL)?.lowercased() == handle.lowercased(),
              XPostAuthorPolicy.normalizedHandle(handle) == handle,
              XPostAuthorPolicy.webURL(sourceURL.absoluteString) != nil,
              XPostAuthorPolicy.webURL(resourceURL.absoluteString) != nil,
              !context.isEmpty, context.utf8.count <= 800, (1...4).contains(chain.count),
              chain.allSatisfy({ XPostAuthorPolicy.webURL($0.absoluteString) != nil }),
              chain.last?.absoluteString == sourceURL.absoluteString else { return nil }
        self.handle = handle
        self.profileURL = "https://x.com/" + handle
        self.sourceURL = sourceURL.absoluteString
        self.resourceURL = resourceURL.absoluteString
        self.context = context
        self.chain = chain.map(\.absoluteString)
        self.checkedAt = checkedAt
    }

    private enum CodingKeys: String, CodingKey { case handle, profileURL, sourceURL, resourceURL, context, chain, checkedAt }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let handle = try values.decode(String.self, forKey: .handle)
        let profile = try values.decode(String.self, forKey: .profileURL)
        let source = try values.decode(String.self, forKey: .sourceURL)
        let resource = try values.decode(String.self, forKey: .resourceURL)
        let context = try values.decode(String.self, forKey: .context)
        let chain = try values.decode([String].self, forKey: .chain)
        let checkedAt = try values.decode(Date.self, forKey: .checkedAt)
        guard let profileURL = URL(string: profile), let sourceURL = URL(string: source),
              let resourceURL = URL(string: resource), chain.count <= 4,
              chain.allSatisfy({ URL(string: $0) != nil }),
              let evidence = Self(handle: handle, profileURL: profileURL, sourceURL: sourceURL,
                                  resourceURL: resourceURL, context: context,
                                  chain: chain.compactMap(URL.init(string:)), checkedAt: checkedAt) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "La evidencia de autor no es válida."))
        }
        self = evidence
    }
}

/// Solo admite cuentas declaradas mediante enlaces públicos; los nombres nunca son arrobas.
enum XPostAuthorPolicy {
    enum DocumentKind: Sendable { case resourceWebsite, repository, creatorProfile }
    struct NextDocument: Sendable { let url: URL; let kind: DocumentKind }

    static func normalizedHandle(_ value: String) -> String? {
        let handle = value.hasPrefix("@") ? String(value.dropFirst()) : value
        guard (1...15).contains(handle.utf8.count),
              handle.unicodeScalars.allSatisfy({ scalar in
                  (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
                      || (48...57).contains(scalar.value) || scalar.value == 95
              }) else { return nil }
        return handle
    }

    static func profileHandle(_ url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              ["x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com", "m.twitter.com"].contains(components.host?.lowercased() ?? ""),
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              url.pathComponents.filter({ $0 != "/" }).count == 1,
              let handle = url.pathComponents.last.flatMap(normalizedHandle) else { return nil }
        let reserved: Set<String> = ["home", "i", "intent", "share", "search", "explore", "notifications", "messages", "settings", "login", "signup", "tos", "privacy", "hashtag", "compose", "about", "download", "jobs"]
        return reserved.contains(handle.lowercased()) ? nil : handle
    }

    static func webURL(_ value: String) -> URL? {
        guard value.utf8.count <= 2_048, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: value),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false, components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }

    static func kind(for url: URL) -> DocumentKind {
        guard url.host()?.lowercased() == "github.com" else { return .resourceWebsite }
        return url.pathComponents.filter({ $0 != "/" }).count == 1 ? .creatorProfile : .repository
    }

    static func evidence(in html: String, documentURL: URL, resourceURL: URL,
                         kind: DocumentKind, chain: [URL]) -> [XPostAuthorEvidence] {
        guard kind != .repository else { return [] }
        let content = documentContent(html, kind: kind)
        var seen = Set<String>()
        return anchors(in: content, baseURL: documentURL).compactMap { anchor in
            guard let handle = profileHandle(anchor.url), isIdentityLink(anchor, kind: kind),
                  seen.insert(handle.lowercased()).inserted else { return nil }
            let context = anchor.label.isEmpty ? anchor.url.absoluteString : anchor.label
            return XPostAuthorEvidence(handle: handle, profileURL: anchor.url, sourceURL: documentURL,
                                       resourceURL: resourceURL, context: String(context.prefix(180)), chain: chain)
        }.prefix(6).map { $0 }
    }

    static func uniqueEvidence(_ evidence: [XPostAuthorEvidence]) -> XPostAuthorEvidence? {
        guard Set(evidence.map { $0.handle.lowercased() }).count == 1 else { return nil }
        return evidence.first
    }

    static func nextDocuments(in html: String, documentURL: URL, kind: DocumentKind) -> [NextDocument] {
        let content = documentContent(html, kind: kind)
        let links = anchors(in: content, baseURL: documentURL)
        let resourceNames = resourceIdentifiers(in: content, documentURL: documentURL)
        let path = documentURL.pathComponents.filter { $0 != "/" }
        var seen = Set<String>()
        return links.compactMap { anchor in
            guard anchor.url.host()?.lowercased() == "github.com", anchor.url.query == nil else { return nil }
            let target = anchor.url.pathComponents.filter { $0 != "/" }
            let nextKind: DocumentKind
            if kind == .repository {
                guard target.count == 1, target.first?.lowercased() == path.first?.lowercased(),
                      anchor.relationships.contains("author") || anchor.relationships.contains("repository-owner") else { return nil }
                nextKind = .creatorProfile
            } else if kind == .resourceWebsite {
                if target.count == 1, anchor.relationships.contains("me") || anchor.relationships.contains("author") || hasAuthorCue(anchor.before) {
                    nextKind = .creatorProfile
                } else if target.count == 2,
                          resourceNames.contains(identifier(target[1])),
                          ["github", "source", "código", "codigo", "repository", "repositorio"].contains(where: { anchor.label.lowercased().contains($0) }) {
                    nextKind = .repository
                } else { return nil }
            } else { return nil }
            guard seen.insert(anchor.url.absoluteString).inserted else { return nil }
            return NextDocument(url: anchor.url, kind: nextKind)
        }.prefix(3).map { $0 }
    }

    private struct Anchor {
        let url: URL
        let label: String
        let before: String
        let relationships: Set<String>
    }

    private static func isIdentityLink(_ anchor: Anchor, kind: DocumentKind) -> Bool {
        if kind == .creatorProfile { return anchor.relationships.contains("me") }
        if anchor.relationships.contains("me") || anchor.relationships.contains("author") { return true }
        let label = anchor.label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if hasAuthorCue(anchor.before) || ["follow me", "sígueme", "sigueme", "autor", "author"].contains(where: label.contains) { return true }
        return kind == .resourceWebsite && ["x", "twitter", "x (twitter)", "follow us", "síguenos", "siguenos"].contains(label)
    }

    private static func hasAuthorCue(_ value: String) -> Bool {
        value.range(of: #"(?:\b(?:author|autor|creator|creador|autora|creadora)\b|(?:created|built|made|developed) by|cread[oa] por|desarrollad[oa] por)\s*[:：]?\s*$"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func hasCreditCue(_ value: String) -> Bool {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
            .range(of: #"\b(?:themes?|templates?|plantillas?|temas?|credits?|creditos|acknowledg(?:e)?ments?|agradecimientos|third[ -]party|terceros|dependenc(?:y|ies|ia|ias)|contributors?|contribuidores?|colaboradores?|sponsors?|patrocinadores?)\b|powered by|built with|hech[oa] con"#,
                   options: .regularExpression) != nil
    }

    private static func isCreditAnnouncement(_ value: String) -> Bool {
        let title = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        return title.range(of: #"\b(?:credits?|creditos|acknowledg(?:e)?ments?|agradecimientos)\b"#, options: .regularExpression) != nil
    }

    private static func resourceIdentifiers(in html: String, documentURL: URL) -> Set<String> {
        var names = [documentURL.host()?.split(separator: ".").first.map(String.init) ?? "",
                     documentURL.lastPathComponent]
        if let regex = try? NSRegularExpression(pattern: #"<(?:title|h1)\b[^>]*>([\s\S]*?)</(?:title|h1)>"#, options: [.caseInsensitive]) {
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).prefix(4) {
                let text = plain(ns.substring(with: match.range(at: 1)))
                names += text.components(separatedBy: CharacterSet.alphanumerics.inverted)
                names.append(text)
            }
        }
        let generic: Set<String> = ["www", "docs", "documentation", "documentacion", "index", "html", "home", "inicio", "github", "source", "code", "codigo"]
        return Set(names.map(identifier).filter { $0.count >= 3 && !generic.contains($0) })
    }

    private static func identifier(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    private static func anchors(in html: String, baseURL: URL) -> [Anchor] {
        guard html.utf8.count <= 1_500_000,
              let regex = try? NSRegularExpression(pattern: #"<a\b([^>]*)>([\s\S]*?)</a>"#, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).prefix(2_000).compactMap { match in
            let attributes = ns.substring(with: match.range(at: 1))
            guard attributes.range(of: #"(?:\bhidden\b|aria-hidden\s*=\s*["']true|display\s*:\s*none|visibility\s*:\s*hidden)"#, options: [.regularExpression, .caseInsensitive]) == nil,
                  let href = attribute("href", in: attributes),
                  let url = URL(string: decode(href), relativeTo: baseURL)?.absoluteURL,
                  webURL(url.absoluteString) != nil else { return nil }
            let body = ns.substring(with: match.range(at: 2))
            let label = attribute("aria-label", in: attributes) ?? plain(body)
            let identity = ["id", "class", "title", "aria-label"].compactMap { attribute($0, in: attributes) }.joined(separator: " ")
            guard !hasCreditCue(plain(body) + " " + label + " " + identity) else { return nil }
            let beforeStart = max(0, match.range.location - 150)
            let before = plain(ns.substring(with: NSRange(location: beforeStart, length: match.range.location - beforeStart)))
            var relationships = Set((attribute("rel", in: attributes) ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
            if attribute("data-component", in: attributes) == "Breadcrumbs.Item" { relationships.insert("repository-owner") }
            return Anchor(url: url, label: label, before: before, relationships: relationships)
        }
    }

    private static func documentContent(_ html: String, kind: DocumentKind) -> String {
        guard html.utf8.count <= 1_500_000 else { return "" }
        // TidyHTML aplana las etiquetas HTML5; el marcador conserva sus límites en el árbol.
        let prepared = clean(html)
            .replacingOccurrences(of: #"<(section|header|footer|main|aside|article|nav)(\s[^>]*|)>"#, with: #"<div data-stacklume-element="$1"$2>"#, options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"</(?:section|header|footer|main|aside|article|nav)\s*>"#, with: "</div>", options: [.regularExpression, .caseInsensitive])
        guard let document = try? XMLDocument(xmlString: prepared, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let nodes = descendantElements(document) else { return "" }
        var excluded: [XMLNode] = []
        var declaredCreditMarkers = Set<ObjectIdentifier>()
        for element in nodes {
            let tag = elementTag(element)
            if kind == .creatorProfile && tag == "article" {
                excluded.append(element)
                continue
            }
            if let link = enclosingLink(element) {
                guard link === element, !isNavigationControlLabel(element) else { continue }
                let descriptions = [element.stringValue ?? ""]
                    + ["aria-label", "title", "id", "class"].compactMap { element.attribute(forName: $0)?.stringValue }
                if descriptions.contains(where: isCreditAnnouncement) {
                    declaredCreditMarkers.insert(ObjectIdentifier(creditScopeMarker(element)))
                }
                continue
            }
            guard !isNavigationControlLabel(element) else { continue }
            let identity = ["id", "class", "aria-label"].compactMap { element.attribute(forName: $0)?.stringValue }.joined(separator: " ")
            if headingLevel(element) != nil {
                if hasCreditCue(identity) { declaredCreditMarkers.insert(ObjectIdentifier(element)) }
                continue
            }
            let text = (element.children ?? []).filter { $0.kind == .text }.compactMap(\.stringValue).joined(separator: " ")
            guard hasCreditCue(identity) || hasCreditCue(text) else { continue }
            guard let children = descendantElements(element) else { return "" }
            let headings = children.filter { headingLevel($0) != nil }
            let hasContentLink = children.contains { node in
                guard node.name?.lowercased() == "a" else { return false }
                var ancestor = node.parent
                while let parent = ancestor, parent !== element {
                    if headingLevel(parent) != nil { return false }
                    ancestor = parent.parent
                }
                return true
            }
            if !headings.isEmpty && !hasContentLink {
                declaredCreditMarkers.formUnion(headings.map(ObjectIdentifier.init))
            } else if hasCreditCue(identity) && hasContentLink {
                excluded.append(element)
            } else {
                declaredCreditMarkers.insert(ObjectIdentifier(creditScopeMarker(element)))
            }
        }
        excluded.forEach { $0.detach() }
        guard let remaining = descendantElements(document) else { return "" }
        excluded = []
        for marker in remaining {
            guard !isNavigationControlLabel(marker) else { continue }
            let level = headingLevel(marker)
            guard (level != nil && hasCreditCue(marker.stringValue ?? ""))
                    || declaredCreditMarkers.contains(ObjectIdentifier(marker)) else { continue }
            excluded += creditMarkerNodes(marker, level: level)
        }
        excluded.forEach { $0.detach() }
        return document.xmlString
    }

    private static func creditScopeMarker(_ element: XMLElement) -> XMLNode {
        var ancestor = element.parent
        while let parent = ancestor {
            if headingLevel(parent) != nil { return parent }
            ancestor = parent.parent
        }
        return element
    }

    private static func elementTag(_ element: XMLElement) -> String {
        (element.attribute(forName: "data-stacklume-element")?.stringValue ?? element.name ?? "").lowercased()
    }

    private static func isNavigationControlLabel(_ element: XMLElement) -> Bool {
        var ancestor: XMLNode? = element
        while let node = ancestor {
            if let element = node as? XMLElement {
                let tag = elementTag(element)
                let role = element.attribute(forName: "role")?.stringValue?.lowercased()
                if ["nav", "button", "select", "option", "menu"].contains(tag)
                    || ["navigation", "banner", "button", "tab", "menuitem"].contains(role ?? "") { return true }
            }
            ancestor = node.parent
        }
        return false
    }

    private static func enclosingLink(_ element: XMLElement) -> XMLElement? {
        var ancestor: XMLNode? = element
        while let node = ancestor {
            if let element = node as? XMLElement,
               elementTag(element) == "a" || element.attribute(forName: "role")?.stringValue?.lowercased() == "link" {
                return element
            }
            ancestor = node.parent
        }
        return nil
    }

    private static func descendantElements(_ root: XMLNode) -> [XMLElement]? {
        var pending = Array((root.children ?? []).reversed())
        var elements: [XMLElement] = []
        var visited = 0
        while let node = pending.popLast() {
            visited += 1
            guard visited <= 40_000 else { return nil }
            if let element = node as? XMLElement {
                elements.append(element)
                guard elements.count <= 20_000 else { return nil }
            }
            pending.append(contentsOf: (node.children ?? []).reversed())
        }
        return elements
    }

    private static func headingLevel(_ node: XMLNode) -> Int? {
        guard let name = node.name?.lowercased(), name.count == 2, name.first == "h",
              let level = Int(name.dropFirst()), (1...6).contains(level) else { return nil }
        return level
    }

    private static func creditMarkerNodes(_ marker: XMLElement, level: Int?) -> [XMLNode] {
        var scope: XMLNode = marker
        while let parent = scope.parent { scope = parent }
        guard let nodes = descendantElements(scope),
              let start = nodes.firstIndex(where: { $0 === marker }) else { return [scope] }
        let end = nodes.indices.dropFirst(start + 1).first { index in
            if let level, let nextLevel = headingLevel(nodes[index]) { return nextLevel <= level }
            return false
        }
        return [marker] + nodes[(start + 1)..<(end ?? nodes.endIndex)].filter { $0.name?.lowercased() == "a" }
    }

    private static func clean(_ html: String) -> String {
        let publicContent = String(html.prefix(1_500_000)).replacingOccurrences(of: #"<!--[\s\S]*?-->|<script\b[\s\S]*?</script>|<style\b[\s\S]*?</style>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        return publicContent.replacingOccurrences(of: #"<([a-z][a-z0-9:-]*)\b(?=[^>]*(?:\shidden[\s=>]|aria-hidden\s*=\s*["']true["']|display\s*:\s*none|visibility\s*:\s*hidden))[^>]*>[\s\S]*?</\1>"#, with: " ", options: [.regularExpression, .caseInsensitive])
    }
    private static func plain(_ html: String) -> String {
        decode(html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?:^|\\s)" + name + #"\s*=\s*["']([^"']*)["']"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[range])
    }
    private static func decode(_ value: String) -> String {
        var result = value
        for (entity, text) in ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&apos;": "'", "&nbsp;": " "] {
            result = result.replacingOccurrences(of: entity, with: text)
        }
        return result
    }
}
