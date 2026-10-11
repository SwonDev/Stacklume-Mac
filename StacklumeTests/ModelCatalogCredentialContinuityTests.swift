import Foundation
import Testing

struct ModelCatalogCredentialContinuityTests {
    @Test func identityMatchesOnlyItsProviderAndService() throws {
        let identity = Data("identidad-estable-sintética".utf8)
        let record = try #require(ModelCatalogCredentialContinuityPolicy.record(provider: .huggingFace, requirement: identity))
        #expect(ModelCatalogCredentialContinuityPolicy.allowsBackgroundRead(provider: .huggingFace, record: record, requirement: identity))
        #expect(!ModelCatalogCredentialContinuityPolicy.allowsBackgroundRead(provider: .civitai, record: record, requirement: identity))
        #expect(!ModelCatalogCredentialContinuityPolicy.allowsBackgroundRead(provider: .huggingFace, record: record, requirement: Data("otra-identidad".utf8)))
        var document = try #require(try JSONSerialization.jsonObject(with: record) as? [String: Any])
        document["service"] = "otro.servicio"
        #expect(!ModelCatalogCredentialContinuityPolicy.allowsBackgroundRead(provider: .huggingFace, record: try JSONSerialization.data(withJSONObject: document), requirement: identity))
    }

    @Test func missingInvalidOrUnknownIdentityNeverPermitsBackgroundDataRead() {
        let identity = Data("identidad-estable-sintética".utf8)
        let valid = ModelCatalogCredentialContinuityPolicy.record(provider: .huggingFace, requirement: identity)
        for record in [nil, Data(), Data("corrupto".utf8), Data(repeating: 1, count: 90_001)] {
            #expect(!ModelCatalogCredentialContinuityPolicy.allowsBackgroundRead(provider: .huggingFace, record: record, requirement: identity))
        }
        for requirement in [nil, Data(), Data(repeating: 1, count: 65_537)] {
            #expect(!ModelCatalogCredentialContinuityPolicy.allowsBackgroundRead(provider: .huggingFace, record: valid, requirement: requirement))
            #expect(ModelCatalogCredentialContinuityPolicy.record(provider: .huggingFace, requirement: requirement) == nil)
        }
    }

    @Test func futureStableBuildKeepsTheSameIdentityAndRecordContainsNoCredential() throws {
        let buildA = Data("requisito-certificado-identificador".utf8)
        let buildB = Data("requisito-certificado-identificador".utf8)
        let record = try #require(ModelCatalogCredentialContinuityPolicy.record(provider: .civitai, requirement: buildA))
        #expect(ModelCatalogCredentialContinuityPolicy.allowsBackgroundRead(provider: .civitai, record: record, requirement: buildB))
        let document = try #require(try JSONSerialization.jsonObject(with: record) as? [String: Any])
        #expect(Set(document.keys) == ["version", "service", "provider", "requirement"])
    }
}
