import Foundation
import FoundationModels

/// Errores de la capa de IA.
public enum AIError: Error, LocalizedError, Sendable {
    case unavailable(AIAvailability)
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(availability): availability.message
        case let .generationFailed(message): message
        }
    }
}

/// Servicio de generación con Foundation Models (operaciones puntuales).
public struct AIService: Sendable {

    public init() {}

    /// Genera título, resumen y etiquetas para un enlace, FUNDAMENTÁNDOSE en los
    /// metadatos REALES extraídos de la página (título y descripción). Sin esos
    /// datos el modelo on-device tiende a inventar; por eso se le pasan y se le
    /// instruye explícitamente para no fabricar nada.
    public func suggestion(
        url: String,
        pageTitle: String?,
        pageDescription: String?,
        siteName: String?
    ) async throws -> LinkSuggestion {
        try ensureAvailable()
        let session = LanguageModelSession {
            """
            Eres un asistente que organiza marcadores web. Recibes datos REALES
            extraídos de una página (sitio, título y descripción). Tu salida debe
            basarse EXCLUSIVAMENTE en esos datos.
            DO NOT inventes hechos, cifras, nombres propios, fechas, autores ni temas
            que no aparezcan literalmente en los datos proporcionados.
            Si la descripción está vacía, resume en UNA frase qué es la página según
            su título y su dominio, sin añadir detalles inventados.
            Responde SIEMPRE en español.
            """
        }
        let prompt = """
        Sitio: \(siteName ?? "(desconocido)")
        Título de la página: \(pageTitle ?? "(ninguno)")
        Descripción de la página: \(pageDescription ?? "(ninguna)")
        URL: \(url)

        A partir ÚNICAMENTE de lo anterior, genera:
        - title: un título limpio y conciso (máx. 60 caracteres).
        - summary: 1 o 2 frases que resuman fielmente la descripción de la página.
        - tags: entre 2 y 5 etiquetas temáticas en minúscula.
        """
        do {
            let response = try await session.respond(to: prompt, generating: LinkSuggestion.self)
            return response.content
        } catch {
            throw AIError.generationFailed(error.localizedDescription)
        }
    }

    /// Sugiere una categoría y etiquetas para un enlace, priorizando las
    /// categorías existentes y fundamentándose en los datos reales del enlace.
    public func classify(
        url: String,
        title: String,
        description: String?,
        existingCategories: [String]
    ) async throws -> LinkClassification {
        try ensureAvailable()
        let categoriesList = existingCategories.isEmpty
            ? "(no hay categorías; propón una breve y genérica)"
            : existingCategories.joined(separator: ", ")
        let session = LanguageModelSession {
            """
            Clasificas marcadores web en categorías. Usa SIEMPRE una de las categorías
            existentes si alguna encaja razonablemente; solo propón una categoría
            nueva si NINGUNA encaja. Básate únicamente en los datos reales del enlace
            (título, descripción, dominio). DO NOT inventes el tema del enlace.
            Responde en español.
            """
        }
        let prompt = """
        Título: \(title)
        Descripción: \(description ?? "(ninguna)")
        URL: \(url)
        Categorías existentes: \(categoriesList)

        Elige la categoría más adecuada (reutiliza una existente si encaja) y entre 2
        y 4 etiquetas temáticas.
        """
        do {
            let response = try await session.respond(to: prompt, generating: LinkClassification.self)
            return response.content
        } catch {
            throw AIError.generationFailed(error.localizedDescription)
        }
    }

    private func ensureAvailable() throws {
        let availability = AIEnvironment.availability
        guard availability.isAvailable else { throw AIError.unavailable(availability) }
    }
}
