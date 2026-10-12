import Foundation

enum AssistantChatImageStore {
    static func directory(for storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("assistant-images", isDirectory: true)
    }

    static func url(for id: String?, storeURL: URL? = AssistantConversationStore.defaultURL()) -> URL? {
        guard let id, let uuid = UUID(uuidString: id), let storeURL else { return nil }
        return directory(for: storeURL).appendingPathComponent(uuid.uuidString + ".jpg")
    }

    static func save(_ jpeg: Data, storeURL: URL? = AssistantConversationStore.defaultURL()) throws -> String {
        guard !jpeg.isEmpty, jpeg.count <= 4 * 1_024 * 1_024, let storeURL else { throw CocoaError(.fileWriteUnknown) }
        let id = UUID().uuidString
        try PrivateFileIO.write(jpeg, to: directory(for: storeURL).appendingPathComponent(id + ".jpg"))
        return id
    }

    static func purge(retaining ids: Set<String>, storeURL: URL) {
        let directory = directory(for: storeURL)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "jpg" {
            let id = file.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: id) != nil, !ids.contains(id) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
