import Foundation
import MLX
import MLXLMCommon

/// Conserva modelo, tokenizador y plantilla. Solo la sesión directa recibe un
/// procesador propio que completa su prefijo de asistente antes de generar.
enum LiquidSessionConfiguration {
    static func withSessionContainer<Result: Sendable>(
        for model: ModelContainer, modelID: String, thinking: Bool, observer: OneShotObserver? = nil,
        operation: @Sendable (ModelContainer) async throws -> Result
    ) async throws -> Result {
        let directory = try await model.modelDirectory
        let prefix = AssistantSessionPolicy.directResponsePrefix(
            modelID: modelID, directoryName: directory.lastPathComponent, thinking: thinking
        )
        // El alias comparte pesos, pero nunca sale de la exclusión del original.
        // La operación incluye el stream y synchronize antes de liberar este lock.
        return try await model.perform { context in
            let processor: any UserInputProcessor = prefix.map {
                DirectInputProcessor(base: context.processor, suffix: context.tokenizer.encode(text: $0, addSpecialTokens: false), observer: observer)
            } ?? context.processor
            let session = ModelContainer(context: .init(configuration: context.configuration, model: context.model,
                processor: processor, tokenizer: context.tokenizer))
            return try await operation(session)
        }
    }

    static func observe(_ observer: OneShotObserver?, at point: OneShotMilestone,
                        completion: GenerateCompletionInfo? = nil) {
        guard let observer else { return }
        let memory = Memory.snapshot()
        let info = completion.map { value -> OneShotCompletionMetrics in
            let stop: OneShotCompletionMetrics.Stop = switch value.stopReason {
            case .stop: .stop
            case .length: .length
            case .cancelled: .cancelled
            }
            return .init(promptTokens: value.promptTokenCount, generatedTokens: value.generationTokenCount,
                         promptTime: value.promptTime, generationTime: value.generateTime, stop: stop)
        }
        observer.record(.init(milestone: point, memory: .init(active: memory.activeMemory,
            cache: memory.cacheMemory, peak: memory.peakMemory), completion: info))
    }

    private struct DirectInputProcessor: UserInputProcessor {
        let base: any UserInputProcessor
        let suffix: [Int]
        let observer: OneShotObserver?

        func prepare(input: UserInput) async throws -> LMInput {
            let prepared = try await base.prepare(input: input)
            defer { LiquidSessionConfiguration.observe(observer, at: .inputPrepared) }
            // Medios y formas desconocidas conservan íntegra la entrada original.
            // Las máscaras de validez de texto extienden su cola con tokens válidos.
            guard input.images.isEmpty, input.videos.isEmpty,
                  prepared.image == nil, prepared.video == nil,
                  !prepared.text.tokens.shape.isEmpty else { return prepared }
            let tokens = prepared.text.tokens
            let tokenShape = tokens.shape
            let axis = tokenShape.count - 1
            let tailShape = Array(tokenShape.dropLast()) + [suffix.count]
            let tail = broadcast(MLXArray(suffix).asType(tokens.dtype), to: tailShape)
            var mask = prepared.text.mask
            if let original = mask {
                guard original.shape == tokenShape else { return prepared }
                mask = concatenated([original, MLXArray.ones(tailShape, dtype: original.dtype)], axis: axis)
            }
            return LMInput(text: .init(tokens: concatenated([tokens, tail], axis: axis), mask: mask),
                image: prepared.image, video: prepared.video)
        }
    }
}
