import Foundation
import Security

struct ModelCatalogCredentials: Sendable {
    private let service = ModelCatalogCredentialContinuityPolicy.service

    private static let requirement: Data? = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var data: CFData?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyData(requirement, [], &data) == errSecSuccess, let data else { return nil }
        return data as Data
    }()

    private static func receiptKey(_ provider: ModelCatalogProvider) -> String {
        "stacklume.modelCatalog.authorizedReadIdentity.\(provider.rawValue)"
    }

    static let continuity = ModelCatalogCredentialContinuity(
        allowsBackgroundRead: { provider in
            ModelCatalogCredentialContinuityPolicy.allowsBackgroundRead(
                provider: provider, record: UserDefaults.standard.data(forKey: receiptKey(provider)), requirement: requirement)
        },
        recordAuthorizedRead: { provider in
            guard let data = ModelCatalogCredentialContinuityPolicy.record(provider: provider, requirement: requirement) else { return }
            UserDefaults.standard.set(data, forKey: receiptKey(provider))
        },
        invalidate: { provider in UserDefaults.standard.removeObject(forKey: receiptKey(provider)) }
    )

    private func identity(_ provider: ModelCatalogProvider) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: provider.rawValue]
    }

    func read(_ provider: ModelCatalogProvider, allowingInteraction: Bool = false) -> ModelCatalogCredentialRead {
        guard allowingInteraction || Self.continuity.allowsBackgroundRead(provider) else {
            return .init(status: .accessUnverified, token: nil)
        }
        var query = identity(provider)
        query[kSecReturnData] = true; query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI] = allowingInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return ModelCatalogCredentialRead.keychain(status: status, data: result as? Data)
    }

    func load(_ provider: ModelCatalogProvider) throws -> String? {
        let value = read(provider)
        switch value.status {
        case .available: return value.token
        case .absent: return nil
        case .authorizationRequired: throw ModelCatalogError.keychainAccessRequired
        case .checking, .unavailable, .accountUnavailable, .accessUnverified: throw ModelCatalogError.keychain
        }
    }

    func save(_ token: String, provider: ModelCatalogProvider) throws {
        guard ModelCatalogRequest.validToken(token) else { throw ModelCatalogError.invalidToken }
        let query = identity(provider)
        let values: [CFString: Any] = [kSecValueData: Data(token.utf8), kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw ModelCatalogError.keychain }
        var insertion = query
        values.forEach { insertion[$0.key] = $0.value }
        guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else { throw ModelCatalogError.keychain }
    }

    func delete(_ provider: ModelCatalogProvider) throws {
        let status = SecItemDelete(identity(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ModelCatalogError.keychain }
    }
}
