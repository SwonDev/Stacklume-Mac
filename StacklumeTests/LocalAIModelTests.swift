import Foundation
import Testing

@Suite("Modelos locales y adjuntos privados")
struct LocalAIModelTests {
    @Test("Cambiar el predeterminado conserva una elección explícita anterior")
    func preservesSelection() {
        #expect(LocalAIModel.defaultModel == .mimo)
        #expect(LocalAIModel.selected(rawValue: nil) == .mimo)
        #expect(LocalAIModel.selected(rawValue: "liquid") == .liquid)
        #expect(LocalAIModel.selected(rawValue: "mimo") == .mimo)
        #expect(LocalAIModel.selected(rawValue: "ornith") == .ornith)
    }

    @Test("El razonamiento visual se configura explícitamente y conserva la frontera de Liquid")
    func explicitlyConfiguresThinking() {
        for model in [LocalAIModel.mimo, .ornith] {
            #expect(model.templateContext(thinking: true)?["enable_thinking"] == true)
            #expect(model.templateContext(thinking: false)?["enable_thinking"] == false)
        }
        #expect(LocalAIModel.liquid.templateContext(thinking: true) == nil)
        #expect(LocalAIModel.liquid.templateContext(thinking: false)?["enable_thinking"] == false)
    }

    @Test("El razonamiento deja una respuesta incluso con límites pequeños y contexto lleno")
    func reservesReasoningAndAnswer() throws {
        for answer in [48, 80, 160, 512, 700, 2048, 8192] {
            let requested = AssistantSessionPolicy.reasonedGenerationTokens(answerTokens: answer)
            #expect(requested > answer)
            for context in [8192, 16384] {
                for prompt in [500, context - 800] {
                    let total = try #require(AssistantSessionPolicy.generationLimit(
                        requestedTokens: requested, promptTokens: prompt, contextTokens: context))
                    let reasoning = try #require(AssistantSessionPolicy.reasoningBudget(totalTokens: total, answerTokens: answer))
                    #expect(reasoning > 0)
                    #expect(reasoning <= 2048)
                    #expect(reasoning + min(256, answer) + 16 <= total)
                    #expect(total + prompt + 32 <= context)
                }
            }
        }
        #expect(AssistantSessionPolicy.reasoningBudget(totalTokens: 16, answerTokens: 48) == nil)
        #expect(LocalAIModel.mimo.primesReasoning)
        #expect(LocalAIModel.ornith.primesReasoning)
    }

    @Test("El contexto visual de 16 GB no hereda la ventana larga de Liquid")
    func boundsVisualContext() {
        for model in [LocalAIModel.ornith, .mimo] {
            #expect(model.contextTokens(memoryGB: 16) <= 8192)
            #expect(model.contextTokens(memoryGB: 24) <= 16384)
            #expect(model.contextTokens(memoryGB: 64) <= 65536)
            #expect(model.downloadGB < 7)
        }
        #expect(LocalAIModel.liquid.contextTokens(memoryGB: 24) == 131072)
    }

    @Test("Los modelos fijados no comparten carpeta ni mezclan revisiones")
    func separatesCheckpoints() {
        let base = URL(fileURLWithPath: "/tmp/StacklumeModelTest")
        #expect(Set(LocalAIModel.allCases.map { $0.directory(in: base) }).count == 3)
        for model in [LocalAIModel.ornith, .mimo] {
            #expect(model.directory(in: base).lastPathComponent == model.revision)
        }
    }

    @Test("Los adjuntos rechazan rutas externas y permanecen privados en la recuperación")
    func imageRecoveryAndTraversal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("chat.json")
        #expect(AssistantChatImageStore.url(for: "../../secreto", storeURL: store) == nil)
        let id = try AssistantChatImageStore.save(Data([0xff, 0xd8, 0xff, 0xd9]), storeURL: store)
        let image = try #require(AssistantChatImageStore.url(for: id, storeURL: store))
        let message = AssistantStoredMessage(isUser: true, text: "Describe la imagen", imageID: id)
        let session = AssistantStoredSession(id: UUID(), title: "Imagen", createdAt: .now, updatedAt: .now, messages: [message])
        #expect(AssistantConversationStore.save([session], to: store))
        #expect(AssistantConversationStore.save([], to: store))
        #expect(FileManager.default.fileExists(atPath: image.path))
        #expect((try FileManager.default.attributesOfItem(atPath: image.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try Data("corrupto".utf8).write(to: store)
        #expect(AssistantConversationStore.loadResult(from: store).sessions.first?.messages.first?.imageID == id)
        #expect(AssistantConversationStore.removeAll(at: store))
        #expect(!FileManager.default.fileExists(atPath: image.path))
    }
}
