import Foundation
import MLXLMCommon

/// Adaptación del DTO de investigación a ToolSpec y ToolCall del SDK instalado.
/// Captura una propuesta candidata; no ejecuta acciones sobre la biblioteca.
enum AssistantResearchToolBridge {
    private enum SchemaError: Error { case unexpectedNull }

    static func specification(for round: AssistantResearchRound) throws -> ToolSpec {
        let schema = try JSONDecoder().decode([String: JSONValue].self, from: Data(round.deliveryTool.parametersJSON.utf8))
        let parameters = try schema.mapValues(sendableValue)
        let function: [String: any Sendable] = [
            "name": AssistantResearchToolSpecification.name,
            "description": "Entrega una propuesta: un componente completo por papel solicitado, aliases exactos de sus fuentes, encaje, alternativa y comprobación futura. No modifica la biblioteca.",
            "parameters": parameters
        ]
        return ["type": "function", "function": function]
    }

    static func output(calls: [ToolCall], generatedText: String, reachedLengthLimit: Bool) throws -> AssistantResearchToolOutput {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try .init(calls: calls.map { call in
            .init(name: call.function.name, argumentsJSON: String(decoding: try encoder.encode(call.function.arguments), as: UTF8.self))
        }, generatedText: generatedText, reachedLengthLimit: reachedLengthLimit)
    }

    private static func sendableValue(_ value: JSONValue) throws -> any Sendable {
        switch value {
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let values): return try values.map(sendableValue)
        case .object(let values): return try values.mapValues(sendableValue)
        // El transporte usa sin_fuente; el adapter Foundation lo convierte a null
        // en el DTO. El esquema no necesita introducir NSNull en ToolSpec.
        case .null: throw SchemaError.unexpectedNull
        }
    }
}
