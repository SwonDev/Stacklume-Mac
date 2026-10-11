import Foundation
import FoundationModels

/// Instantánea Sendable de un enlace, para que las herramientas del chat puedan
/// consultar la biblioteca sin tocar SwiftData desde otro contexto.
public struct LinkSnapshot: Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let url: String
    public let category: String?
    public let tags: [String]

    public init(id: UUID, title: String, url: String, category: String?, tags: [String]) {
        self.id = id
        self.title = title
        self.url = url
        self.category = category
        self.tags = tags
    }
}

/// Herramienta que permite al modelo buscar en la biblioteca del usuario.
public struct SearchLibraryTool: Tool {
    public let name = "buscar_biblioteca"
    public let description = "Busca enlaces guardados del usuario por palabra clave en el título, la URL, la categoría o las etiquetas."

    let links: [LinkSnapshot]

    public init(links: [LinkSnapshot]) {
        self.links = links
    }

    @Generable
    public struct Arguments: Sendable {
        @Guide(description: "Palabras clave a buscar en la biblioteca")
        public var query: String
    }

    public func call(arguments: Arguments) async throws -> String {
        let query = arguments.query.lowercased()
        let hits = links.filter { link in
            link.title.lowercased().contains(query)
                || link.url.lowercased().contains(query)
                || (link.category?.lowercased().contains(query) ?? false)
                || link.tags.contains { $0.lowercased().contains(query) }
        }.prefix(10)

        if hits.isEmpty {
            return "No se encontraron enlaces para «\(arguments.query)»."
        }
        return hits.map { link in
            let cat = link.category.map { " · \($0)" } ?? ""
            return "- \(link.title) (\(link.url))\(cat)"
        }.joined(separator: "\n")
    }
}

/// Modelo de conversación del chat de IA (envuelve `LanguageModelSession`).
@MainActor
@Observable
public final class AIConversation {

    public struct Message: Identifiable, Sendable {
        public let id = UUID()
        public let isUser: Bool
        public var text: String
    }

    public private(set) var messages: [Message] = []
    public private(set) var isResponding = false

    public var availability: AIAvailability { AIEnvironment.availability }

    private var session: LanguageModelSession?
    private let snapshot: [LinkSnapshot]

    public init(snapshot: [LinkSnapshot]) {
        self.snapshot = snapshot
    }

    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(tools: [SearchLibraryTool(links: snapshot)]) {
            """
            Eres el asistente de Stacklume, un gestor de marcadores. Ayudas al
            usuario a encontrar y organizar sus enlaces guardados. Usa la
            herramienta de búsqueda cuando te pregunten por enlaces concretos.
            Responde en español, de forma breve y útil.
            """
        }
    }

    public func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard availability.isAvailable else {
            messages.append(Message(isUser: true, text: trimmed))
            messages.append(Message(isUser: false, text: availability.message))
            return
        }

        messages.append(Message(isUser: true, text: trimmed))

        if session == nil { session = makeSession() }
        guard let session, !session.isResponding else { return }

        isResponding = true
        do {
            let response = try await session.respond(to: trimmed)
            messages.append(Message(isUser: false, text: response.content))
        } catch {
            messages.append(Message(isUser: false, text: Self.friendlyError(error)))
        }
        isResponding = false
    }

    /// Convierte los errores técnicos de Foundation Models en mensajes claros.
    static func friendlyError(_ error: Error) -> String {
        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .guardrailViolation:
                return "No puedo ayudarte con esa petición."
            case .exceededContextWindowSize:
                return "La conversación es muy larga. Empieza una nueva e inténtalo otra vez."
            case .rateLimited:
                return "Demasiadas peticiones seguidas. Espera un momento e inténtalo de nuevo."
            case .assetsUnavailable, .decodingFailure:
                return "El modelo no está listo todavía. Inténtalo de nuevo en unos instantes."
            default:
                return "No he podido completar la respuesta. Vuelve a intentarlo."
            }
        }
        return "No he podido completar la respuesta. Vuelve a intentarlo."
    }
}
