import Foundation
import SwiftData

/// Tipo de condición de una regla de auto-clasificación.
public enum RuleConditionType: String, Codable, CaseIterable, Sendable, Identifiable {
    case urlPattern, titleKeyword, platform, domain

    public var id: String { rawValue }

    public var displayName: String {
        let raw: String
        switch self {
        case .urlPattern: raw = "La URL contiene"
        case .titleKeyword: raw = "El título contiene"
        case .platform: raw = "La plataforma es"
        case .domain: raw = "El dominio contiene"
        }
        return localizedDomain(raw)
    }
}

/// Modo de coincidencia de una regla con varias condiciones: TODAS (AND) o ALGUNA (OR).
public enum RuleMatchMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case all, any

    public var id: String { rawValue }

    public var displayName: String {
        let raw: String
        switch self {
        case .all: raw = "Cumple TODAS"
        case .any: raw = "Cumple ALGUNA"
        }
        return localizedDomain(raw)
    }
}

/// Una condición individual de una regla (tipo + valor). Se usa para las condiciones
/// ADICIONALES (más allá de la primera, que se guarda en `conditionType`/`conditionValue`
/// por retrocompatibilidad). `Codable` para persistir como atributo compuesto en SwiftData.
public struct RuleConditionSpec: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var type: RuleConditionType
    public var value: String

    public init(id: UUID = UUID(), type: RuleConditionType = .domain, value: String = "") {
        self.id = id
        self.type = type
        self.value = value
    }
}

/// Acción de una regla de auto-clasificación.
public enum RuleActionType: String, Codable, CaseIterable, Sendable, Identifiable {
    case setCategory, addTag

    public var id: String { rawValue }

    public var displayName: String {
        let raw: String
        switch self {
        case .setCategory: raw = "Asignar categoría"
        case .addTag: raw = "Añadir etiqueta"
        }
        return localizedDomain(raw)
    }
}

/// Una acción individual de una regla (tipo + UUID-en-texto del destino). Se usa para las
/// acciones ADICIONALES (más allá de la primera, que vive en `actionType`/`actionValue`).
public struct RuleActionSpec: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var type: RuleActionType
    public var value: String

    public init(id: UUID = UUID(), type: RuleActionType = .addTag, value: String = "") {
        self.id = id
        self.type = type
        self.value = value
    }
}

/// Regla de auto-clasificación: si un enlace cumple la condición, se le aplica la
/// acción (asignar categoría o añadir etiqueta).
@Model
public final class ClassificationRule {
    public var id: UUID = UUID()
    public var name: String = ""
    public var conditionType: RuleConditionType = RuleConditionType.domain
    public var conditionValue: String = ""
    public var actionType: RuleActionType = RuleActionType.addTag
    /// UUID (en texto) de la categoría o etiqueta objetivo.
    public var actionValue: String = ""
    public var order: Int = 0
    public var isActive: Bool = true
    public var createdAt: Date = Date()
    /// Modo de coincidencia cuando hay varias condiciones (AND/OR). Por defecto `.all`, así
    /// las reglas de una sola condición se comportan EXACTAMENTE igual que antes.
    public var matchMode: RuleMatchMode = RuleMatchMode.all
    /// Condiciones ADICIONALES (la primera vive en `conditionType`/`conditionValue`).
    /// Vacío = regla de una sola condición (retrocompatible).
    public var extraConditions: [RuleConditionSpec] = []
    /// Acciones ADICIONALES (la primera vive en `actionType`/`actionValue`). Vacío = una
    /// sola acción (retrocompatible). Permite, p. ej., asignar categoría Y añadir etiqueta.
    public var extraActions: [RuleActionSpec] = []

    /// Conjunto COMPLETO de condiciones (la primaria + las adicionales), para el motor y la UI.
    public var allConditions: [RuleConditionSpec] {
        [RuleConditionSpec(type: conditionType, value: conditionValue)] + extraConditions
    }

    /// Conjunto COMPLETO de acciones (la primaria + las adicionales).
    public var allActions: [RuleActionSpec] {
        [RuleActionSpec(type: actionType, value: actionValue)] + extraActions
    }

    public init(
        id: UUID = UUID(),
        name: String = "",
        conditionType: RuleConditionType = .domain,
        conditionValue: String = "",
        actionType: RuleActionType = .addTag,
        actionValue: String = "",
        order: Int = 0,
        isActive: Bool = true
    ) {
        self.id = id
        self.name = name
        self.conditionType = conditionType
        self.conditionValue = conditionValue
        self.actionType = actionType
        self.actionValue = actionValue
        self.order = order
        self.isActive = isActive
        self.createdAt = Date()
    }
}
