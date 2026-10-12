import Foundation

enum LocalAIModel: String, CaseIterable, Identifiable, Sendable {
    case ornith, mimo, liquid

    static let selectionKey = "stacklume.localAI.selectedModel"
    static let defaultModel: Self = .mimo
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .ornith: "Ornith 1.5 9B"
        case .mimo: "MiMo V2.6 Distill 9B"
        case .liquid: "LFM2.5-8B-A1B (Liquid)"
        }
    }
    var repositoryID: String {
        switch self {
        case .ornith: "Shiftedx/ornith-1.5-9b-affine4-vision-mlx"
        case .mimo: "nativ-community/MiMo-V2.6-Distill-Qwen-9B-MLX-4bit"
        case .liquid: "LiquidAI/LFM2.5-8B-A1B-MLX-8bit"
        }
    }
    var revision: String? {
        switch self {
        case .ornith: "ff90f23c9a726f7a54dc1e54d57b76e5d239af63"
        case .mimo: "3ea706a5e7b8aefb85bf37e72fe610613a50ca27"
        case .liquid: nil
        }
    }
    var supportsImages: Bool { self != .liquid }
    var downloadGB: Double {
        switch self { case .ornith: 6.51; case .mimo: 5.95; case .liquid: 9.0 }
    }
    var capabilities: String { supportsImages ? "Texto e imágenes · 4 bits" : "Texto · 8 bits" }
    var minimumMemoryGB: Double { 14.5 }
    var primesReasoning: Bool { self != .liquid }
    func templateContext(thinking: Bool) -> [String: Bool]? {
        self == .liquid && thinking ? nil : ["enable_thinking": thinking]
    }
    var toolProtocolDirective: String {
        guard self == .mimo else { return "" }
        return "Cada llamada a herramienta usa el formato XML de Qwen: <tool_call><function=NOMBRE><parameter=ARGUMENTO>VALOR</parameter></function></tool_call>. Sustituye NOMBRE y ARGUMENTO por una función y parámetros declarados; no emitas esos marcadores literales. Cada argumento lleva su etiqueta parameter; nunca pongas un objeto JSON directamente dentro de function. No llames funciones que no estén disponibles."
    }

    func contextTokens(memoryGB: Double) -> Int {
        if supportsImages {
            switch memoryGB {
            case 60...: 65_536
            case 30..<60: 32_768
            case 20..<30: 16_384
            default: 8_192
            }
        } else {
            switch memoryGB {
            case 20...: 131_072
            case 14.5..<20: 65_536
            case 7.5..<14.5: 32_768
            case 5.5..<7.5: 8_192
            default: 4_096
            }
        }
    }

    func directory(in base: URL) -> URL {
        if let revision {
            return base.appendingPathComponent("StacklumeLLM/" + repositoryID + "/" + revision, isDirectory: true)
        }
        return base.appendingPathComponent("StacklumeLLM/" + String(repositoryID.split(separator: "/").last!), isDirectory: true)
    }

    static func selected(rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? defaultModel
    }
}
