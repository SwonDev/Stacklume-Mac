import Foundation

/// Procedencia privada de una portada recuperada desde la página original. Las URLs
/// exactas permiten al usuario revisar el origen; nunca se escriben en los logs.
@MainActor
final class CoverRecoveryProvenanceStore {
    struct Entry: Codable, Equatable, Sendable {
        let referenceURL: String
        let pageURL: String
        let recoveredImageURL: String
        let recoveredAt: Date
        let coverJPEGDigest: String

        var isValid: Bool {
            guard [referenceURL, pageURL, recoveredImageURL].allSatisfy({ $0.utf8.count <= 16_384 }),
                  StacklumeAutomationPolicy.openableStoredURL(referenceURL) != nil,
                  let page = URL(string: pageURL), let image = URL(string: recoveredImageURL),
                  StacklumeAutomationPolicy.allowsAutomaticNetworkURL(page),
                  StacklumeAutomationPolicy.allowsAutomaticNetworkURL(image),
                  coverJPEGDigest.count == 64,
                  coverJPEGDigest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return false }
            return true
        }
    }

    static let maximumEntries = 100_000
    static let maximumBytes = 64 * 1_024 * 1_024
    static let shared: CoverRecoveryProvenanceStore = {
        let base = try? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        return CoverRecoveryProvenanceStore(fileURL: base?.appendingPathComponent("Stacklume/cover-recovery-provenance.json"))
    }()

    private let fileURL: URL?
    private var entries: [String: Entry] = [:]
    private var readable = true

    init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? BoundedFileReader.read(fileURL, maximumBytes: Self.maximumBytes),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data),
              decoded.count <= Self.maximumEntries,
              decoded.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value.isValid }) else {
            // Un archivo dañado se conserva: no se reemplaza silenciosamente por uno vacío.
            readable = false
            return
        }
        entries = decoded
    }

    func entry(for id: UUID) -> Entry? { entries[id.uuidString] }
    func allEntries() -> [String: Entry] { entries }

    @discardableResult
    func record(_ entry: Entry, for id: UUID) -> Bool {
        guard entry.isValid else { return false }
        var updated = entries
        updated[id.uuidString] = entry
        return persist(updated)
    }

    @discardableResult
    func remove(_ id: UUID) -> Bool {
        var updated = entries
        updated[id.uuidString] = nil
        return persist(updated)
    }

    @discardableResult
    func removeAll() -> Bool { persist([:]) }

    @discardableResult
    func prune(keeping live: Set<UUID>) -> Bool {
        let ids = Set(live.map(\.uuidString))
        let updated = entries.filter { ids.contains($0.key) }
        guard updated.count != entries.count else { return true }
        return persist(updated)
    }

    private func persist(_ updated: [String: Entry]) -> Bool {
        guard readable, let fileURL, updated.count <= Self.maximumEntries,
              let data = try? JSONEncoder().encode(updated), data.count <= Self.maximumBytes else { return false }
        do {
            try PrivateFileIO.ensureDirectory(fileURL.deletingLastPathComponent())
            try PrivateFileIO.write(data, to: fileURL)
            entries = updated
            return true
        } catch { return false }
    }
}
