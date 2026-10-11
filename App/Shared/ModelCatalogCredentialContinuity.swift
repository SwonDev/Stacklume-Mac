import Foundation

enum ModelCatalogCredentialContinuityPolicy {
    static let service = "com.swondev.stacklume.model-catalog"
    private struct Record: Codable {
        let version: Int
        let service: String
        let provider: ModelCatalogProvider
        let requirement: Data
    }

    static func record(provider: ModelCatalogProvider, requirement: Data?) -> Data? {
        guard let requirement, !requirement.isEmpty, requirement.count <= 65_536 else { return nil }
        return try? JSONEncoder().encode(Record(version: 1, service: service, provider: provider, requirement: requirement))
    }

    static func allowsBackgroundRead(provider: ModelCatalogProvider, record: Data?, requirement: Data?) -> Bool {
        guard let requirement, !requirement.isEmpty, requirement.count <= 65_536,
              let record, record.count <= 90_000,
              let value = try? JSONDecoder().decode(Record.self, from: record),
              value.version == 1, value.service == service, value.provider == provider else { return false }
        return value.requirement == requirement
    }
}

struct ModelCatalogCredentialContinuity: Sendable {
    let allowsBackgroundRead: @Sendable (ModelCatalogProvider) -> Bool
    let recordAuthorizedRead: @Sendable (ModelCatalogProvider) -> Void
    let invalidate: @Sendable (ModelCatalogProvider) -> Void

    // Los lectores inyectados no acceden al Llavero real ni a su autorización.
    static let injectedReader = Self(allowsBackgroundRead: { _ in true }, recordAuthorizedRead: { _ in }, invalidate: { _ in })
}
