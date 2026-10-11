import Foundation

/// Un fichero por enlace: no carga todos los borradores en RAM. Guardado atómico privado.
enum XPostDraftStore {
    static let maximumEncodedBytes = 40_000
    enum StoreError: LocalizedError {
        case tooLarge
        var errorDescription: String? { "El borrador es demasiado extenso para guardarlo." }
    }
    private static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stacklume/XDrafts", isDirectory: true)
    }
    static func load(_ id: UUID) -> XPostDraft? {
        guard let data = try? BoundedFileReader.read(root.appendingPathComponent(id.uuidString + ".json"), maximumBytes: maximumEncodedBytes) else { return nil }
        guard let draft = try? JSONDecoder().decode(XPostDraft.self, from: data),
              (try? validate(draft)) != nil else { return nil }
        return draft
    }
    static func save(_ draft: XPostDraft, id: UUID) throws {
        try PrivateFileIO.write(encodedDraft(draft), to: root.appendingPathComponent(id.uuidString + ".json"))
    }

    static func encodedDraft(_ draft: XPostDraft) throws -> Data {
        try validate(draft)
        let encoded = try JSONEncoder().encode(draft)
        guard encoded.count <= maximumEncodedBytes else { throw StoreError.tooLarge }
        return encoded
    }

    private static func validate(_ draft: XPostDraft) throws {
        guard draft.text.utf8.count <= 24_000, draft.audience.utf8.count <= 4_000,
              draft.angle.utf8.count <= 500, draft.language.utf8.count <= 32,
              draft.manualHashtags.utf8.count <= 1_000,
              draft.variants.count <= XPostTone.allCases.count,
              Set(draft.variants.map(\.id)).count == draft.variants.count,
              Set(draft.variants.map(\.tone)).count == draft.variants.count,
              draft.suggestedHashtags.count <= XPostPolicy.maximumSuggestedHashtags,
              draft.suggestedHashtags.allSatisfy({ $0.count <= 32 }),
              draft.variants.allSatisfy({ variant in
                  variant.text.utf8.count <= 24_000
                      && variant.appliedHashtags.count <= XPostPolicy.maximumAppliedHashtags
                      && variant.appliedHashtags.allSatisfy { $0.count <= 32 }
              }) else { throw StoreError.tooLarge }
    }

    static func remove(_ id: UUID) {
        let url = root.appendingPathComponent(id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
    }

    static func prune(keeping ids: Set<UUID>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !ids.contains(id) { remove(id) }
        }
    }
}
