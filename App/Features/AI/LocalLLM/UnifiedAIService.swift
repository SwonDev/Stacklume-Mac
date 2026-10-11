import Foundation
import StacklumeAI

enum UnifiedAIError: LocalizedError {
    case liquidNotLoaded
    case liquidFailed
    var errorDescription: String? {
        switch self {
        case .liquidNotLoaded:
            "Carga el modelo Liquid en Ajustes › Inteligencia Artificial para usar la IA."
        case .liquidFailed:
            "El modelo Liquid no pudo generar una respuesta. Inténtalo de nuevo."
        }
    }
}

/// Servicio de IA unificado para sugerencias y clasificación de enlaces. Usa
/// EXCLUSIVAMENTE el motor elegido por el usuario (uno u otro): si es Liquid usa
/// el modelo local (sin recurrir a Apple, para no activar/cargar el de Apple en
/// memoria); si es Apple usa Foundation Models.
/// Resultado del enriquecido completo de un enlace en UNA sola pasada de IA: título
/// mejorado, descripción rica, categoría y etiquetas, todo en el idioma activo.
struct EnrichedSuggestion: Sendable {
    let title: String
    let summary: String
    let category: String
    let tags: [String]
}

/// Caché de sugerencias por (idioma + URL): permite precalcular en segundo plano y
/// que «Sugerir con IA» sea instantáneo. `inflight` deduplica cálculos concurrentes.
@MainActor
enum EnrichCache {
    static var results: [String: EnrichedSuggestion] = [:]
    static var inflight: [String: Task<EnrichedSuggestion?, Never>] = [:]
    /// La clave incluye si la petición aportó CONTENIDO de la página: una sugerencia
    /// fundamentada en el contenido (`c1`) es mejor y NO debe servirse desde una
    /// precalentada sin contenido (`c0`), ni al revés. Así conviven ambas sin pisarse.
    static func key(_ url: String, _ lang: String, _ hasContent: Bool = false) -> String {
        "\(lang)|\(hasContent ? "c1" : "c0")|\(url.trimmingCharacters(in: .whitespaces).lowercased())"
    }
}

@MainActor
struct UnifiedAIService {
    let provider: String   // "apple" | "liquid"

    /// Carga el modelo Liquid en memoria si está descargado pero aún no cargado, para
    /// que «Sugerir con IA»/auto-organizar funcionen sin tener que abrir antes el chat.
    /// Si no está descargado, no hace nada (el llamador lanzará liquidNotLoaded).
    static func ensureLiquidLoaded() async {
        let runner = LocalAIRunner.shared
        // Si el usuario desactivó la IA local («Descargar de la memoria»), no la
        // autocargamos: el llamador lanzará liquidNotLoaded y se mostrará el aviso de
        // «Carga el modelo en Ajustes › IA».
        guard runner.modelContainer == nil, runner.isDownloaded, !runner.isDeactivated else { return }
        _ = await runner.ensureReady()
    }

    /// Enriquecido COMPLETO en una sola llamada: mejora el título, redacta una
    /// descripción rica, propone categoría (reutiliza o crea) y etiquetas, TODO
    /// traducido al idioma `language` ("es"/"en"). Una sola pasada de razonamiento.
    ///
    /// CACHÉ: el resultado se cachea por (idioma + URL). Si la sugerencia ya se
    /// precalculó en segundo plano (al escribir la URL), aquí se devuelve AL INSTANTE.
    /// Llamadas concurrentes a la misma URL comparten la misma tarea (no se duplica).
    func enrich(url: String, pageTitle: String?, pageDescription: String?,
                siteName: String?, existingCategories: [String],
                language: String, pageContent: String? = nil,
                existingTags: [String] = []) async throws -> EnrichedSuggestion {
        // Para Liquid: asegura el modelo cargado y da un mensaje claro si no se puede.
        if provider == "liquid" {
            await Self.ensureLiquidLoaded()
            guard LocalAIRunner.shared.modelContainer != nil else { throw UnifiedAIError.liquidNotLoaded }
        }
        let hasContent = (pageContent?.isEmpty == false)
        let key = EnrichCache.key(url, language, hasContent)
        if let cached = EnrichCache.results[key] { return cached }

        let task: Task<EnrichedSuggestion?, Never>
        if let existing = EnrichCache.inflight[key] {
            task = existing   // ya se está calculando (p. ej. precalentado): reutilízalo.
        } else {
            let provider = self.provider
            task = Task { @MainActor in
                await UnifiedAIService.computeEnrich(
                    provider: provider, url: url, pageTitle: pageTitle,
                    pageDescription: pageDescription, siteName: siteName,
                    existingCategories: existingCategories, language: language,
                    pageContent: pageContent, existingTags: existingTags)
            }
            EnrichCache.inflight[key] = task
        }
        let result = await task.value
        // Cachea el resultado ANTES de soltar la tarea en vuelo: así una llamada
        // posterior con la misma clave encuentra siempre la caché o la tarea, nunca un
        // hueco que dispare una segunda inferencia del modelo local.
        if let result { EnrichCache.results[key] = result }
        EnrichCache.inflight[key] = nil
        guard let result else { throw UnifiedAIError.liquidFailed }
        return result
    }

    /// Cálculo real del enriquecido (sin caché). Devuelve nil si falla.
    static func computeEnrich(provider: String, url: String, pageTitle: String?,
                              pageDescription: String?, siteName: String?,
                              existingCategories: [String], language: String,
                              pageContent: String? = nil,
                              existingTags: [String] = []) async -> EnrichedSuggestion? {
        if provider == "liquid" {
            await ensureLiquidLoaded()
            guard LocalAIRunner.shared.modelContainer != nil else { return nil }
            return await LiquidAIService.enrich(
                url: url, pageTitle: pageTitle, pageDescription: pageDescription,
                siteName: siteName, existingCategories: existingCategories,
                language: language, pageContent: pageContent, existingTags: existingTags)
        }
        guard let s = try? await AIService().suggestion(
            url: url, pageTitle: pageTitle, pageDescription: pageDescription, siteName: siteName)
        else { return nil }
        let c = try? await AIService().classify(
            url: url, title: s.title, description: pageDescription, existingCategories: existingCategories)
        return EnrichedSuggestion(title: s.title, summary: s.summary,
                                  category: c?.category ?? "", tags: c?.tags ?? s.tags)
    }

    /// Precalcula y cachea la sugerencia en segundo plano (sin aplicar nada), para que
    /// al pulsar «Sugerir con IA» el resultado ya esté listo. Solo arranca si el modelo
    /// ya está cargado (no carga 4.8 GB especulativamente). No bloquea ni lanza.
    static func prewarm(url: String, pageTitle: String?, pageDescription: String?,
                        siteName: String?, existingCategories: [String],
                        provider: String, language: String) {
        guard provider != "liquid" || LocalAIRunner.shared.modelContainer != nil else { return }
        let key = EnrichCache.key(url, language)
        guard EnrichCache.results[key] == nil, EnrichCache.inflight[key] == nil else { return }
        // Prioridad BAJA: la inferencia en 2.º plano cede CPU/GPU al renderizado de la
        // UI, así la navegación sigue fluida mientras se precalienta la sugerencia.
        let task = Task(priority: .utility) { @MainActor in
            await computeEnrich(provider: provider, url: url, pageTitle: pageTitle,
                                pageDescription: pageDescription, siteName: siteName,
                                existingCategories: existingCategories, language: language)
        }
        EnrichCache.inflight[key] = task
        Task(priority: .utility) { @MainActor in
            let result = await task.value
            EnrichCache.inflight[key] = nil
            if let result { EnrichCache.results[key] = result }
        }
    }

    func suggestion(url: String, pageTitle: String?, pageDescription: String?,
                    siteName: String?) async throws -> LinkSuggestion {
        if provider == "liquid" {
            await Self.ensureLiquidLoaded()
            guard LocalAIRunner.shared.modelContainer != nil else { throw UnifiedAIError.liquidNotLoaded }
            guard let result = await LiquidAIService.suggestion(
                url: url, pageTitle: pageTitle, pageDescription: pageDescription, siteName: siteName)
            else { throw UnifiedAIError.liquidFailed }
            return result
        }
        return try await AIService().suggestion(
            url: url, pageTitle: pageTitle, pageDescription: pageDescription, siteName: siteName)
    }

    func classify(url: String, title: String, description: String?,
                  existingCategories: [String]) async throws -> LinkClassification {
        if provider == "liquid" {
            await Self.ensureLiquidLoaded()
            guard LocalAIRunner.shared.modelContainer != nil else { throw UnifiedAIError.liquidNotLoaded }
            guard let result = await LiquidAIService.classify(
                url: url, title: title, description: description, existingCategories: existingCategories)
            else { throw UnifiedAIError.liquidFailed }
            return result
        }
        return try await AIService().classify(
            url: url, title: title, description: description, existingCategories: existingCategories)
    }
}

/// Sugerencias/clasificación con el modelo local de Liquid (LFM2.5), pidiendo
/// JSON y parseándolo de forma tolerante. Devuelve nil si no hay modelo o el
/// resultado no es parseable (el llamador recurrirá a Apple).
enum LiquidAIService {

    static func suggestion(url: String, pageTitle: String?, pageDescription: String?,
                           siteName: String?) async -> LinkSuggestion? {
        let system = """
        Organizas marcadores web. Piensa MUY brevemente y termina con UN objeto JSON \
        válido (sin markdown) con estas claves:
        - "title": un título corto y limpio,
        - "summary": 1 frase fiel a la descripción (no inventes nada),
        - "tags": array de 2 a 5 etiquetas en minúscula.
        NO cuentes caracteres ni palabras. Básate SOLO en los datos. El JSON va al \
        final, después de tu razonamiento. Responde en español.
        """
        let prompt = """
        Sitio: \(siteName ?? "(desconocido)")
        Título: \(pageTitle ?? "(ninguno)")
        Descripción: \(pageDescription ?? "(ninguna)")
        URL: \(url)
        """
        // Salida estructurada (JSON): sin razonamiento (enableThinking: false) para
        // que sea rápido — no hace falta cadena de pensamiento para una sugerencia.
        let raw = await LocalAIRunner.shared.complete(system: system, prompt: prompt, maxTokens: 2048, enableThinking: false)
        AgentDiagnostics.shared.log("SUGGESTION: chars=\(raw?.count ?? -1)")
        guard let raw,
              let data = extractJSONObject(raw),
              let dto = try? JSONDecoder().decode(SuggestionDTO.self, from: data),
              let title = dto.title, !title.isEmpty else { return nil }
        return LinkSuggestion(
            title: String(title.prefix(80)),
            summary: dto.summary ?? "",
            tags: TagSanitizer.cleanList(dto.tags ?? [], limit: 5))
    }

    static func classify(url: String, title: String, description: String?,
                         existingCategories: [String]) async -> LinkClassification? {
        let cats = existingCategories.isEmpty
            ? "(no hay; propón una breve)" : existingCategories.joined(separator: ", ")
        let system = """
        Clasificas un marcador: eliges su categoría y 2-4 etiquetas. Reutiliza una \
        categoría existente si encaja; si no, propón una breve. Piensa MUY brevemente.
        Termina tu respuesta con SOLO este objeto JSON y NADA más después \
        (etiquetas en minúscula, en español), rellenando con datos REALES del marcador \
        (no copies estos placeholders):
        {"category": "<colección, en singular>", "tags": ["<tema>", "<tecnología>", "<tipo>"]}
        NO cuentes caracteres ni palabras.
        """
        let prompt = """
        Título: \(title)
        Descripción: \(description ?? "(ninguna)")
        URL: \(url)
        Categorías existentes: \(cats)
        """
        let raw = await LocalAIRunner.shared.complete(system: system, prompt: prompt, maxTokens: 2560, enableThinking: false)
        AgentDiagnostics.shared.log("CLASSIFY: chars=\(raw?.count ?? -1)")
        guard let raw,
              let data = extractJSONObject(raw),
              let dto = try? JSONDecoder().decode(ClassificationDTO.self, from: data),
              let category = dto.category, !category.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return LinkClassification(
            category: category.trimmingCharacters(in: .whitespaces),
            tags: (dto.tags ?? []).map { $0.lowercased() }.prefix(4).map { $0 })
    }

    /// Enriquecido completo en UNA pasada: título mejorado + descripción rica +
    /// categoría + etiquetas, TODO en el idioma indicado (traduce si hace falta).
    static func enrich(url: String, pageTitle: String?, pageDescription: String?,
                       siteName: String?, existingCategories: [String],
                       language: String, pageContent: String? = nil,
                       existingTags: [String] = []) async -> EnrichedSuggestion? {
        let lang = language == "en" ? "English" : "español"
        // EJEMPLO de FORMATO con PLACEHOLDERS GENÉRICOS (no contenido real). CLAVE: un modelo
        // pequeño COPIA un ejemplo concreto y memorable cuando duda → un ejemplo tipo «Wild Sky
        // Guardians en Steam» se filtraba como TÍTULO de enlaces que no tenían nada que ver
        // (openscreen, pdfx → «Guardias de cielo»). Con placeholders abstractos no hay nada
        // copiable: el modelo entiende la ESTRUCTURA y el NIVEL DE DETALLE sin un nombre que calcar.
        let example = language == "en"
            ? "{\"title\": \"<clear, specific name of the resource, no site noise>\", \"summary\": \"<four to six sentences in English: what it is, what it offers or is about, its key features, and who or what it is for; faithful to the real content, no invented data or figures>\", \"category\": \"<best collection, singular>\", \"tags\": [\"<topic>\", \"<technology>\", \"<type>\"]}"
            : "{\"title\": \"<nombre claro y específico del recurso, sin ruido del sitio>\", \"summary\": \"<de cuatro a seis frases en español: qué es, qué ofrece o de qué trata, sus características o puntos clave y para quién o para qué sirve; fiel al contenido real, sin inventar datos ni cifras>\", \"category\": \"<mejor colección, en singular>\", \"tags\": [\"<tema>\", \"<tecnología>\", \"<tipo>\"]}"
        let cats = existingCategories.isEmpty
            ? "(no hay; propón una breve)" : existingCategories.joined(separator: ", ")
        let tagsLine = existingTags.isEmpty
            ? "(no hay todavía)" : existingTags.prefix(40).joined(separator: ", ")
        // Contenido REAL de la página (extraído del artículo) como fuente principal del
        // resumen. Si no hay (fallo de red, paywall, etc.), el modelo se apoya en la
        // descripción original. Lo capamos para no inflar el contexto del modelo local.
        let trimmedContent = (pageContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = trimmedContent.count >= 80
        let contentBlock = hasContent
            ? "Contenido de la página (FUENTE PRINCIPAL del resumen, fiel a esto):\n\(String(trimmedContent.prefix(3500)))"
            : "Contenido de la página: (no disponible; básate en la descripción original)"
        let sourceRule = hasContent
            ? "Para el \"summary\", BÁSATE EN EL CONTENIDO DE LA PÁGINA que te doy abajo; es la fuente fiable. Resume lo que de verdad dice, sin inventar datos ni cifras."
            : "Para el \"summary\", básate en el título y la descripción; sé fiel y NO inventes datos ni cifras."
        let system = """
        Eres un bibliotecario que cataloga enlaces.

        IDIOMA OBLIGATORIO: summary, category y tags DEBEN estar EN \(lang). Si la página \
        está en otro idioma, TRADÚCELOS a \(lang).

        \(sourceRule)

        Genera:
        - "title": el título mejorado, claro y específico, FIEL al recurso real (NUNCA \
        inventes un nombre que no aparezca en los datos). CONSERVA SIN TRADUCIR los \
        NOMBRES PROPIOS (marca, producto, app, librería, juego, sitio web); traduce SOLO \
        las palabras DESCRIPTIVAS que los rodean (una coletilla como «on Steam» o «free \
        tool» pasa a «en Steam» o «herramienta gratis», pero el nombre en sí NUNCA se \
        traduce). Para un repositorio «owner/repo», conserva esa forma tal cual. QUITA el \
        ruido: sufijos del sitio (« - YouTube», «| GitHub»), coletillas de marketing, \
        emojis y cebos de clic. Que identifique el contenido de un vistazo.
        - "summary": una descripción EXTENSA, rica e informativa de 4 a 6 frases EN \(lang). \
        Explica bien: QUÉ es, QUÉ ofrece o de qué trata, sus características o puntos clave, \
        y para QUIÉN o para qué sirve. Da contexto útil a partir del contenido. Fiel a la \
        página (no inventes datos ni cifras). Describe SOLO el contenido: NO añadas frases \
        meta sobre el propio resumen («esta descripción…», «este resumen…») ni te dirijas \
        al lector. Igual que en el título, CONSERVA SIN TRADUCIR los NOMBRES PROPIOS \
        (marcas, empresas, productos, apps, librerías): p. ej. «Point-Free» se queda \
        «Point-Free», NUNCA «PuntoLibre»; «Swift» nunca «Rápido».
        - "category": la mejor colección EN \(lang). PRIORIZA REUTILIZAR una de las \
        existentes si encaja por SIGNIFICADO (aunque el nombre no sea idéntico: «Gaming» \
        ≈ «Videojuegos»); usa el nombre EXACTO de la existente. Solo propón una nueva si \
        de verdad ninguna encaja: breve, general y en singular (p. ej. «Diseño», no \
        «enlaces de diseño que guardé»).
        - "tags": de 3 a 5 etiquetas EN \(lang), en minúscula, de UNA o dos palabras, que \
        sean CONCEPTOS REALES del contenido (tema, tecnología, tipo). PRIORIZA REUTILIZAR \
        las etiquetas EXISTENTES que te doy si encajan (usa su MISMO nombre exacto); crea \
        nuevas solo si de verdad faltan. PROHIBIDO inventar etiquetas sin valor o genéricas \
        («7 días», «tabla», «web», «página», «online»), números, fechas, y nombres propios \
        que ya están en el título.

        Termina con SOLO este objeto JSON y NADA más después. El "summary" del ejemplo \
        muestra el nivel de detalle y extensión esperados:
        \(example)
        NO cuentes caracteres ni palabras.
        """
        let prompt = """
        Sitio: \(siteName ?? "(desconocido)")
        Título original: \(pageTitle ?? "(ninguno)")
        Descripción original: \(pageDescription ?? "(ninguna)")
        URL: \(url)
        Categorías existentes: \(cats)
        Etiquetas existentes (REUTILIZA las que encajen): \(tagsLine)

        \(contentBlock)

        Recuerda: devuelve el JSON con title, summary, category y tags EN \(lang) \
        (traducido si la página está en otro idioma).
        """
        // Salida estructurada (JSON con título + descripción + categoría + etiquetas):
        // sin razonamiento (enableThinking: false) → rápido. No necesita pensar para
        // rellenar el formulario; antes generaba miles de tokens de <think> inútiles.
        let raw = await LocalAIRunner.shared.complete(system: system, prompt: prompt, maxTokens: 4096, enableThinking: false)
        AgentDiagnostics.shared.log("ENRICH(\(lang)): chars=\(raw?.count ?? -1)")
        guard let raw,
              let data = extractJSONObject(raw),
              let dto = try? JSONDecoder().decode(EnrichDTO.self, from: data) else { return nil }
        let title = (dto.title ?? pageTitle ?? "").trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return EnrichedSuggestion(
            title: String(title.prefix(120)),
            summary: (dto.summary ?? "").trimmingCharacters(in: .whitespaces),
            category: (dto.category ?? "").trimmingCharacters(in: .whitespaces),
            tags: TagSanitizer.cleanList(dto.tags ?? [], limit: 5))
    }

    /// Traduce `text` al idioma `language` ("es"/"en") con el modelo Liquid local.
    /// Conserva los nombres propios. Devuelve nil si el modelo no está disponible o
    /// no produce salida. Pensado para traducir descripciones de «Descubrir» al vuelo.
    static func translate(_ text: String, to language: String) async -> String? {
        await UnifiedAIService.ensureLiquidLoaded()
        guard await LocalAIRunner.shared.modelContainer != nil else { return nil }
        let target = language == "en" ? "English" : "español"
        let system = """
        Eres un traductor profesional. Traduce el TEXTO del usuario a \(target), de forma \
        natural y fiel. CONSERVA SIN TRADUCIR los nombres propios (marcas, productos, \
        repositorios, tecnologías, nombres de usuario). Responde ÚNICAMENTE con la \
        traducción: sin comillas, sin notas, sin el texto original, sin explicaciones.
        """
        let raw = await LocalAIRunner.shared.complete(
            system: system, prompt: text, maxTokens: 1200, enableThinking: false)
        guard let raw else { return nil }
        let answer = afterThinking(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.isEmpty ? nil : answer
    }

    /// Extrae 3-5 PUNTOS CLAVE del texto de un artículo (para resaltados automáticos), en
    /// el idioma indicado. Devuelve cada punto como una frase concisa y autocontenida. Es
    /// extractivo/sintético sobre el CONTENIDO real; si no hay nada aprovechable, `nil`.
    static func keyPoints(from text: String, language: String) async -> [String]? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.count >= 120 else { return nil }
        await UnifiedAIService.ensureLiquidLoaded()
        guard await LocalAIRunner.shared.modelContainer != nil else { return nil }
        let target = language == "en" ? "English" : "español"
        let system = """
        Extrae los PUNTOS CLAVE del texto del usuario. Devuelve EXCLUSIVAMENTE una lista de \
        entre 3 y 5 viñetas, sin nada más. Formato OBLIGATORIO:
        - <idea 1>
        - <idea 2>
        Reglas: escribe SIEMPRE en \(target) (traduce si el texto está en otro idioma). Cada \
        viñeta es una frase concisa y autocontenida (máx. ~160 caracteres), fiel al texto, sin \
        inventar nada. NO numeres. NO escribas introducción, cierre, ni repitas estas \
        instrucciones. Empieza directamente por «- ».
        """
        let raw = await LocalAIRunner.shared.complete(
            system: system, prompt: String(source.prefix(6000)), maxTokens: 700, enableThinking: false)
        guard let raw else { return nil }
        let answer = afterThinking(raw)
        let lines = answer.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        // Solo las líneas con viñeta son puntos reales: así se descarta cualquier preámbulo o
        // eco del prompt que el modelo añada antes de la lista. Si no usó viñetas, se cae a
        // todas las líneas (y el filtro de meta-frases las depura igualmente).
        let bulleted = lines.filter { ($0.first).map { "-•*–—".contains($0) } ?? false }
        let candidates = bulleted.isEmpty ? lines : bulleted
        // Frases que delatan que la línea es meta (instrucciones/razonamiento), no contenido.
        let metaMarkers = ["key point", "puntos clave", "we need", "provide only", "the list",
                           "cada línea", "cada viñeta", "each line", "intro or closing",
                           "una lista", "a list of", "here are", "aquí están", "aquí tienes"]
        let points = candidates
            .map { line -> String in
                var s = line
                while let first = s.first, "-•*–—".contains(first) { s.removeFirst(); s = s.trimmingCharacters(in: .whitespaces) }
                if let dot = s.firstIndex(where: { $0 == "." || $0 == ")" }),
                   s.distance(from: s.startIndex, to: dot) <= 2,
                   !s[s.startIndex..<dot].isEmpty,
                   s[s.startIndex..<dot].allSatisfy(\.isNumber) {
                    s = String(s[s.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
                }
                return s
            }
            .filter { p in
                let low = p.lowercased()
                return p.count >= 12 && !metaMarkers.contains { low.contains($0) }
            }
        return points.isEmpty ? nil : Array(points.prefix(5))
    }

    private struct EnrichDTO: Decodable { let title: String?; let summary: String?; let category: String?; let tags: [String]? }
    private struct SuggestionDTO: Decodable { let title: String?; let summary: String?; let tags: [String]? }
    private struct ClassificationDTO: Decodable { let category: String?; let tags: [String]? }

    /// Devuelve el texto posterior al último `</think>` (la respuesta real, sin el
    /// razonamiento). Si no hay cierre, devuelve el texto tal cual.
    static func afterThinking(_ text: String) -> String {
        if let lastClose = text.range(of: "</think>", options: .backwards) {
            return String(text[lastClose.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// Extrae el objeto JSON `{…}` balanceado de la respuesta del modelo. El JSON va
    /// DESPUÉS del razonamiento, así que se descarta todo hasta el ÚLTIMO `</think>`,
    /// se quitan los fences de markdown, y se busca el último `{…}` balanceado.
    static func extractJSONObject(_ text: String) -> Data? {
        var s = text
        // Todo lo que va tras el último cierre de razonamiento es la respuesta real.
        if let lastClose = s.range(of: "</think>", options: .backwards) {
            s = String(s[lastClose.upperBound...])
        }
        // Quita fences de markdown (```json … ```).
        s = s.replacingOccurrences(of: "```json", with: " ")
            .replacingOccurrences(of: "```", with: " ")
        guard let start = s.firstIndex(of: "{") else { return nil }
        var depth = 0
        var idx = start
        var end: String.Index?
        while idx < s.endIndex {
            let c = s[idx]
            if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0 { end = idx; break } }
            idx = s.index(after: idx)
        }
        guard let end else { return nil }
        return String(s[start...end]).data(using: .utf8)
    }
}
