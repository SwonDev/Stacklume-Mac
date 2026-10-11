import Foundation
import Testing

@Suite("Licencia comercial")
struct CommercialLicenseModelsTests {
    @Test("La build comercial exige identificadores UUID completos")
    func validatesConfiguration() {
        let complete = CommercialLicenseConfiguration(
            isCommercialBuild: true,
            organizationID: "2CB78B74-4715-4E41-A354-62AFB87A8DDA",
            benefitID: "95C27E97-AEC2-44BB-BB8C-4FB36F07B1F6"
        )
        let incomplete = CommercialLicenseConfiguration(
            isCommercialBuild: true,
            organizationID: "",
            benefitID: "no-es-un-uuid"
        )
        #expect(complete.isComplete)
        #expect(!incomplete.isComplete)
        #expect(
            CommercialLicenseConfiguration(
                isCommercialBuild: false,
                organizationID: "",
                benefitID: ""
            ).isComplete
        )
    }

    @Test("Interpreta los valores de build sin depender de mayúsculas")
    func parsesBuildFlag() {
        #expect(CommercialLicenseConfiguration.boolValue("YES"))
        #expect(CommercialLicenseConfiguration.boolValue("true"))
        #expect(CommercialLicenseConfiguration.boolValue(1))
        #expect(!CommercialLicenseConfiguration.boolValue("NO"))
        #expect(!CommercialLicenseConfiguration.boolValue(nil))
    }

    @Test("Normaliza la clave y rechaza entradas truncadas o con espacios internos")
    func validatesInput() {
        #expect(
            CommercialLicenseInput.normalizedKey("  STACKLUME_12345678\n")
                == "STACKLUME_12345678"
        )
        #expect(CommercialLicenseInput.isPlausibleKey("STACKLUME_12345678"))
        #expect(!CommercialLicenseInput.isPlausibleKey("corta"))
        #expect(!CommercialLicenseInput.isPlausibleKey("STACK LUME_12345678"))
    }

    @Test("El recibo admite treinta días sin red, pero nunca una licencia caducada")
    func enforcesOfflineGraceAndExpiry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let valid = CommercialLicenseReceipt(
            key: "STACKLUME_12345678",
            activationID: UUID().uuidString,
            licenseID: UUID().uuidString,
            benefitID: UUID().uuidString,
            status: .granted,
            validatedAt: now.addingTimeInterval(-29 * 24 * 60 * 60),
            expiresAt: nil
        )
        let stale = CommercialLicenseReceipt(
            key: valid.key,
            activationID: valid.activationID,
            licenseID: valid.licenseID,
            benefitID: valid.benefitID,
            status: .granted,
            validatedAt: now.addingTimeInterval(-31 * 24 * 60 * 60),
            expiresAt: nil
        )
        let expired = CommercialLicenseReceipt(
            key: valid.key,
            activationID: valid.activationID,
            licenseID: valid.licenseID,
            benefitID: valid.benefitID,
            status: .granted,
            validatedAt: now,
            expiresAt: now.addingTimeInterval(-1)
        )
        #expect(valid.grantsAccess(at: now))
        #expect(!stale.grantsAccess(at: now))
        #expect(!expired.grantsAccess(at: now))
    }

    @Test("Decodifica las respuestas vigentes de activación de Polar")
    func decodesPolarActivation() throws {
        let data = Data(
            """
            {
              "id": "D0B46140-537E-4EB8-9D80-0F93D22B4F70",
              "license_key": {
                "id": "588672AB-1A54-4B6D-A56D-EBEF8C2F9B16",
                "benefit_id": "95C27E97-AEC2-44BB-BB8C-4FB36F07B1F6",
                "status": "granted",
                "expires_at": "2027-07-29T10:11:12.123Z",
                "activation": null
              }
            }
            """.utf8
        )
        let response = try JSONDecoder.polarLicenseDecoder().decode(
            PolarLicenseActivationResponse.self,
            from: data
        )
        #expect(response.licenseKey.status == .granted)
        #expect(response.licenseKey.benefitID == "95C27E97-AEC2-44BB-BB8C-4FB36F07B1F6")
        #expect(response.licenseKey.expiresAt != nil)
    }

    @Test("Solo una revocación confirmada elimina el recibo local")
    func preservesReceiptForOperationalErrors() {
        #expect(PolarLicenseClientError.rejected.isAuthoritativeRejection)
        #expect(!PolarLicenseClientError.activationLimitReached.isAuthoritativeRejection)
        #expect(!PolarLicenseClientError.invalidConfiguration.isAuthoritativeRejection)
        #expect(!PolarLicenseClientError.temporarilyUnavailable.isAuthoritativeRejection)
        #expect(!PolarLicenseClientError.invalidResponse.isAuthoritativeRejection)
    }
}
