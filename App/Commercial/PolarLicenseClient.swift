import Foundation

enum PolarLicenseClientError: LocalizedError, Sendable {
    case invalidConfiguration
    case rejected
    case activationLimitReached
    case temporarilyUnavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Esta copia de Stacklume no tiene completa su configuración comercial. Contacta con soporte."
        case .rejected:
            "La licencia no es válida, ha caducado o fue revocada. Comprueba la clave e inténtalo de nuevo."
        case .activationLimitReached:
            "La licencia ya alcanzó su límite de dispositivos. Libera una activación desde tu cuenta y vuelve a intentarlo."
        case .temporarilyUnavailable:
            "No se pudo contactar con el servicio de licencias. Comprueba tu conexión e inténtalo de nuevo."
        case .invalidResponse:
            "El servicio de licencias devolvió una respuesta inesperada. Inténtalo de nuevo más tarde."
        }
    }

    var isAuthoritativeRejection: Bool {
        switch self {
        case .rejected:
            true
        case .activationLimitReached, .invalidConfiguration, .temporarilyUnavailable, .invalidResponse:
            false
        }
    }
}

actor PolarLicenseClient {
    private let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder.polarLicenseDecoder()

    init(
        baseURL: URL = URL(string: "https://api.polar.sh/v1/customer-portal/license-keys")!,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func activate(
        key: String,
        configuration: CommercialLicenseConfiguration,
        installationLabel: String
    ) async throws -> CommercialLicenseReceipt {
        try validateConfiguration(configuration)
        let response: PolarLicenseActivationResponse = try await post(
            endpoint: "activate",
            body: ActivationRequest(
                key: key,
                organizationID: configuration.organizationID,
                label: installationLabel,
                meta: ["platform": "macOS", "architecture": "arm64"]
            )
        )
        return try makeReceipt(
            record: response.licenseKey,
            key: key,
            activationID: response.id,
            expectedBenefitID: configuration.benefitID
        )
    }

    func validate(
        receipt: CommercialLicenseReceipt,
        configuration: CommercialLicenseConfiguration
    ) async throws -> CommercialLicenseReceipt {
        try validateConfiguration(configuration)
        let record: PolarLicenseRecord = try await post(
            endpoint: "validate",
            body: ValidationRequest(
                key: receipt.key,
                organizationID: configuration.organizationID,
                activationID: receipt.activationID,
                benefitID: configuration.benefitID
            )
        )
        return try makeReceipt(
            record: record,
            key: receipt.key,
            activationID: receipt.activationID,
            expectedBenefitID: configuration.benefitID
        )
    }

    func deactivate(
        receipt: CommercialLicenseReceipt,
        configuration: CommercialLicenseConfiguration
    ) async throws {
        try validateConfiguration(configuration)
        let _: EmptyResponse = try await post(
            endpoint: "deactivate",
            body: DeactivationRequest(
                key: receipt.key,
                organizationID: configuration.organizationID,
                activationID: receipt.activationID
            ),
            acceptsEmptyResponse: true
        )
    }

    private func validateConfiguration(_ configuration: CommercialLicenseConfiguration) throws {
        guard configuration.isCommercialBuild, configuration.isComplete else {
            throw PolarLicenseClientError.invalidConfiguration
        }
    }

    private func makeReceipt(
        record: PolarLicenseRecord,
        key: String,
        activationID: String,
        expectedBenefitID: String
    ) throws -> CommercialLicenseReceipt {
        guard record.benefitID.caseInsensitiveCompare(expectedBenefitID) == .orderedSame,
              record.status == .granted,
              record.expiresAt.map({ $0 > Date() }) ?? true else {
            throw PolarLicenseClientError.rejected
        }
        return CommercialLicenseReceipt(
            key: key,
            activationID: activationID,
            licenseID: record.id,
            benefitID: record.benefitID,
            status: record.status,
            validatedAt: Date(),
            expiresAt: record.expiresAt
        )
    }

    private func post<Response: Decodable, Body: Encodable>(
        endpoint: String,
        body: Body,
        acceptsEmptyResponse: Bool = false
    ) async throws -> Response {
        let url = baseURL.appending(path: endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PolarLicenseClientError.temporarilyUnavailable
        }
        guard let http = response as? HTTPURLResponse else {
            throw PolarLicenseClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if endpoint == "activate", http.statusCode == 422 {
                throw PolarLicenseClientError.activationLimitReached
            }
            if http.statusCode == 404 {
                throw PolarLicenseClientError.rejected
            }
            if [400, 401, 403, 422].contains(http.statusCode) {
                throw PolarLicenseClientError.invalidResponse
            }
            throw PolarLicenseClientError.temporarilyUnavailable
        }
        if acceptsEmptyResponse, data.isEmpty, let empty = EmptyResponse() as? Response {
            return empty
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw PolarLicenseClientError.invalidResponse
        }
    }
}

private struct ActivationRequest: Encodable {
    let key: String
    let organizationID: String
    let label: String
    let meta: [String: String]

    enum CodingKeys: String, CodingKey {
        case key
        case organizationID = "organization_id"
        case label
        case meta
    }
}

private struct ValidationRequest: Encodable {
    let key: String
    let organizationID: String
    let activationID: String
    let benefitID: String

    enum CodingKeys: String, CodingKey {
        case key
        case organizationID = "organization_id"
        case activationID = "activation_id"
        case benefitID = "benefit_id"
    }
}

private struct DeactivationRequest: Encodable {
    let key: String
    let organizationID: String
    let activationID: String

    enum CodingKeys: String, CodingKey {
        case key
        case organizationID = "organization_id"
        case activationID = "activation_id"
    }
}

private struct EmptyResponse: Decodable {
    init() {}
}
