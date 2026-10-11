import Foundation
import Testing

@Suite("Asistente IA — conversaciones privadas")
struct AssistantConversationStoreTests {
    @Test("Un fallo de reset conserva el estado previo de recuperación")
    func failedResetRestoresRecoveryIntent() throws {
        let suite = "StacklumeFailedReset-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        enum Failure: Error { case injected }
        for previous in [false, true] {
            if previous { LibraryResetIntent.markIntentionalReset(in: defaults) }
            else { LibraryResetIntent.didCreateNonemptyBackup(in: defaults) }
            do {
                try LibraryResetIntent.performingReset(in: defaults) {
                    #expect(LibraryResetIntent.preventsAutomaticRecovery(in: defaults))
                    throw Failure.injected
                }
                Issue.record("El fallo inyectado no se propagó")
            } catch Failure.injected { }
            #expect(LibraryResetIntent.preventsAutomaticRecovery(in: defaults) == previous)
        }
        LibraryResetIntent.performingReset(in: defaults) { }
        #expect(LibraryResetIntent.preventsAutomaticRecovery(in: defaults))
    }

    @Test("Restablecer vacía el archivo actual y su rotación, incluso si el principal falta")
    func resetClearsCurrentAndPreviousHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacklumeReset-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("conversations.json")
        let old = AssistantStoredSession(id: UUID(), title: "Historial sintético",
            createdAt: .distantPast, updatedAt: .distantPast,
            messages: [AssistantStoredMessage(isUser: true, text: "Contenido anterior")])
        #expect(AssistantConversationStore.save([old], to: url))
        #expect(AssistantConversationStore.save([old], to: url))
        #expect(AssistantConversationStore.removeAll(at: url))
        #expect(AssistantConversationStore.load(from: url).isEmpty)
        let previous = AssistantConversationStore.backupURL(for: url)
        #expect(try Data(contentsOf: previous) == Data("[]".utf8))
        try FileManager.default.removeItem(at: url)
        #expect(AssistantConversationStore.load(from: url).isEmpty)
        try Data("corrupto".utf8).write(to: url)
        #expect(AssistantConversationStore.load(from: url).isEmpty)
        #expect(AssistantConversationStore.save([old], to: url))
        #expect(AssistantConversationStore.load(from: url) == [old])
    }

    @Test("El vacío intencional persiste y una copia nueva no vacía permite recuperación")
    func intentionalEmptyLibrarySurvivesRestart() throws {
        let suite = "StacklumeResetIntent-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!LibraryResetIntent.preventsAutomaticRecovery(in: defaults))
        LibraryResetIntent.markIntentionalReset(in: defaults)
        let reloaded = try #require(UserDefaults(suiteName: suite))
        #expect(LibraryResetIntent.preventsAutomaticRecovery(in: reloaded))
        LibraryResetIntent.didCreateNonemptyBackup(in: reloaded)
        #expect(!LibraryResetIntent.preventsAutomaticRecovery(in: defaults))
    }

    @Test("Guarda y recupera el historial con permisos privados")
    func roundTripAndPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacklumeAssistantStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("conversations.json")
        let session = AssistantStoredSession(
            id: UUID(),
            title: "Proyecto Atlántico",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            messages: [
                AssistantStoredMessage(isUser: true, text: "¿Qué guardé ayer?"),
                AssistantStoredMessage(
                    isUser: false,
                    text: "Encontré tres enlaces.",
                    references: [AssistantLinkReference(
                        title: "Swift.org",
                        url: "https://www.swift.org/",
                        summary: "Lenguaje Swift.",
                        collection: nil,
                        tags: ["Swift"],
                        origin: .web
                    )]
                ),
            ]
        )

        #expect(AssistantConversationStore.save([session], to: url))
        #expect(AssistantConversationStore.load(from: url) == [session])

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test("Migra mensajes anteriores sin referencias interactivas")
    func decodesLegacyMessage() throws {
        let data = Data(#"{"isUser":false,"text":"Respuesta antigua"}"#.utf8)
        let message = try JSONDecoder().decode(AssistantStoredMessage.self, from: data)
        #expect(message.text == "Respuesta antigua")
        #expect(message.references.isEmpty)
    }

    @Test("Acota sesiones, mensajes y contenido invisible")
    func boundsStoredData() {
        let now = Date()
        let messages = (0..<500).map { index in
            AssistantStoredMessage(isUser: index.isMultiple(of: 2), text: "mensaje \(index)\u{202E}")
        }
        let sessions = (0..<80).map { index in
            AssistantStoredSession(
                id: UUID(),
                title: "chat \(index)\u{202E}",
                createdAt: now,
                updatedAt: now.addingTimeInterval(TimeInterval(index)),
                messages: messages
            )
        }

        let safe = AssistantConversationStore.sanitized(sessions)
        #expect(safe.count == AssistantConversationStore.maximumSessions)
        #expect(safe.first?.title == "chat 79")
        #expect(safe.first?.messages.count == AssistantConversationStore.maximumMessagesPerSession)
        #expect(safe.allSatisfy { !$0.title.contains("\u{202E}") })
        #expect(safe.allSatisfy { session in
            session.messages.allSatisfy { !$0.text.contains("\u{202E}") }
        })
    }

    @Test("Un archivo corrupto no rompe el arranque")
    func rejectsCorruptFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacklumeAssistantCorrupt-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: AssistantConversationStore.backupURL(for: url))
        }
        try Data("{no es json".utf8).write(to: url)
        #expect(AssistantConversationStore.load(from: url).isEmpty)
    }

    @Test("Recupera la última instantánea válida si el historial principal se corrompe")
    func recoversPreviousSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacklumeAssistantRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("conversations.json")
        let first = AssistantStoredSession(
            id: UUID(), title: "Primera versión",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            messages: [AssistantStoredMessage(isUser: true, text: "Mensaje conservado")]
        )
        var second = first
        second.title = "Segunda versión"
        second.updatedAt = Date(timeIntervalSince1970: 3)

        #expect(AssistantConversationStore.save([first], to: url))
        #expect(AssistantConversationStore.save([second], to: url))
        try Data("{historial truncado".utf8).write(to: url, options: .atomic)

        let recovered = AssistantConversationStore.loadResult(from: url)
        #expect(recovered.recoveredFromBackup)
        #expect(recovered.sessions == [first])

        let attributes = try FileManager.default.attributesOfItem(
            atPath: AssistantConversationStore.backupURL(for: url).path
        )
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("Un historial vacío válido no resucita una copia anterior")
    func validEmptyHistoryDoesNotRestoreBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacklumeAssistantEmpty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("conversations.json")
        let old = AssistantStoredSession(
            id: UUID(), title: "Anterior", createdAt: .distantPast,
            updatedAt: .distantPast, messages: [AssistantStoredMessage(isUser: true, text: "Antiguo")]
        )

        #expect(AssistantConversationStore.save([old], to: url))
        #expect(AssistantConversationStore.save([], to: url))

        let loaded = AssistantConversationStore.loadResult(from: url)
        #expect(!loaded.recoveredFromBackup)
        #expect(loaded.sessions.isEmpty)
    }

    @Test("El índice encuentra texto sin depender de mayúsculas ni acentos")
    func normalizedSearchIndex() {
        let session = AssistantStoredSession(
            id: UUID(), title: "Investigación Atlántica", createdAt: .distantPast,
            updatedAt: .distantPast,
            messages: [AssistantStoredMessage(isUser: false, text: "Diseño y organización")]
        )

        let index = AssistantConversationStore.searchIndex(for: session)
        #expect(index.contains(AssistantConversationStore.normalizedSearchText("ATLANTICA")))
        #expect(index.contains(AssistantConversationStore.normalizedSearchText("diseño")))
    }

    @Test("El índice de un chat largo está acotado y prioriza lo reciente")
    func boundedSearchIndexPrefersRecentMessages() {
        let filler = String(repeating: "x", count: AssistantConversationStore.maximumMessageCharacters - 20)
        let messages = (0..<12).map { index in
            AssistantStoredMessage(
                isUser: index.isMultiple(of: 2),
                text: index == 11 ? "MARCADOR_RECIENTE \(filler)" : "mensaje_\(index) \(filler)"
            )
        }
        let session = AssistantStoredSession(
            id: UUID(), title: "Chat extenso", createdAt: .distantPast,
            updatedAt: .distantPast, messages: messages
        )

        let index = AssistantConversationStore.searchIndex(for: session)
        #expect(index.count <= AssistantConversationStore.maximumSearchIndexCharacters)
        #expect(index.contains("marcador_reciente"))
        #expect(!index.contains("mensaje_0"))
    }
}
