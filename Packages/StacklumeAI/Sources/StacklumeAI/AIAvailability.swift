import Foundation
import FoundationModels

/// Estado de disponibilidad de la IA on-device (Foundation Models).
public enum AIAvailability: Sendable, Equatable {
    case available
    case appleIntelligenceNotEnabled
    case modelNotReady
    case deviceNotEligible
    case unavailable

    /// Mensaje legible para mostrar al usuario.
    public var message: String {
        switch self {
        case .available:
            "IA on-device lista."
        case .appleIntelligenceNotEnabled:
            "Activa Apple Intelligence en Ajustes para usar la IA."
        case .modelNotReady:
            "El modelo se está descargando. Inténtalo de nuevo en unos minutos."
        case .deviceNotEligible:
            "Este dispositivo no admite la IA on-device."
        case .unavailable:
            "La IA on-device no está disponible ahora mismo."
        }
    }

    public var isAvailable: Bool { self == .available }
}

public enum AIEnvironment {
    /// Disponibilidad actual del modelo del sistema.
    public static var availability: AIAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady):
            return .modelNotReady
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        default:
            return .unavailable
        }
    }
}
