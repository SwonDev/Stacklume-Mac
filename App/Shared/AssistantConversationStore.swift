import Foundation

struct AssistantStoredMessage: Codable, Equatable, Sendable {
    let isUser: Bool
    let text: String
    let references: [AssistantLinkReference]
    let imageID: String?

    init(isUser: Bool, text: String, references: [AssistantLinkReference] = [], imageID: String? = nil) {
        self.isUser = isUser
        self.text = text
        self.references = references
        self.imageID = isUser ? imageID.flatMap { UUID(uuidString: $0)?.uuidString } : nil
    }

    private enum CodingKeys: String, CodingKey {
        case isUser, text, references, imageID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isUser = try values.decode(Bool.self, forKey: .isUser)
        text = try values.decode(String.self, forKey: .text)
        // Compatibilidad con los historiales de 1.49 y anteriores.
        references = try values.decodeIfPresent([AssistantLinkReference].self, forKey: .references) ?? []
        let rawID = try values.decodeIfPresent(String.self, forKey: .imageID)
        imageID = isUser ? rawID.flatMap { UUID(uuidString: $0)?.uuidString } : nil
    }
}

struct AssistantStoredSession: Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [AssistantStoredMessage]
}

struct AssistantConversationLoadResult: Equatable, Sendable {
    let sessions: [AssistantStoredSession]
    let recoveredFromBackup: Bool
}

/// Store local para conversaciones extensas. UserDefaults solo conserva las claves de
/// configuración; el texto del chat se escribe como JSON atómico privado (0600), acotado y
/// recuperable. El formato es deliberadamente simple para migrar los chats existentes.
enum AssistantConversationStore {
    static let maximumSessions = 60
    static let maximumMessagesPerSession = 400
    static let maximumMessageCharacters = 24_000
    static let maximumFileBytes = 32 * 1_024 * 1_024
    /// Tope del índice efímero por conversación. Conserva primero el título y los mensajes
    /// más recientes, suficientes para buscar en chats largos sin duplicar en RAM todo el
    /// historial persistido (que puede alcanzar decenas de megabytes).
    static let maximumSearchIndexCharacters = 120_000

    static func defaultURL() -> URL? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--stacklume-marketing-demo")
            || arguments.contains(where: { $0.hasPrefix("--stacklume-marketing-demo=") }) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "StacklumeMarketingDemo-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                return directory.appendingPathComponent("assistant-conversations.json")
            } catch {
                return nil
            }
        }
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let directory = base.appendingPathComponent("Stacklume", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            return nil
        }
        return directory.appendingPathComponent("assistant-conversations.json")
    }

    static func load(from url: URL? = defaultURL()) -> [AssistantStoredSession] {
        loadResult(from: url).sessions
    }

    @discardableResult
    static func removeAll(at url: URL? = defaultURL()) -> Bool {
        guard let url else { return false }
        do {
            // Vacía también la rotación: si falta o se corrompe el principal, no
            // debe recuperarse una conversación que el usuario ha borrado.
            let empty = Data("[]".utf8)
            try PrivateFileIO.write(empty, to: backupURL(for: url))
            try PrivateFileIO.write(empty, to: url)
            AssistantChatImageStore.purge(retaining: [], storeURL: url)
            return true
        } catch { return false }
    }

    /// Lee primero el archivo principal y, si está ausente, truncado o corrupto, recupera la
    /// última instantánea válida. Un array vacío válido NO activa el respaldo.
    static func loadResult(from url: URL? = defaultURL()) -> AssistantConversationLoadResult {
        guard let url else { return .init(sessions: [], recoveredFromBackup: false) }
        if let primary = decodedSessions(from: url) {
            return .init(sessions: sanitized(primary), recoveredFromBackup: false)
        }
        if let backup = decodedSessions(from: backupURL(for: url)) {
            return .init(sessions: sanitized(backup), recoveredFromBackup: true)
        }
        return .init(sessions: [], recoveredFromBackup: false)
    }

    @discardableResult
    static func save(_ sessions: [AssistantStoredSession], to url: URL? = defaultURL()) -> Bool {
        guard let url else { return false }
        let safe = sanitized(sessions)
        guard let data = try? JSONEncoder().encode(safe), data.count <= maximumFileBytes else { return false }
        do {
            // Solo rota una versión principal que siga siendo decodificable. Así un archivo
            // corrupto nunca reemplaza el último respaldo sano.
            if decodedSessions(from: url) != nil,
               let previous = try? BoundedFileReader.read(url, maximumBytes: maximumFileBytes) {
                let backup = backupURL(for: url)
                try PrivateFileIO.write(previous, to: backup)
            }
            try PrivateFileIO.write(data, to: url)
            let backup = decodedSessions(from: backupURL(for: url)) ?? []
            let retained = Set((safe + backup).flatMap { $0.messages.compactMap(\.imageID) })
            AssistantChatImageStore.purge(retaining: retained, storeURL: url)
            return true
        } catch {
            return false
        }
    }

    static func sanitized(_ sessions: [AssistantStoredSession]) -> [AssistantStoredSession] {
        sessions
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(maximumSessions)
            .map { session in
                var copy = session
                copy.title = String(AssistantActionPolicy.sanitizedUserInput(session.title).prefix(80))
                copy.messages = session.messages
                    .suffix(maximumMessagesPerSession)
                    .compactMap { message in
                        let text = AssistantActionPolicy.sanitizedText(
                            message.text, maximumCharacters: maximumMessageCharacters
                        )
                        let references = message.isUser
                            ? []
                            : AssistantResponsePresentation.sanitizedReferences(message.references)
                        return text.isEmpty ? nil : AssistantStoredMessage(
                            isUser: message.isUser,
                            text: text,
                            references: references,
                            imageID: message.imageID
                        )
                    }
                return copy
            }
    }

    /// Texto normalizado y acotado para el buscador del historial. Se genera bajo demanda y
    /// nunca se persiste: no crea otra copia durable de las conversaciones privadas.
    static func searchIndex(for session: AssistantStoredSession) -> String {
        var result = String(normalizedSearchText(session.title).prefix(maximumSearchIndexCharacters))
        result.reserveCapacity(min(maximumSearchIndexCharacters, result.count + 16_384))

        for message in session.messages.reversed() {
            let separatorCount = result.isEmpty ? 0 : 1
            let available = maximumSearchIndexCharacters - result.count - separatorCount
            guard available > 0 else { break }

            let normalized = normalizedSearchText(message.text)
            guard !normalized.isEmpty else { continue }
            if separatorCount == 1 { result.append("\n") }
            result.append(contentsOf: normalized.prefix(available))
        }
        return result
    }

    static func normalizedSearchText(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        ).lowercased()
    }

    static func backupURL(for url: URL) -> URL {
        url.appendingPathExtension("previous")
    }

    private static func decodedSessions(from url: URL) -> [AssistantStoredSession]? {
        guard let data = try? BoundedFileReader.read(url, maximumBytes: maximumFileBytes)
        else { return nil }
        return try? JSONDecoder().decode([AssistantStoredSession].self, from: data)
    }
}
