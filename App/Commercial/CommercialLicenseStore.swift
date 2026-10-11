import Foundation
import Security

enum CommercialLicenseStoreError: LocalizedError {
    case keychain(OSStatus)
    case invalidStoredReceipt

    var errorDescription: String? {
        switch self {
        case .keychain:
            "No se pudo acceder de forma segura a la licencia en el Llavero."
        case .invalidStoredReceipt:
            "La licencia guardada no se puede leer. Vuelve a activarla."
        }
    }
}

/// Guarda la clave y su recibo únicamente en el Llavero de macOS. La biblioteca SwiftData
/// y los stores laterales de Stacklume quedan completamente independientes de la licencia.
struct CommercialLicenseStore: Sendable {
    private let service = "com.swondev.stacklume.commercial-license"
    private let account = "polar-license"

    func load() throws -> CommercialLicenseReceipt? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CommercialLicenseStoreError.keychain(status) }
        guard let data = result as? Data,
              let receipt = try? JSONDecoder().decode(CommercialLicenseReceipt.self, from: data) else {
            throw CommercialLicenseStoreError.invalidStoredReceipt
        }
        return receipt
    }

    func save(_ receipt: CommercialLicenseReceipt) throws {
        let data = try JSONEncoder().encode(receipt)
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            // La activación pertenece a este Mac: no debe migrar con una copia del
            // Llavero a otro equipo y consumir una activación fantasma.
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CommercialLicenseStoreError.keychain(updateStatus)
        }

        var insertion = identity
        attributes.forEach { insertion[$0.key] = $0.value }
        let insertStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw CommercialLicenseStoreError.keychain(insertStatus)
        }
    }

    func delete() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CommercialLicenseStoreError.keychain(status)
        }
    }
}
