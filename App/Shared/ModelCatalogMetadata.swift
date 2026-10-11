import Foundation

struct ModelCatalogMetadataDocument: Sendable {
    struct Line: Identifiable, Sendable {
        let id: Int
        let text: String
    }
    let text: String
    let lines: [Line]

    init(data: Data) throws {
        guard data.count <= ModelCatalogRequest.maximumJSONBytes else { throw ModelCatalogError.tooLarge }
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let formatted = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
        guard let text = String(data: formatted, encoding: .utf8) else { throw ModelCatalogError.invalidResponse }
        self.text = text
        lines = text.components(separatedBy: "\n").enumerated().map { .init(id: $0.offset + 1, text: $0.element) }
    }

    func matching(_ query: String) -> [Line] {
        query.isEmpty ? lines : lines.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }
}
