import Foundation

enum AssistantSessionPolicy {
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
