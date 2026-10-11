import Foundation

struct CommercialLicenseConfiguration: Sendable, Equatable {
    let isCommercialBuild: Bool
    let organizationID: String
    let benefitID: String

    init(isCommercialBuild: Bool, organizationID: String, benefitID: String) {
        self.isCommercialBuild = isCommercialBuild
        self.organizationID = organizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.benefitID = benefitID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Los recibos antiguos conservan sus tipos y almacenamiento. La edición
    // gratuita ignora cualquier bandera comercial heredada del bundle.
    init(bundle: Bundle = .main) {
        self.init(isCommercialBuild: false, organizationID: "", benefitID: "")
    }

    static let current = CommercialLicenseConfiguration()

    var isComplete: Bool {
        guard isCommercialBuild else { return true }
        return UUID(uuidString: organizationID) != nil && UUID(uuidString: benefitID) != nil
    }

    static func boolValue(_ value: Any?) -> Bool {
        switch value {
        case let value as Bool:
            value
        case let value as NSNumber:
            value.boolValue
        case let value as String:
            ["1", "true", "yes"].contains(value.lowercased())
        default:
            false
        }
    }
}

enum CommercialLicenseInput {
    static func normalizedKey(_ rawValue: String) -> String {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isPlausibleKey(_ value: String) -> Bool {
        let normalized = normalizedKey(value)
        return (8...256).contains(normalized.utf8.count)
            && !normalized.contains(where: { $0.isWhitespace })
    }
}

enum CommercialLicenseStatus: String, Codable, Sendable {
    case granted
    case revoked
    case disabled
}

/// Recibo mínimo guardado en Keychain. La licencia se revalida periódicamente, pero una
/// caída temporal de red no debe expulsar a un comprador legítimo de su propia biblioteca.
struct CommercialLicenseReceipt: Codable, Sendable, Equatable {
    static let offlineGraceInterval: TimeInterval = 30 * 24 * 60 * 60

    let key: String
    let activationID: String
    let licenseID: String
    let benefitID: String
    let status: CommercialLicenseStatus
    let validatedAt: Date
    let expiresAt: Date?

    func grantsAccess(
        at date: Date = Date(),
        offlineGraceInterval: TimeInterval = Self.offlineGraceInterval
    ) -> Bool {
        guard status == .granted else { return false }
        if let expiresAt, expiresAt <= date { return false }
        return validatedAt.addingTimeInterval(offlineGraceInterval) > date
    }
}

struct PolarLicenseRecord: Decodable, Sendable, Equatable {
    let id: String
    let benefitID: String
    let status: CommercialLicenseStatus
    let expiresAt: Date?
    let activation: PolarLicenseActivation?

    enum CodingKeys: String, CodingKey {
        case id
        case benefitID = "benefit_id"
        case status
        case expiresAt = "expires_at"
        case activation
    }
}

struct PolarLicenseActivation: Decodable, Sendable, Equatable {
    let id: String
}

struct PolarLicenseActivationResponse: Decodable, Sendable, Equatable {
    let id: String
    let licenseKey: PolarLicenseRecord

    enum CodingKeys: String, CodingKey {
        case id
        case licenseKey = "license_key"
    }
}

extension JSONDecoder {
    static func polarLicenseDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Fecha ISO 8601 de Polar no válida."
            )
        }
        return decoder
    }
}
