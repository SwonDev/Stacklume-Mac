import Foundation

enum XPostAuthorResolution: Sendable {
    case verified(XPostAuthorEvidence)
    case ambiguous
    case notFound
    case unavailable
}

/// Consulta hasta tres documentos públicos enlazados; comparte las guardas y cotas de red.
enum XPostAuthorResolver {
    static func resolve(_ resourceURL: URL) async throws -> XPostAuthorResolution {
        var current = XPostAuthorPolicy.NextDocument(url: resourceURL, kind: XPostAuthorPolicy.kind(for: resourceURL))
        var visited = Set<String>(), chain = [resourceURL], evidence: [XPostAuthorEvidence] = []
        for _ in 0..<3 {
            try Task.checkCancellation()
            guard visited.insert(current.url.absoluteString).inserted else { break }
            var request = URLRequest(url: current.url)
            request.timeoutInterval = 12
            request.setValue("Stacklume", forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            let result: ExternalHTTPResponse
            do {
                result = try await ExternalHTTPClient.shared.data(for: request, maximumBytes: 1_500_000,
                                                                 allowedMIMEPrefixes: ["text/html", "application/xhtml+xml"])
            } catch is CancellationError { throw CancellationError() }
            catch { return .unavailable }
            try Task.checkCancellation()
            guard let documentURL = result.response.url,
                  let html = String(data: result.data, encoding: .utf8) ?? String(data: result.data, encoding: .isoLatin1) else { return .unavailable }
            if chain.last != documentURL { chain.append(documentURL) }
            let kind = documentURL.host()?.lowercased() == "github.com" ? XPostAuthorPolicy.kind(for: documentURL) : current.kind
            evidence += XPostAuthorPolicy.evidence(in: html, documentURL: documentURL, resourceURL: resourceURL,
                                                   kind: kind, chain: chain)
            if Set(evidence.map { $0.handle.lowercased() }).count > 1 { return .ambiguous }
            let next = XPostAuthorPolicy.nextDocuments(in: html, documentURL: documentURL, kind: kind)
            guard next.count <= 1 else {
                return XPostAuthorPolicy.uniqueEvidence(evidence).map(XPostAuthorResolution.verified) ?? .ambiguous
            }
            guard let target = next.first else { break }
            current = target
        }
        return XPostAuthorPolicy.uniqueEvidence(evidence).map(XPostAuthorResolution.verified) ?? .notFound
    }
}
