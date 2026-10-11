import Foundation
import FoundationModels

/// Sugerencia generada por la IA para un enlace.
@Generable
public struct LinkSuggestion: Sendable {
    @Guide(description: "Un título claro y conciso basado en el título real de la página, máximo 60 caracteres")
    public var title: String

    @Guide(description: "Resumen fiel del contenido en 1 o 2 frases, basado SOLO en la descripción real proporcionada; nunca inventes datos")
    public var summary: String

    @Guide(description: "Entre 2 y 5 etiquetas temáticas en minúscula derivadas del contenido real, sin almohadilla")
    public var tags: [String]

    public init(title: String, summary: String, tags: [String]) {
        self.title = title
        self.summary = summary
        self.tags = tags
    }
}

/// Clasificación sugerida por la IA para un enlace.
@Generable
public struct LinkClassification: Sendable {
    @Guide(description: "La categoría más adecuada para el enlace")
    public var category: String

    @Guide(description: "Entre 2 y 4 etiquetas temáticas en minúscula")
    public var tags: [String]

    public init(category: String, tags: [String]) {
        self.category = category
        self.tags = tags
    }
}
