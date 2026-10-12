import Foundation

enum AssistantSessionPolicy {
    // Los llamadores acotan la respuesta; el razonamiento tiene su propia reserva.
    static func reasonedGenerationTokens(answerTokens: Int) -> Int {
        let answer = max(1, min(answerTokens, 16_384))
        return answer + min(2_048, max(512, answer)) + 32
    }

    static func reasoningBudget(totalTokens: Int, answerTokens: Int) -> Int? {
        let answerReserve = min(256, max(1, answerTokens))
        let available = totalTokens - answerReserve - 16
        guard available > 0 else { return nil }
        return min(2_048, max(512, answerTokens), available)
    }

    static func generationLimit(requestedTokens: Int, promptTokens: Int, contextTokens: Int) -> Int? {
        guard requestedTokens > 0, promptTokens >= 0, contextTokens > 32,
              promptTokens <= contextTokens - 32 else { return nil }
        let available = contextTokens - promptTokens - 32
        guard available >= min(512, requestedTokens) else { return nil }
        return min(requestedTokens, available)
    }

    /// Este modelo no consulta enable_thinking en su plantilla. El prefijo de
    /// respuesta vacía se ha contrastado con el modelo instalado; no es un
    /// interruptor documentado por Liquid ni se aplica a otra identidad.
    static func directResponsePrefix(modelID: String, directoryName: String, thinking: Bool) -> String? {
        guard !thinking, modelID == "LiquidAI/LFM2.5-8B-A1B-MLX-8bit",
              directoryName == "LFM2.5-8B-A1B-MLX-8bit" else { return nil }
        return "<think></think>\n"
    }

    static func reachedTokenLimit(generatedTokens: Int, maximumTokens: Int, stopWasLength: Bool) -> Bool {
        stopWasLength || (maximumTokens > 0 && generatedTokens >= maximumTokens)
    }
}
