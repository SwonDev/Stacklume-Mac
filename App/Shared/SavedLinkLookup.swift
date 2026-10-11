import Foundation
import SwiftData
import StacklumeCore

/// Índice ligero de duplicados: solo cadenas canónicas, invalidado tras un guardado.
@MainActor
final class SavedLinkLookup {
    static let shared = SavedLinkLookup()
    private var keys: Set<String>?
    private var observer: NSObjectProtocol?
    private init() {
        observer = NotificationCenter.default.addObserver(forName: .stacklumeModelDidSave,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keys = nil }
        }
    }
    func contains(_ url: String, in context: ModelContext) -> Bool {
        if keys == nil {
            var descriptor = FetchDescriptor<Bookmark>(predicate: #Predicate { $0.deletedAt == nil })
            descriptor.propertiesToFetch = [\.url]
            keys = Set(((try? context.fetch(descriptor)) ?? []).map { CanonicalURL.key($0.url) })
        }
        return keys?.contains(CanonicalURL.key(url)) == true
    }
}
