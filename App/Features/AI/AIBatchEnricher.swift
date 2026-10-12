import Foundation
import SwiftData
import AppKit
import StacklumeCore
import StacklumeMetadata

/// Enriquecido en lote CON IA: además de los metadatos de red, usa el motor de IA
/// activo (en Mac, el modelo Liquid local) para mejorar el título, redactar
/// una descripción rica y proponer categoría + etiquetas. Rellena SOLO los huecos
/// (no pisa el título, descripción, colección o etiquetas que el usuario ya puso) y
/// reutiliza/deduplica colecciones y etiquetas por nombre, así que no crea
/// duplicados a lo largo del lote.
@MainActor
enum AIBatchEnricher {

    /// Enlaces que están enriqueciéndose AHORA mismo vía `enrichOne` (alta sin editor o
    /// botón «Mejorar con IA»). Evita procesar el mismo enlace dos veces a la vez (doble
    /// fetch de red + doble inferencia), p. ej. al añadirlo y pulsar «Mejorar con IA»
    /// enseguida. Aislado en `@MainActor`, sin carrera.
    private static var enrichingIDs: Set<PersistentIdentifier> = []

    /// ¿La salida de la IA es una META-RESPUESTA / no-respuesta («No se proporcionó descripción…»,
    /// «no es posible…», «como modelo de IA…») en vez de una descripción real? El usuario lo vio
    /// guardado como descripción. NUNCA debe almacenarse: es ruido, no contenido.
    static func isMetaNonAnswer(_ text: String) -> Bool {
        let t = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Frases de no-respuesta FUERTES (auto-referencia del modelo o «no hay info»). Solo cuentan
        // si están al PRINCIPIO (primeros 90 chars) o si TODO el texto es corto: un «no se
        // proporcionan más detalles» al FINAL de una descripción real NO la rechaza (verificado con
        // casos reales como «…publicada como modelo de Civitai/Stable Diffusion»).
        let strong = [
            "no se proporciono informacion", "no se proporciono descripcion",
            "no se proporciona informacion", "no se proporciona descripcion",
            "no se ha proporcionado informacion", "resumen: no se proporciono",
            "no es posible generar un resumen", "no es posible ofrecer una descripcion",
            "no es posible generar una descripcion", "no es posible proporcionar una descripcion",
            "no hay informacion suficiente", "no se dispone de contenido",
            "no se puede generar un resumen", "no tengo informacion suficiente",
            "como modelo de lenguaje", "como modelo de ia", "como asistente de ia",
            "lo siento, no puedo", "lo siento, pero no",
        ]
        let head = String(t.prefix(90))
        if strong.contains(where: { head.contains($0) }) { return true }
        if t.count < 160, strong.contains(where: { t.contains($0) }) { return true }
        return false
    }

    /// Un enlace se puede mejorar con IA si le falta un buen título, descripción,
    /// colección o etiquetas.
    static func needsAIEnrichment(_ link: Bookmark) -> Bool {
        guard link.fileKind == nil else { return false }
        let title = link.title.trimmingCharacters(in: .whitespaces)
        // Un título/descripción EDITADOS a mano nunca cuentan como «pendientes» (no se reprocesan).
        let titleEdited = UserEditLedger.isTitleEdited(link.id)
        let detailsEdited = UserEditLedger.isDetailsEdited(link.id)
        return (!titleEdited && (title.isEmpty
            || title.lowercased() == link.url.urlHost.lowercased()
            // Título ALUCINADO/ajeno al enlace (se vio «Wild Sky Guardians en Steam» para un
            // repo de GitHub): hay que reprocesarlo para refrescar el título real y limpiar la
            // descripción que ese título falso contaminó. Antes el gate lo daba por «completo».
            || TitleCoherence.titleLikelyUnrelated(title: title, url: link.url)))
            // La DESCRIPCIÓN debe acabar SIEMPRE rica y en español (salvo que la editaras tú). No
            // basta con que «no esté vacía»: la `og:description` CRUDA (corta, a menudo en inglés)
            // dejaba el enlace «completo» a ojos del gate → la IA nunca lo tocaba.
            // `needsSpanishDescription` la marca si está VACÍA, CORTA o en OTRO IDIOMA.
            || (!detailsEdited && needsSpanishDescription(link))
            || link.category == nil
            || link.tags.isEmpty
    }

    /// ¿La DESCRIPCIÓN (`details`) necesita (re)generarse en español? Sí si falta, es muy corta
    /// (las `og:description` a veces se quedan cortas → el usuario quiere enriquecerlas) o está
    /// en otro idioma (debe quedar en español). NO mira el título: los nombres en inglés se
    /// RESPETAN (decisión del usuario). Reutiliza la detección de [[LinkTranslator]].
    static func needsSpanishDescription(_ link: Bookmark) -> Bool {
        let d = (link.details ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if d.isEmpty { return true }
        if d.count < 140 { return true }                       // corta → enriquecer
        return LinkTranslator.isForeignDescription(d)          // otro idioma → a español
    }

    /// Regenera SOLO la descripción (`details`) en ESPAÑOL, fundamentada en el contenido REAL de
    /// la página (así «traduce» desde cualquier idioma Y enriquece las que se quedaban cortas, en
    /// un solo paso). NO toca título/colección/etiquetas. Devuelve `true` si la actualizó.
    @discardableResult
    static func regenerateDescription(
        _ link: Bookmark, in context: ModelContext, provider: String, language: String
    ) async -> Bool {
        guard link.modelContext != nil else { return false }
        guard !UserEditLedger.isDetailsEdited(link.id) else { return false }   // descripción tuya
        let pid = link.persistentModelID
        guard !enrichingIDs.contains(pid) else { return false }
        enrichingIDs.insert(pid)
        defer { enrichingIDs.remove(pid) }

        let service = UnifiedAIService(provider: provider)
        let pageContent = await Self.pageContentExcerpt(for: link.url)
        guard link.modelContext != nil else { return false }
        // BLINDAJE anti-alucinación: sin contenido REAL de la página NO se regenera la descripción
        // (el modelo inventaría algo ajeno al enlace). Mejor sin descripción IA que una falsa.
        guard let pageContent, !pageContent.isEmpty else { return false }
        guard let result = try? await service.enrich(
            url: link.url,
            pageTitle: link.title.isEmpty ? nil : link.title,
            pageDescription: (link.details?.isEmpty == false) ? link.details : nil,
            siteName: link.siteName,
            existingCategories: [],
            language: language,
            pageContent: pageContent,
            existingTags: []),
            link.modelContext != nil,
            !result.summary.trimmingCharacters(in: .whitespaces).isEmpty,
            !isMetaNonAnswer(result.summary) else { return false }
        // Solo la descripción; el título (nombre) se respeta tal cual.
        link.details = result.summary
        link.updatedAt = Date()
        SpotlightIndexer.index(link)
        context.saveLogging()
        return true
    }

    /// Enriquece en lote. Devuelve cuántos enlaces se mejoraron. Respeta la
    /// cancelación de la tarea (para poder detenerlo o cederlo en segundo plano).
    ///
    /// - Parameter collectionScope: si no es nil, solo se enriquecen los enlaces
    ///   cuya `category?.id` pertenezca a este conjunto (colección + descendientes).
    ///   Si es nil (por defecto), se procesan todos los enlaces de la biblioteca.
    /// - Parameter ignoreLedger: si es `false` (barrido AUTOMÁTICO de fondo) se SALTAN los
    ///   enlaces que ya pasaron por la IA alguna vez (ver [[EnrichmentLedger]]), para no
    ///   reprocesar en cada arranque lo ya intentado. Si es `true` (acciones MANUALES:
    ///   «Auto-Organizar», Mantenimiento, enriquecer una colección) se reprocesan también.
    ///   En ambos casos cada enlace procesado queda marcado en el libro mayor.
    @discardableResult
    static func enrich(
        in context: ModelContext,
        provider: String,
        language: String,
        limit: Int = 200,
        collectionScope: Set<UUID>? = nil,
        ignoreLedger: Bool = false,
        force: Bool = false,
        renderIfEmpty: Bool = false,
        respectActivityGate: Bool = true,
        onProgress: @MainActor (Int, Int) -> Void = { _, _ in }
    ) async -> Int {
        if respectActivityGate, MenuBarController.shared.isMenuBarOnly { return 0 }
        let all = (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
        // `force` = pasa por TODOS los enlaces (re-enriquece a fondo), ignorando el gate y el
        // ledger. Si no, solo los que necesitan IA y no se han intentado (salvo ignoreLedger).
        var pending = all.filter {
            $0.deletedAt == nil
                && $0.fileKind == nil
                && (force || needsAIEnrichment($0))
                && (force || ignoreLedger || !EnrichmentLedger.hasAIAttempt($0.id))
        }
        if let scope = collectionScope {
            pending = pending.filter { link in
                guard let catID = link.category?.id else { return false }
                return scope.contains(catID)
            }
        }
        let slice = Array(pending.prefix(limit))
        guard !slice.isEmpty else { return 0 }

        let service = UnifiedAIService(provider: provider)
        // Cachés find-or-create por nombre normalizado, PRECARGADAS una sola vez con lo
        // existente (evita un fetch por cada nombre nuevo). El contexto no “ve” lo recién
        // insertado al instante, así que sin esto cada enlace con la misma categoría/
        // etiqueta nueva crearía un duplicado. Unifica todo el lote en una sola entidad.
        var catCache: [String: BookmarkCategory] = [:]
        for c in (((try? context.fetch(FetchDescriptor<BookmarkCategory>())) ?? [])
            .filter { $0.deletedAt == nil }) {
            catCache[CollectionMerger.canonical(c.name)] = c
        }
        var tagCache: [String: Tag] = [:]
        for t in ((try? context.fetch(FetchDescriptor<Tag>())) ?? []).filter({ $0.deletedAt == nil }) {
            tagCache[EntityResolver.tagKey(t.name)] = t
        }
        var existingCatNames = Set(catCache.values.map(\.name))

        var done = 0, enriched = 0
        for link in slice {
            if Task.isCancelled { break }
            // APLAZA el enriquecido MLX mientras la app está EN PRIMER PLANO y la estás usando: el
            // modelo (carga de ~GB + compilación de shaders Metal + inferencia) SATURA la GPU, y el
            // render de la UI —que también necesita la GPU— se queda esperando detrás → scroll/clic/
            // búsqueda/preview se entrecortan. Como una inferencia (o la carga del modelo) en curso
            // NO se puede interrumpir, una puerta de pocos segundos no basta: arrancaba justo al
            // hacer una pausa y entrecortaba al volver. Por eso SOLO enriquecemos cuando la app está
            // en SEGUNDO PLANO (cambiaste a otra app) o tras un largo rato de inactividad en primer
            // plano. Así NUNCA se nota usándola; la organización avanza en cuanto la dejas o la
            // cambias. No rompe nada: solo retrasa el trabajo de fondo, no lo cancela.
            // El botón MANUAL («Enriquecer biblioteca») salta esta puerta (respectActivityGate=
            // false): es una acción explícita del usuario, que ESPERA el resultado; pausarla por
            // estar en primer plano lo dejaría «sin avanzar». La puerta solo aplica al barrido de fondo.
            while respectActivityGate,
                  UserActivityMonitor.shared.shouldPauseHeavyBackgroundWork {
                if Task.isCancelled { context.saveLogging(); return enriched }
                try? await Task.sleep(for: .seconds(2))
            }
            // Guarda anti-crash: si el enlace se borró antes de esta iteración
            // (modelContext == nil), no lo toques (mismo patrón que enrichOne).
            guard link.modelContext != nil else { done += 1; onProgress(done, slice.count); continue }
            // 1) Metadatos de red (imagen, nombre del sitio, plataforma; título si vacío).
            //    Refresca el título real (`og:title`) si está vacío, es el host, con `force`, o
            //    si el título guardado es ALUCINADO/ajeno al enlace ([[TitleCoherence]]): así un
            //    «Wild Sky Guardians en Steam» en un repo recupera su «owner/repo» real.
            // Un título EDITADO a mano no se refresca de red ni se considera «ajeno» ([[UserEditLedger]]).
            let titleEdited = UserEditLedger.isTitleEdited(link.id)
            let titleWasUnrelated = !titleEdited
                && TitleCoherence.titleLikelyUnrelated(title: link.title, url: link.url)
            let overwriteTitle = !titleEdited && (force || link.title.isEmpty
                || link.title.lowercased() == link.url.urlHost.lowercased()
                || titleWasUnrelated)
            await MacLinkEnricher.enrichFromNetwork(link, in: context, overwriteTitle: overwriteTitle)
            guard link.modelContext != nil else { done += 1; onProgress(done, slice.count); continue }

            // 1.5) Contenido REAL de la página para fundamentar el resumen de la IA. Si el HTML
            // estático no da prosa (SPA/JS) y `renderIfEmpty`, RENDERIZA la página para obtener el
            // texto real → la descripción SIEMPRE se puede generar (no dejar ningún enlace sin enriquecer).
            var pageContent = await Self.pageContentExcerpt(for: link.url)
            if renderIfEmpty, (pageContent?.isEmpty ?? true), link.modelContext != nil {
                pageContent = await LibraryCompleter.renderAndApplyMeta(link)
            }
            guard link.modelContext != nil else { done += 1; onProgress(done, slice.count); continue }

            // 2) IA: título mejorado + descripción rica (fiel al contenido) + categoría + etiquetas.
            //    Si el título SIGUE pareciendo ajeno tras el refresco de red (no se pudo recuperar
            //    el real), NO se le pasa al modelo como pista: perpetuaría la alucinación en la
            //    descripción. `regenerateText` limpia el título Y la descripción contaminada (sin
            //    tocar la colección/etiquetas que el usuario tenga).
            let stillUnrelated = TitleCoherence.titleLikelyUnrelated(title: link.title, url: link.url)
            let promptTitle = (link.title.isEmpty || stillUnrelated) ? nil : link.title
            var aiResponded = false
            if let result = try? await service.enrich(
                url: link.url,
                pageTitle: promptTitle,
                pageDescription: (link.details?.isEmpty == false) ? link.details : nil,
                siteName: link.siteName,
                existingCategories: Array(existingCatNames),
                language: language,
                pageContent: pageContent,
                existingTags: tagCache.values.map(\.name)), link.modelContext != nil {
                // Re-comprueba modelContext tras el await de inferencia (segundos):
                // el enlace pudo borrarse durante la IA; escribir en él haría fatalError.
                apply(result, to: link, in: context,
                      catCache: &catCache, tagCache: &tagCache, existingCatNames: &existingCatNames,
                      force: force, grounded: (pageContent?.isEmpty == false),
                      regenerateText: titleWasUnrelated)
                enriched += 1
                aiResponded = true
            }
            // Traduce el título con la IA local si quedó en script no latino (igual que enrichOne).
            // En modo manual/a fondo lo hacemos siempre; el barrido de fondo tiene su propio paso.
            if (force || renderIfEmpty), link.modelContext != nil {
                await translateTitleWithLocalAI(link, language: language)
            }
            // Portada perfecta: si tras la red/IA sigue sin imagen, busca la imagen «hero»
            // del HTML o captura la página renderizada (SPAs). Punto único ([[CoverEnsurer]]).
            if link.modelContext != nil { await CoverEnsurer.ensure(for: link, in: context) }
            // Marca «ya intentado por IA» SOLO si el modelo RESPONDIÓ (aplicara o no): así un fallo
            // TRANSITORIO de inferencia (MLX ocupado/OOM/cancelado → result nil) NO quema el enlace
            // para siempre; el barrido de fondo lo reintentará en el próximo arranque.
            if aiResponded, link.modelContext != nil { EnrichmentLedger.markAIAttempt(link.id) }
            done += 1
            onProgress(done, slice.count)
        }
        context.saveLogging()
        return enriched
    }

    /// Enriquece con IA UN SOLO enlace ya insertado (altas sin editor: arrastrar y
    /// soltar, deep link). Reutiliza EXACTAMENTE el mismo mapeo `EnrichedSuggestion`→
    /// modelo que el lote (`apply`), así que no se duplica la lógica de asignar/crear
    /// colección y etiquetas ni la de rellenar solo los huecos. A diferencia del lote,
    /// NO ejecuta `enrichFromNetwork` (eso lo hace antes el `LinkIngest`), solo la IA.
    /// Las cachés find-or-create se construyen frescas con lo existente para no crear
    /// duplicados de colección/etiqueta con nombres ya presentes en la biblioteca.
    /// Devuelve `true` si la IA produjo una sugerencia y se aplicó.
    @discardableResult
    static func enrichOne(
        _ link: Bookmark,
        in context: ModelContext,
        provider: String,
        language: String,
        force: Bool = false,
        prefetchedContent: String? = nil
    ) async -> Bool {
        // Sin `force` solo actúa si faltan datos; con `force` (botón «Mejorar con IA»)
        // regenera aunque el enlace ya esté completo.
        guard link.fileKind == nil else { return false }
        if !force { guard needsAIEnrichment(link) else { return false } }
        // Reentrada: no enriquezcas el mismo enlace si ya está en curso.
        let pid = link.persistentModelID
        guard !enrichingIDs.contains(pid) else { return false }
        enrichingIDs.insert(pid)
        defer { enrichingIDs.remove(pid) }
        let service = UnifiedAIService(provider: provider)

        var catCache: [String: BookmarkCategory] = [:]
        for c in (((try? context.fetch(FetchDescriptor<BookmarkCategory>())) ?? [])
            .filter { $0.deletedAt == nil }) {
            catCache[CollectionMerger.canonical(c.name)] = c
        }
        var tagCache: [String: Tag] = [:]
        for t in ((try? context.fetch(FetchDescriptor<Tag>())) ?? []).filter({ $0.deletedAt == nil }) {
            tagCache[EntityResolver.tagKey(t.name)] = t
        }
        var existingCatNames = Set(catCache.values.map(\.name))

        // Contenido REAL: si el llamante lo trae (p. ej. el texto RENDERIZADO de una web JS, donde
        // el HTML estático no da prosa), se usa; si no, se extrae del HTML estático. Fundamenta la
        // descripción Y la categoría (sin contenido NO se aplican, para no inventar/categorizar mal).
        let pageContent: String?
        if let prefetchedContent, !prefetchedContent.isEmpty {
            pageContent = prefetchedContent
        } else {
            pageContent = await Self.pageContentExcerpt(for: link.url)
        }
        guard link.modelContext != nil else { return false }

        // Título ALUCINADO/ajeno (ver [[TitleCoherence]]): no se le pasa al modelo como pista
        // (perpetuaría la invención) y se fuerza la regeneración de título + descripción.
        let titleWasUnrelated = TitleCoherence.titleLikelyUnrelated(title: link.title, url: link.url)
        let promptTitle = (link.title.isEmpty || titleWasUnrelated) ? nil : link.title
        guard let result = try? await service.enrich(
            url: link.url,
            pageTitle: promptTitle,
            pageDescription: (link.details?.isEmpty == false) ? link.details : nil,
            siteName: link.siteName,
            existingCategories: Array(existingCatNames),
            language: language,
            pageContent: pageContent,
            existingTags: tagCache.values.map(\.name)) else { return false }

        // Guarda anti-crash: tras el await de inferencia (segundos) el enlace pudo
        // borrarse (modelContext == nil); escribir en un @Model invalidado dispara
        // fatalError de SwiftData. Mismo patrón que LinkRowView/LinkCoverCard.
        guard link.modelContext != nil else { return false }
        apply(result, to: link, in: context,
              catCache: &catCache, tagCache: &tagCache, existingCatNames: &existingCatNames,
              force: force, grounded: (pageContent?.isEmpty == false),
              regenerateText: titleWasUnrelated)
        // Si el TÍTULO quedó en un script no latino (chino/japonés/árabe…), que la PROPIA IA local
        // lo traduzca al idioma de la app aquí mismo (inmediato, sin depender de descargar idiomas
        // del traductor de Apple). Si lo consigue, el título queda en español; si no, sigue foráneo
        // y el motor de Apple ([[AutoTranslateEngine]]) lo traduce — sin solaparse, porque solo actúa
        // cuando AÚN es foráneo.
        if link.modelContext != nil {
            await translateTitleWithLocalAI(link, language: language)
        }
        guard link.modelContext != nil else { return false }
        context.saveLogging()
        // Cuenta como intento de IA (igual que el lote `enrich`): el alta enriquece aquí mismo, así
        // que el barrido automático de fondo NO debe re-procesar este enlace. «Mejorar con IA»
        // (force) también pasa por aquí; marcarlo es correcto (ya quedó enriquecido a mano).
        EnrichmentLedger.markAIAttempt(link.id)
        return true
    }

    /// Traduce SOLO el título de un enlace extranjero con la IA local y GUARDA. Para el barrido de
    /// fondo que pasa al idioma de la app los títulos en script no latino de enlaces YA guardados,
    /// SIN el traductor de Apple (sin descargar idiomas → cero prompts/fricción). Devuelve si tradujo.
    @discardableResult
    static func translateForeignTitle(_ link: Bookmark, in context: ModelContext, language: String) async -> Bool {
        guard link.modelContext != nil, LinkTranslator.isForeign(link.title) else { return false }
        let before = link.title
        await translateTitleWithLocalAI(link, language: language)
        guard link.modelContext != nil, link.title != before else { return false }
        context.saveLogging()
        return true
    }

    /// Traduce el TÍTULO con la IA LOCAL si está en script no latino. Complementa al motor de
    /// traducción de Apple (no se solapan: este actúa primero y, si deja el título en español, el de
    /// Apple ya no lo toca porque `needsTranslation` pasa a `false`). No toca títulos ya latinos ni
    /// acepta un eco del original (si la IA «devuelve» el mismo idioma, se descarta). No cambia el
    /// modelo: usa el mismo Liquid local que el resto.
    private static func translateTitleWithLocalAI(_ link: Bookmark, language: String) async {
        guard LinkTranslator.isForeign(link.title) else { return }
        let original = link.title
        let langName = Locale.current.localizedString(forLanguageCode: language) ?? "español"
        let system = "Eres un traductor profesional. Traduce el título al \(langName). Devuelve SOLO "
            + "el título traducido, en UNA línea, sin comillas ni explicaciones. Conserva nombres "
            + "propios, marcas, rutas tipo «owner/repo» y términos técnicos sin traducirlos."
        guard let raw = await LocalAIRunner.shared.complete(
            system: system, prompt: "Título: \(original)", maxTokens: 160, enableThinking: true) else { return }
        guard link.modelContext != nil else { return }
        let cleaned = cleanTranslatedTitle(raw)
        // Válido solo si NO está vacío, ya NO es script no latino (no es un eco), cambió algo y es
        // una traducción FIEL (no una alucinación del modelo, como «… en Steam» inventado).
        guard !cleaned.isEmpty, !LinkTranslator.isForeign(cleaned), cleaned != original,
              isFaithfulTranslation(cleaned, original: original, url: link.url) else { return }
        link.title = cleaned
        link.updatedAt = Date()
        SpotlightIndexer.index(link)
    }

    /// ¿La «traducción» del modelo es FIEL (no una alucinación)? Un modelo pequeño puede devolver
    /// texto inventado que pasa los filtros básicos (es latino y distinto del original). Rechaza:
    /// longitudes desproporcionadas y la introducción de sufijos de plataforma («en Steam», «en
    /// GitHub»…) que NO están en la URL — justo el patrón del título alucinado «… en Steam».
    private static func isFaithfulTranslation(_ cleaned: String, original: String, url: String) -> Bool {
        if cleaned.count > max(original.count * 6, 120) { return false }
        let host = url.urlHost.lowercased()
        let lower = cleaned.lowercased()
        for p in ["steam", "github", "youtube", "twitter", "reddit", "spotify", "tiktok"]
        where lower.contains(" en \(p)") || lower.contains(" on \(p)") {
            if !host.contains(p) { return false }   // sufijo de plataforma INVENTADO → no es fiel
        }
        return true
    }

    /// Limpia la salida del modelo al traducir un título: quita prefijos («Título:»), comillas
    /// envolventes y cualquier segunda línea (explicación que el modelo pequeño pueda añadir).
    private static func cleanTranslatedTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: #"^(t[íi]tulo|title|traducci[óo]n|translation)\s*[:\-–]\s*"#,
                           options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(r)
        }
        if let nl = s.firstIndex(where: { $0.isNewline }) { s = String(s[..<nl]) }
        // Incluye comillas/apóstrofes TIPOGRÁFICOS (' ' “ ”) que el modelo pone a veces.
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'«»\u{2018}\u{2019}\u{201C}\u{201D}` "))
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extrae un fragmento de TEXTO real de la página (artículo) para fundamentar el
    /// resumen de la IA. Reutiliza `OfflineCopyService` (compartido): descarga el HTML,
    /// extrae el cuerpo legible y lo pasa a texto plano. Devuelve `nil` si la página no
    /// da contenido aprovechable (red caída, paywall, muy corto). Capado a 3500 chars
    /// para no inflar el contexto del modelo local. `internal` para reutilizarlo desde
    /// el editor («Sugerir con IA») sin duplicar la extracción.
    static func pageContentExcerpt(for url: String) async -> String? {
        guard let readable = await MacOfflineCopyService.fetchReadable(url: url) else { return nil }
        let text = OfflineCopyService.plainText(from: readable)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 80 else { return nil }   // demasiado corto → no aporta
        return String(text.prefix(3500))
    }

    /// Aplica la sugerencia al enlace. Por defecto rellena solo los huecos; con
    /// `force == true` (botón «Mejorar con IA» del detalle) REGENERA título y
    /// descripción aunque ya existan, conservando la colección y las etiquetas que el
    /// usuario haya puesto (esas solo se rellenan si faltan).
    private static func apply(
        _ s: EnrichedSuggestion, to link: Bookmark, in context: ModelContext,
        catCache: inout [String: BookmarkCategory], tagCache: inout [String: Tag],
        existingCatNames: inout Set<String>, force: Bool = false, grounded: Bool = true,
        regenerateText: Bool = false
    ) {
        // Título. NUNCA se toca si el usuario lo editó a mano ([[UserEditLedger]]). Si no, BLINDAJE
        // anti-alucinación: solo se acepta el de la IA si está FUNDAMENTADO en contenido REAL.
        if !UserEditLedger.isTitleEdited(link.id) {
            let current = link.title.trimmingCharacters(in: .whitespaces)
            let isHostOrEmpty = current.isEmpty || current.lowercased() == link.url.urlHost.lowercased()
            if let ownerRepo = TitleCoherence.githubOwnerRepo(link.url) {
                // GitHub: título DETERMINISTA (la red pone «owner/repo: descripción» del og:title). El
                // modelo NO decide el título de un repo —inventa la parte descriptiva—. Si la red no
                // trajo el og:title (vacío/host), al menos «owner/repo» real; si ya hay og bueno, se conserva.
                if isHostOrEmpty { link.title = ownerRepo }
            } else if !s.title.isEmpty, grounded, isAcceptableTitle(s.title) {
                // Resto de sitios: si está vacío/es el host, con `force`, o si el título era ajeno
                // (`regenerateText`), usa el de la IA; si ya hay un título OG bueno, solo si es una
                // versión LIMPIA del existente (mismo contenido sin el sufijo del sitio).
                if force || regenerateText || isHostOrEmpty || Self.isCleanedVariant(s.title, of: current) {
                    link.title = s.title
                }
            }
            // Limpieza DETERMINISTA del ruido del sitio: «GitHub - owner/repo: …», «… - YouTube»…
            let cleanedTitle = TitleCleaner.clean(link.title, siteName: link.siteName, host: link.url.urlHost)
            if !cleanedTitle.isEmpty, cleanedTitle != link.title { link.title = cleanedTitle }
        }

        // Descripción: NUNCA se toca si el usuario la editó a mano. Si no, SOLO si está FUNDAMENTADA
        // en contenido real (`grounded`): sin contenido el modelo INVENTARÍA algo ajeno (el usuario
        // lo vio: un OCR descrito como un juego). Mejor SIN descripción IA que una alucinación.
        let currentDetails = (link.details ?? "").trimmingCharacters(in: .whitespaces)
        if !UserEditLedger.isDetailsEdited(link.id),
           grounded, !s.summary.isEmpty, !isMetaNonAnswer(s.summary),
           force || regenerateText || currentDetails.isEmpty
               // En OTRO IDIOMA (inglés de GitHub/HF, etc.) → se sustituye por la española recién
               // generada (fundamentada en el contenido real). Sin esto, la traducción se calculaba
               // pero `apply` no la escribía porque la inglesa no estaba ni vacía ni era «corta».
               || LinkTranslator.isForeignDescription(currentDetails)
               || (currentDetails.count < 200 && s.summary.count >= currentDetails.count + 40) {
            link.details = s.summary
        }
        // Colección. Orden de PRIORIDAD (de más fiable a menos):
        //   1) Regla de dominio DETERMINISTA ([[DomainCategoryRules]]): para dominios conocidos
        //      (huggingface.co → IA, etc.) la colección NO la decide el modelo. No depende de
        //      `grounded` (no necesita contenido) y se aplica también con `force` (corrige una
        //      categoría equivocada al «Mejorar con IA»). Es la garantía de que esos enlaces nunca
        //      se clasifican mal por un nombre llamativo.
        //   2) Sugerencia de la IA: solo con contenido REAL (`grounded`) —sin él adivina por el
        //      nombre (el usuario vio «Islet» → «Videojuegos»)— y solo si resuelve a una colección
        //      válida (nunca se borra la que había por una sugerencia vacía/irresoluble).
        if force || link.category == nil {
            if let domainName = DomainCategoryRules.categoryName(forURL: link.url,
                                                                title: link.title, details: link.details),
               let cat = resolveCategory(domainName, in: context, cache: &catCache, names: &existingCatNames) {
                link.category = cat
            } else if grounded {
                let name = s.category.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty,
                   let cat = resolveCategory(name, in: context, cache: &catCache, names: &existingCatNames) {
                    link.category = cat
                }
            }
        } else if grounded, hasGenericCodeCategory(link) {
            // La colección es la GENÉRICA «Desarrollo» que se pone AUTOMÁTICAMENTE a TODO repo de
            // código. GitHub/GitLab son MULTITEMÁTICOS (un repo puede ser de OCR, IA, web, juegos…):
            // si la IA, con el contenido real, sugiere una colección DISTINTA y más específica,
            // reclasifica (p. ej. `datalab-to/surya`: «Desarrollo»→«OCR»). PRIORIZA reutilizar la
            // colección existente que encaje (el prompt ya lo pide). No toca lo que el usuario movió.
            let name = s.category.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty,
               CollectionMerger.canonical(name) != CollectionMerger.canonical(link.category?.name ?? ""),
               let cat = resolveCategory(name, in: context, cache: &catCache, names: &existingCatNames) {
                link.category = cat
            }
        }
        // Etiquetas: con contenido REAL, la IA AÑADE etiquetas semánticas (tema/tecnología/tipo) del
        // contenido, SIN pisar ni duplicar las que ya hay, hasta un tope total. Antes solo actuaba si
        // NO había ninguna, pero el auto-tagger por dominio casi siempre pone alguna → el etiquetado
        // por IA quedaba anulado (el usuario pidió etiquetado más rico, 2026-06-28).
        if grounded {
            let maxTags = 6
            for raw in s.tags {
                if link.tags.count >= maxTags { break }
                // Saneo central: decodifica percent-encoding, conserva tildes y descarta
                // basura («7 días», restos %c3a, coletillas). Ver TagSanitizer.
                guard let name = TagSanitizer.clean(raw),
                      let tag = resolveTag(name, in: context, cache: &tagCache) else { continue }
                if !link.tags.contains(where: { $0.id == tag.id }) { link.tags.append(tag) }
            }
        }
        link.updatedAt = Date()
        SpotlightIndexer.index(link)
    }

    /// ¿El título propuesto por la IA es ACEPTABLE? Rechaza meta-respuestas («No se proporcionó
    /// título…», «como modelo de IA…») y frases largas (un título no es un párrafo): un título
    /// basura, aunque esté fundamentado en la página, no debe sustituir al OG/host honesto.
    private static func isAcceptableTitle(_ t: String) -> Bool {
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 160 else { return false }
        return !isMetaNonAnswer(trimmed)
    }

    /// ¿La colección del enlace es la GENÉRICA «Desarrollo» que se asigna AUTOMÁTICAMENTE a todo
    /// repo de código (GitHub/GitLab…)? Esas plataformas son MULTITEMÁTICAS, así que «Desarrollo»
    /// suele quedarse corta y conviene que la IA la afine a la colección real del contenido. Se
    /// limita a hosts de código para no «mover» categorías específicas y correctas de sitios
    /// monotemáticos (Steam→Videojuegos, YouTube→Vídeos…).
    private static func hasGenericCodeCategory(_ link: Bookmark) -> Bool {
        guard let cat = link.category,
              CollectionMerger.canonical(cat.name) == "desarrollo" else { return false }
        let host = link.url.urlHost.lowercased()
        let codeHosts = ["github.com", "gitlab.com", "bitbucket.org", "codeberg.org",
                         "sourceforge.net", "gitea.com", "gitea.io", "sr.ht", "gogs.io"]
        return codeHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// ¿`candidate` es una versión LIMPIA de `original` (el mismo contenido sin el ruido
    /// de sufijos del sitio/coletillas)? `true` solo si, normalizado (sin tildes, solo
    /// alfanuméricos), `candidate` es más corto y está contenido en `original`. Así se
    /// acepta «Swift (lenguaje de programación)» como limpieza de «Swift (lenguaje de
    /// programación) - Wikipedia, la enciclopedia libre», pero NUNCA un título inventado.
    private static func isCleanedVariant(_ candidate: String, of original: String) -> Bool {
        func norm(_ s: String) -> String {
            s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
                .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        }
        let c = norm(candidate), o = norm(original)
        guard c.count >= 3, c.count < o.count else { return false }
        return o.contains(c)
    }

    /// Colección para la categoría sugerida por la IA. Delega en el resolutor canónico ÚNICO
    /// (`EntityResolver`), que reúne sinónimos/traducciones («Development»→«Desarrollo»,
    /// «Juegos»→«Videojuegos») y re-comprueba el contexto (ve inserts pendientes de tareas
    /// concurrentes) para no duplicar. `names` (lo que la IA cree que ya existe) se mantiene
    /// al día con el nombre resuelto.
    @discardableResult
    private static func resolveCategory(_ name: String, in context: ModelContext,
                                        cache: inout [String: BookmarkCategory],
                                        names: inout Set<String>) -> BookmarkCategory? {
        guard let cat = EntityResolver.category(name, in: context, cache: &cache) else { return nil }
        names.insert(cat.name)
        return cat
    }

    @discardableResult
    private static func resolveTag(_ name: String, in context: ModelContext,
                                   cache: inout [String: Tag]) -> Tag? {
        EntityResolver.tag(name, in: context, cache: &cache)
    }
}

/// Saneador central de nombres de etiqueta. Las etiquetas automáticas (IA, metadatos,
/// dominio) llegaban con basura: percent-encoding sin decodificar y truncado
/// (`meteorolog%c3a` por «meteorología»), términos sin valor («7 días», «tabla») y
/// tildes perdidas. Esto centraliza la limpieza: se aplica en TODOS los puntos del Mac
/// donde se crea una etiqueta a partir de texto, para que solo entren etiquetas útiles.
/// (Definido aquí, en un archivo ya incluido en el target, en vez de en un archivo suelto.)
enum TagSanitizer {

    /// Clave de deduplicación canónica (minúsculas + SIN tildes + espacios colapsados),
    /// para que «Código», «codigo» y «CÓDIGO» se traten como la MISMA etiqueta/categoría
    /// y se reutilice la existente en vez de crear duplicados. Sirve para tags y categorías.
    static func key(_ name: String) -> String {
        name.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Coletillas/términos sin valor como etiqueta (en minúsculas, sin tildes).
    private static let stopwords: Set<String> = [
        "tabla", "pagina", "inicio", "home", "index", "untitled", "sin titulo",
        "articulo", "video", "noticia", "web", "sitio", "online", "gratis",
        "click", "aqui", "mas", "ver", "leer", "info", "general", "varios"
    ]

    /// Devuelve un nombre de etiqueta limpio, o `nil` si no es válido/aporta valor.
    /// - Decodifica percent-encoding COMPLETO (restaura tildes: `predicci%C3%B3n` → «predicción»).
    /// - Rechaza percent-encoding corrupto/truncado (sigue con «%» o `%xx` suelto).
    /// - Rechaza basura: sin letras, numérico-inicial («7 días»), demasiado corta/larga, coletillas.
    static func clean(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // Decodifica percent-encoding solo si está COMPLETO y produce UTF-8 válido.
        if s.contains("%"), let decoded = s.removingPercentEncoding, !decoded.contains("\u{FFFD}") {
            s = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Restos de percent-encoding (decodificación fallida o truncada) → descartar.
        if s.contains("%") { return nil }

        // Limpia comillas/guiones de adorno en los extremos.
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'«»“”·-–—|/\\ "))
        guard !s.isEmpty else { return nil }

        // Debe contener al menos una letra (descarta «2024», «100», símbolos sueltos).
        guard s.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return nil }

        // Numérico-inicial sin valor: «7 días», «10 cosas», «3 trucos».
        if s.range(of: "^\\d", options: .regularExpression) != nil { return nil }

        // Longitud razonable para una etiqueta (no frases).
        let len = s.count
        guard len >= 2, len <= 28 else { return nil }
        // No más de 3 palabras (una etiqueta no es una frase).
        guard s.split(separator: " ").count <= 3 else { return nil }

        // Coletillas sin valor (comparando sin tildes ni mayúsculas).
        let folded = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        if stopwords.contains(folded) { return nil }

        return s
    }

    /// Saneo LIGERO para etiquetas que el usuario pidió explícitamente: decodifica
    /// percent-encoding y descarta restos corruptos, pero respeta su elección (no filtra
    /// por longitud ni por ser numérica). Devuelve nil solo si queda vacía o corrupta.
    static func sanitizeProvided(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("%"), let d = s.removingPercentEncoding, !d.contains("\u{FFFD}") {
            s = d.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.contains("%") { return nil }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'«»“”·|/\\ "))
        return s.isEmpty ? nil : s
    }

    /// Limpia y deduplica (sin distinción de mayúsculas/tildes) una lista de etiquetas,
    /// conservando el orden y la primera grafía vista.
    static func cleanList(_ raw: [String], limit: Int = 8) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for r in raw {
            guard let name = clean(r) else { continue }
            let key = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            if seen.insert(key).inserted {
                out.append(name)
                if out.count >= limit { break }
            }
        }
        return out
    }
}

/// Monitor LIGERO de actividad del usuario: registra el instante de la última interacción
/// (ratón, scroll, teclado) mediante un monitor LOCAL de `NSEvent`. Lo usa el enriquecido en
/// lote para PAUSAR la inferencia MLX (que satura la GPU) mientras el usuario está usando la app,
/// de modo que el render no se entrecorte. Singleton @MainActor; el monitor vive toda la sesión.
@MainActor
final class UserActivityMonitor {
    static let shared = UserActivityMonitor()
    private var lastActivity = Date()
    private var lastScroll = Date.distantPast
    private var lastScrollPost = Date.distantPast
    private var monitor: Any?

    private init() {
        // Eventos que delatan que el usuario está interactuando (no consumimos: devolvemos el evento).
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .scrollWheel, .keyDown, .flagsChanged, .magnify, .swipe,
        ]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lastActivity = Date()
                // El SWIPE de dos dedos del trackpad y el scroll llegan como `.scrollWheel`. Avisa
                // (throttle) para que la hover preview se OCULTE y no tape las acciones de swipe.
                if event.type == .scrollWheel {
                    let now = Date()
                    self.lastScroll = now
                    if now.timeIntervalSince(self.lastScrollPost) > 0.25 {
                        self.lastScrollPost = now
                        NotificationCenter.default.post(name: .stacklumeUserScrolled, object: nil)
                    }
                }
            }
            return event
        }
        // Traer la app al frente (cambiar A Stacklume) también cuenta como actividad: el clic en
        // el dock / ⌘Tab no llega al monitor de eventos, así que sin esto el enriquecido podría
        // arrancar justo al volver a la app. Con esto, se aplaza ~45 s tras volver al frente.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastActivity = Date() }
        }
    }

    /// ¿Hubo interacción en los últimos `seconds` segundos?
    func recentlyActive(within seconds: TimeInterval) -> Bool {
        Date().timeIntervalSince(lastActivity) < seconds
    }

    /// Puerta para MLX/Metal. Cuando Stacklume está activa se basa en sus eventos locales;
    /// cuando está detrás de otra app consulta el tiempo desde la última entrada de la sesión
    /// completa. Así el autoenriquecido no compite con un juego, una videollamada o cualquier
    /// trabajo que el usuario esté haciendo fuera de Stacklume. No requiere capturar ni guardar
    /// teclas: CoreGraphics solo devuelve un intervalo agregado de inactividad.
    var shouldPauseHeavyBackgroundWork: Bool {
        if MenuBarController.shared.isMenuBarOnly { return true }
        if NSApplication.shared.isActive {
            return recentlyActive(within: 45.0)
        }
        guard let anyInputEvent = CGEventType(rawValue: UInt32.max) else { return true }
        let idleSeconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: anyInputEvent
        )
        return idleSeconds < 180
    }

    /// ¿Hubo scroll/swipe en los últimos `seconds` segundos? Lo usa la hover preview para NO
    /// aparecer mientras deslizas (taparía las acciones de swipe).
    func recentlyScrolled(within seconds: TimeInterval) -> Bool {
        Date().timeIntervalSince(lastScroll) < seconds
    }

    /// Cede el hilo MIENTRAS el usuario está interactuando (scroll/teclado/ratón/trackpad), para
    /// que el trabajo de fondo —red y, sobre todo, las ESCRITURAS en SwiftData, que invalidan el
    /// `@Query` y obligan a recalcular/re-diffear la lista— NO compita con la interacción y no la
    /// entrecorte. Vuelve cuando lleva `idle` segundos sin actividad o si la tarea se cancela.
    /// Pensado para las pasadas de fondo LIGERAS (metadatos de red, portadas, copia offline,
    /// salud): un umbral corto (≈2,5 s) las pausa durante el scroll pero las reanuda en cuanto
    /// hay una pausa, así avanzan sin que se note. (El enriquecido MLX usa su propia puerta de
    /// 45 s porque la carga del modelo es mucho más cara e ininterrumpible.)
    func waitUntilIdle(idle: TimeInterval = 2.5) async {
        while recentlyActive(within: idle) {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }
}
