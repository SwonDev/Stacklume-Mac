import Foundation

/// Clasificación DETERMINISTA de la colección a partir del DOMINIO del enlace. Es la fuente de
/// verdad para los sitios conocidos: su colección NO la decide el modelo de IA (que, al ser local
/// y pequeño, puede despistarse con un nombre llamativo —p. ej. un LLM «…Claude-Mythos…» de
/// `huggingface.co` acababa en «Videojuegos»—), sino esta tabla. Determinista = mismo enlace,
/// misma colección, SIEMPRE. Y es AMPLIABLE: cada dominio que se quiera fijar es una línea más
/// y queda resuelto para siempre, sin tocar el modelo ni depender de su criterio.
///
/// El nombre devuelto se resuelve luego por forma canónica ([[EntityResolver]]/[[CollectionMerger]])
/// a la colección REAL del usuario (p. ej. «IA» cae en su colección «LLM», que comparte canónica),
/// o la crea si no existe. Tiene PRIORIDAD sobre la sugerencia de la IA, tanto al alta como al
/// «Mejorar con IA».
///
/// Complementa a `AutoCategorizer`/`PlatformDetector` del paquete (que ya clasifican por TIPO de
/// contenido: GitHub→Desarrollo, YouTube→Vídeos, Steam→Videojuegos, Spotify→Música…). Aquí van los
/// dominios cuya categoría es inequívoca pero que el detector deja como genéricos (`.website`).
enum DomainCategoryRules {

    /// Dominio (host sin `www.`) → nombre de colección canónica. Se empareja por host exacto o
    /// subdominio (`*.dominio`). Ampliar es añadir una entrada. Conservador: solo casos CLAROS,
    /// para no robarle a la IA los dominios genéricos (un blog personal puede ser de cualquier tema).
    private static let map: [String: String] = [
        // Inteligencia Artificial / modelos (LLM, imagen, inferencia, ML).
        "huggingface.co": "IA", "hf.co": "IA",
        "ollama.com": "IA", "ollama.ai": "IA",
        "replicate.com": "IA", "civitai.com": "IA", "modelscope.cn": "IA",
        "together.ai": "IA", "groq.com": "IA", "openrouter.ai": "IA",
        "lmstudio.ai": "IA", "mistral.ai": "IA", "cohere.com": "IA",
        "perplexity.ai": "IA", "midjourney.com": "IA", "runwayml.com": "IA",
        "elevenlabs.io": "IA", "stability.ai": "IA", "anthropic.com": "IA",
        "openai.com": "IA", "platform.openai.com": "IA", "deepmind.com": "IA",
        "paperswithcode.com": "IA", "kaggle.com": "IA",
        // Productos/servicios INEQUÍVOCAMENTE de IA (conservador: solo casos claros).
        "claude.ai": "IA", "gemini.google.com": "IA", "notebooklm.google.com": "IA",
        "x.ai": "IA", "character.ai": "IA", "poe.com": "IA", "wandb.ai": "IA",
        "lightning.ai": "IA", "leonardo.ai": "IA", "ideogram.ai": "IA", "krea.ai": "IA",
        "suno.com": "IA", "udio.com": "IA", "fal.ai": "IA", "comfy.org": "IA",
    ]

    /// Nombre de colección determinista para el dominio del enlace, o `nil` si no hay regla
    /// (entonces decide la IA con el contenido real). `title`/`details` quedan disponibles por si
    /// en el futuro una regla necesita afinar por contenido; hoy basta el host.
    static func categoryName(forURL url: String, title: String = "", details: String? = nil) -> String? {
        let host = url.urlHost.lowercased()
        for (domain, category) in map where host == domain || host.hasSuffix("." + domain) {
            return category
        }
        return nil
    }
}
