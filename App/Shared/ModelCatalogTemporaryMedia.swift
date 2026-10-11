import Foundation

enum ModelCatalogTemporaryMedia {
    static let maximumFileBytes = 64 * 1_024 * 1_024
    static let maximumReservedBytes = 128 * 1_024 * 1_024
    private static let store = Store(directory: FileManager.default.temporaryDirectory.appendingPathComponent("stacklume-model-media", isDirectory: true))

    static func create(extension fileExtension: String) throws -> URL { try store.create(extension: fileExtension) }
    static func remove(_ url: URL) { store.remove(url) }
    static func purgeOnLaunch() { store.purge() }
    static func purgeOnTermination() { store.purge() }

    // Todas las reservas y operaciones de disco están protegidas por el mismo lock.
    final class Store: @unchecked Sendable {
        private let directory: URL
        private let lock = NSLock()
        private var active: Set<String> = []

        init(directory: URL) { self.directory = directory.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(directory.lastPathComponent, isDirectory: true) }

        func create(extension fileExtension: String) throws -> URL {
            lock.lock(); defer { lock.unlock() }
            guard active.count * maximumFileBytes < maximumReservedBytes,
                  !fileExtension.isEmpty, fileExtension.count <= 8, fileExtension.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw ModelCatalogError.mediaTooLarge }
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else { throw ModelCatalogError.unsafeURL }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let entries = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            for entry in entries where isOwned(entry) && !active.contains(entry.lastPathComponent) { try? manager.removeItem(at: entry) }
            let url = directory.appendingPathComponent("sample-\(UUID().uuidString).\(fileExtension)")
            guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ModelCatalogError.invalidResponse }
            active.insert(url.lastPathComponent)
            return url
        }

        func remove(_ url: URL) {
            lock.lock(); defer { lock.unlock() }
            guard isOwned(url) else { return }
            try? FileManager.default.removeItem(at: url); active.remove(url.lastPathComponent)
        }

        func purge() {
            lock.lock(); defer { lock.unlock() }
            guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { return }
            if let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for url in entries where isOwned(url) { try? FileManager.default.removeItem(at: url) }
            }
            active.removeAll()
        }

        private func isOwned(_ url: URL) -> Bool {
            url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path && url.lastPathComponent.hasPrefix("sample-") && UUID(uuidString: String(url.deletingPathExtension().lastPathComponent.dropFirst(7))) != nil
        }
    }
}
