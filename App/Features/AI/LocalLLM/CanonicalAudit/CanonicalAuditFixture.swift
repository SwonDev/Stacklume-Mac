import Foundation
import CryptoKit

struct CanonicalPreparedAudit: Sendable {
    let batch: XPostCopyBatch
    let request: XPostCopyPolicy.Prompt
    let sourceSHA256: String
    let candidatesSHA256: String
    let contextSHA256: String
    let systemSHA256: String
    let userSHA256: String
}
enum CanonicalAuditFixture {
    enum FixtureError: Error { case source, candidates, context }
    static let sourceSHA256 = "22c4d517c3915e2999cdd2c82a3c55f352426164a360bd7bfead38ca53485761"
    static let candidatesSHA256 = "91a8a1d295eeca3c98aefde4a10b5c0cdfd2e1122375ae1d04197b038fa391a9"
    static let contextSHA256 = "6cf37fe6b4bd72bc73db07313cfa58c962ad06da22bf9973c99a7537ceacb77c"
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func prepare(sourceData: Data, candidatesData: Data) throws -> CanonicalPreparedAudit {
        guard sourceData.count == 1_657, hash(sourceData) == sourceSHA256,
              let source = String(data: sourceData, encoding: .utf8), source.count == 1_655 else { throw FixtureError.source }
        guard candidatesData.count == 819, hash(candidatesData) == candidatesSHA256,
              let candidates = String(data: candidatesData, encoding: .utf8) else { throw FixtureError.candidates }
        let context = try XPostCopyPolicy.generationContext(source: source, tone: .calm)
        guard context.fragments.map(\.id) == ["F2", "F3", "F4", "F5"],
              hash(Data(context.literalText.utf8)) == contextSHA256,
              context.literalText.count == 1_345, !context.sourceWasTruncated else { throw FixtureError.context }
        let ranges = [NSRange(location: 313, length: 299), NSRange(location: 613, length: 387),
                      NSRange(location: 1_001, length: 319), NSRange(location: 1_321, length: 334)]
        let literal = source as NSString
        for (fragment, range) in zip(context.fragments, ranges) {
            guard Data(literal.substring(with: range).utf8) == Data(fragment.text.utf8) else { throw FixtureError.context }
        }
        let batch = try XPostGroupedCopyPolicy.extract(candidates, tones: XPostTone.allCases, context: context)
        let request = XPostSemanticAuditPolicy.prompt(batch: batch, language: "es")
        guard hash(Data(request.system.utf8)) == "e2b58be0e6ed1a6d6e8aee4528d4a0c67d62daab0cdecd36e0ae753204e8a53e",
              hash(Data(request.user.utf8)) == "3e5a07efedb668cdd39d62763b10dae5476883794d0cd029934ad5747218e911" else { throw FixtureError.context }
        return .init(batch: batch, request: request, sourceSHA256: sourceSHA256,
            candidatesSHA256: candidatesSHA256, contextSHA256: contextSHA256,
            systemSHA256: hash(Data(request.system.utf8)), userSHA256: hash(Data(request.user.utf8)))
    }
}
