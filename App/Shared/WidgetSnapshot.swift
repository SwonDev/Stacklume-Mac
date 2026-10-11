import Foundation

/// Snapshot ligero de la biblioteca para el widget (compartido app↔widget vía fichero).
struct WidgetSnapshot: Codable {
    struct Item: Codable, Identifiable {
        var id: String
        var title: String
        var host: String
        var colorHex: String
    }
    var favorites: [Item]
    var generatedAt: Date

    /// Ruta del fichero compartido (sin sandbox, accesible por app y widget).
    static func fileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Stacklume", isDirectory: true)
        try? PrivateFileIO.ensureDirectory(dir)
        return dir.appendingPathComponent("widget-snapshot.json")
    }

    static func load() -> WidgetSnapshot {
        guard let data = try? BoundedFileReader.read(fileURL(), maximumBytes: 1 * 1_024 * 1_024),
              let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else {
            return WidgetSnapshot(favorites: [], generatedAt: Date())
        }
        return snap
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            try? PrivateFileIO.write(data, to: Self.fileURL())
        }
    }
}
