import Foundation
import SwiftData
import StacklumeCore
import StacklumeMetadata
import StacklumePersistence

/// Alta unificada de un enlace SIN editor (arrastrar y soltar, deep link
/// `stacklume://add`). Centraliza el camino que antes estaba duplicado e inline en
/// `RootWindowView`: detectar plataforma, insertar el `Bookmark`, indexar en Spotlight
/// y lanzar el enriquecido en segundo plano.
///
/// El enriquecido replica el del iPhone: primero metadatos de red
/// (`MacLinkEnricher.enrichFromNetwork`, que además auto-organiza) y, si procede, IA
/// (autocategoría, autoetiquetas, descripción y traducción al idioma de la app vía
/// `AIBatchEnricher.enrichOne`, que REUTILIZA el mismo mapeo `EnrichedSuggestion`→
/// modelo que el editor y el lote). NO se duplica nada: solo se orquesta lo existente.
///
/// Concurrencia (Swift 6 strict): todo corre en `@MainActor`. El `Bookmark` es un
/// `@Model` no-`Sendable`, así que NUNCA cruza un límite de actor: las llamadas de red
/// e IA hacen `await` (suspenden) pero siempre vuelven al `MainActor` antes de tocar el
/// modelo. Es el mismo patrón del editor y de `AIBatchEnricher`.
@MainActor
enum LinkIngest {

    /// Entrada ligera para altas en lote. `suggestedTitle` se usa como semilla visible
    /// (por ejemplo, el título de una pestaña del navegador) y el enriquecido posterior
    /// puede mejorarlo con los metadatos reales de la página.
    struct IngestItem: Sendable {
        let urlString: String
        let suggestedTitle: String?

        init(urlString: String, suggestedTitle: String? = nil) {
            self.urlString = urlString
            self.suggestedTitle = suggestedTitle
        }
    }

    /// Resultado de una alta masiva: los duplicados se devuelven para que la UI pueda
    /// explicar cuántos se omitieron sin volver a consultar SwiftData.
    struct BatchResult {
        let added: [Bookmark]
        let skipped: [Bookmark]
    }

    struct UserOrganization {
        let categoryID: UUID?
        let tagIDs: Set<UUID>
        let preservesCategory: Bool
        let replacesTags: Bool

        init(category: BookmarkCategory?, tags: [Tag], preservesCategory: Bool = true,
             replacesTags: Bool = false) {
            categoryID = category?.id
            tagIDs = Set(tags.map(\.id))
            self.preservesCategory = preservesCategory
            self.replacesTags = replacesTags
        }
    }

    private static var organizationGate = IngestOrganizationGate()
    private static var latestHumanOrganization: [UUID: UserOrganization] = [:]
    private static var pendingEnrichment: Set<UUID> = []
    private static var latestHumanText: [UUID: (title: String, details: String?)] = [:]

    static func userChangedText(_ bookmarkID: UUID) {
        guard pendingEnrichment.contains(bookmarkID),
              let job = enrichJobs.first(where: { $0.bookmarkID == bookmarkID }),
              job.link.modelContext != nil, job.link.deletedAt == nil else { return }
        latestHumanText[bookmarkID] = (job.link.title, job.link.details)
    }

    static func userChangedOrganization(_ bookmarkID: UUID) {
        guard pendingEnrichment.contains(bookmarkID),
              let job = enrichJobs.first(where: { $0.bookmarkID == bookmarkID }),
              job.link.modelContext != nil, job.link.deletedAt == nil else { return }
        latestHumanOrganization[bookmarkID] = .init(category: job.link.category, tags: job.link.tags,
                                                   replacesTags: true)
        organizationGate.invalidate(bookmarkID)
    }

    /// Inserta el enlace y arranca el enriquecido en segundo plano. Devuelve el
    /// `Bookmark` recién creado o el existente si era un duplicado, para que el llamante
    /// pueda, p. ej., seleccionarlo.
    ///
    /// - Parameters:
    ///   - urlString: la URL (http/https) ya validada por el llamante.
    ///   - context: el `ModelContext` de la ventana.
    ///   - aiEnrich: si `true`, además de los metadatos de red intenta IA (respetando
    ///     el toggle `stacklume.aiAutoEnrich` y la disponibilidad del modelo Liquid).
    @discardableResult
    static func ingestLink(
        urlString: String,
        in context: ModelContext,
        aiEnrich: Bool
    ) -> Bookmark {
        let result = ingestLinks(
            [IngestItem(urlString: urlString)],
            in: context,
            category: nil,
            aiEnrich: aiEnrich
        )
        // Cada entrada produce necesariamente un alta o un duplicado activo.
        return result.added.first ?? result.skipped[0]
    }

    /// Alta masiva optimizada para pestañas, pegado múltiple e importadores interactivos.
    /// Obtiene los enlaces existentes UNA sola vez, deduplica también dentro del propio lote,
    /// inserta y guarda en una transacción y después encola el enriquecido serializado. Así un
    /// lote grande no repite un fetch completo por URL ni degrada a O(n²).
    @discardableResult
    static func ingestLinks(
        _ items: [IngestItem],
        in context: ModelContext,
        category: BookmarkCategory?,
        aiEnrich: Bool,
        userOrganization: UserOrganization? = nil
    ) -> BatchResult {
        guard !items.isEmpty else { return BatchResult(added: [], skipped: []) }

        let active = ((try? context.fetch(FetchDescriptor<Bookmark>(
            predicate: #Predicate { $0.deletedAt == nil }
        ))) ?? [])
        var existingByCanonical: [String: Bookmark] = [:]
        for link in active {
            // Una biblioteca antigua puede contener duplicados previos al embudo único.
            // Conserva el primero sin hacer `Dictionary(uniqueKeysWithValues:)`, que haría trap.
            let key = CanonicalURL.key(link.url)
            if existingByCanonical[key] == nil { existingByCanonical[key] = link }
        }
        var added: [Bookmark] = []
        var skipped: [Bookmark] = []

        for item in items {
            // ¿Comando de instalación (npm i…, pip install…, brew install…)? Se guarda
            // apuntando a la página del registro del paquete y conserva el comando original.
            let commandInfo = CommandDetector.detect(item.urlString)
            // Normaliza esquema y host antes de deduplicar y persistir.
            let effectiveURL = Self.normalizeURL(commandInfo?.registryURL ?? item.urlString)
            let canonicalKey = CanonicalURL.key(effectiveURL)
            if let existing = existingByCanonical[canonicalKey] {
                if let cmd = commandInfo?.command, existing.command?.isEmpty ?? true {
                    existing.command = cmd
                }
                skipped.append(existing)
                continue
            }

            let detection = PlatformDetector.detect(effectiveURL)
            let suggestedTitle = item.suggestedTitle?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let nonEmptySuggestedTitle = suggestedTitle.flatMap { $0.isEmpty ? nil : $0 }
            let title = commandInfo?.packageName
                ?? nonEmptySuggestedTitle
                ?? URL(string: effectiveURL)?.host()
                ?? effectiveURL
            let link = Bookmark(url: effectiveURL, title: title,
                                platform: commandInfo?.platform ?? detection.platform,
                                contentType: commandInfo != nil ? .code : detection.contentType)
            link.platformColor = commandInfo?.colorHex ?? detection.brandColorHex
            link.command = commandInfo?.command
            link.category = category
            context.insert(link)
            applyUserOrganization(userOrganization, to: link, in: context)
            existingByCanonical[canonicalKey] = link
            added.append(link)
        }

        context.saveLogging()
        for link in added { SpotlightIndexer.index(link) }

        // Idioma y preferencia se resuelven una sola vez para todo el lote.
        let language = AppSettingsStore.current(in: context).language.rawValue
        let autoEnrichEnabled = UserDefaults.standard.object(
            forKey: "stacklume.aiAutoEnrich"
        ) as? Bool ?? true
        for link in added {
            enqueueEnrich(link, in: context,
                          aiEnrich: aiEnrich && autoEnrichEnabled,
                          language: language,
                          userOrganization: userOrganization)
        }

        return BatchResult(added: added, skipped: skipped)
    }

    // MARK: - Cola serializada de enriquecido del alta

    /// Un trabajo de enriquecido pendiente. Se guarda el `Bookmark` directamente (todo es
    /// `@MainActor` y comparte el mismo `ModelContext`); `enrichInBackground` ya se protege con
    /// `link.modelContext != nil` por si el enlace se borró mientras esperaba su turno.
    private struct EnrichJob {
        let bookmarkID: UUID
        let link: Bookmark
        let context: ModelContext
        let aiEnrich: Bool
        let language: String
        let userOrganization: UserOrganization?
        let organizationTicket: UUID?
    }
    private static var enrichJobs: [EnrichJob] = []
    private static var enrichJobHead = 0
    private static var enrichDraining = false

    /// Añade un enlace a la cola y arranca el vaciado si no estaba ya en marcha.
    private static func enqueueEnrich(_ link: Bookmark, in context: ModelContext,
                                      aiEnrich: Bool, language: String,
                                      userOrganization: UserOrganization?) {
        pendingEnrichment.insert(link.id)
        enrichJobs.append(EnrichJob(bookmarkID: link.id, link: link, context: context,
                                    aiEnrich: aiEnrich, language: language,
                                    userOrganization: userOrganization,
                                    organizationTicket: userOrganization == nil ? nil : organizationGate.begin(link.id)))
        drainEnrichQueue()
    }

    /// Vacía la cola en ORDEN, procesando UN enlace cada vez (await secuencial): la siguiente
    /// alta no empieza hasta que la anterior termina, así el modelo local nunca atiende dos a la
    /// vez. Reentrante-seguro: si ya hay un vaciado en curso, las nuevas altas solo se añaden a la
    /// cola y este mismo bucle las recogerá. Best-effort: un fallo en un enlace no detiene el resto.
    private static func drainEnrichQueue() {
        guard !enrichDraining else { return }
        enrichDraining = true
        Task { @MainActor in
            defer {
                enrichJobs.removeAll(keepingCapacity: true)
                enrichJobHead = 0
                enrichDraining = false
            }
            // Índice de cabeza en vez de `removeFirst()`: una importación grande no desplaza
            // todo el array por cada enlace (O(n²)). Las altas nuevas se pueden seguir anexando.
            while enrichJobHead < enrichJobs.count {
                let job = enrichJobs[enrichJobHead]
                enrichJobHead += 1
                await enrichInBackground(job.link, in: job.context,
                                         aiEnrich: job.aiEnrich, language: job.language,
                                         userOrganization: job.userOrganization,
                                         organizationTicket: job.organizationTicket,
                                         bookmarkID: job.bookmarkID)
            }
        }
    }

    /// Enriquecido en 2.º plano para un enlace ya insertado: metadatos de red (que ya
    /// auto-organizan) y, si procede, IA. Aislado en `@MainActor`: el `Bookmark` no
    /// cruza hilos; las llamadas `await` suspenden y reanudan en el MainActor.
    private static func enrichInBackground(
        _ link: Bookmark,
        in context: ModelContext,
        aiEnrich: Bool,
        language: String,
        userOrganization: UserOrganization?,
        organizationTicket: UUID?,
        bookmarkID: UUID
    ) async {
        defer {
            if link.modelContext != nil, link.deletedAt == nil,
               userOrganization != nil || latestHumanOrganization[bookmarkID] != nil {
                applyUserOrganization(userOrganization, to: link, in: context, ticket: organizationTicket)
                context.saveLogging()
                SpotlightIndexer.index(link)
            }
            if let organizationTicket { organizationGate.finish(organizationTicket, for: bookmarkID) }
            latestHumanOrganization.removeValue(forKey: bookmarkID)
            latestHumanText.removeValue(forKey: bookmarkID)
            pendingEnrichment.remove(bookmarkID)
            if MenuBarController.shared.isMenuBarOnly { LocalAIRunner.shared.unload() }
        }
        // Guarda anti-crash: si el enlace se borró antes de arrancar, no lo toques.
        guard link.modelContext != nil else { return }
        // Los servidores locales se pueden guardar y abrir de forma explícita, pero nunca
        // generan tráfico automático de metadatos/portadas/salud. Esto protege altas desde
        // deep links, imports y backups frente a SSRF y DNS rebinding.
        guard let publicURL = StacklumeAutomationPolicy.openableStoredURL(link.url),
              StacklumeAutomationPolicy.allowsAutomaticNetworkURL(publicURL),
              let publicHost = publicURL.host(),
              await Task.detached(priority: .utility, operation: {
                  AssistantHostResolver.hasOnlyPublicAddresses(publicHost)
              }).value
        else { return }
        // 0) Acortador (t.co, bit.ly…): resuélvelo a la URL REAL antes de pedir metadatos, para que
        //    plataforma/favicon/imagen Y la auto-organización salgan del sitio de verdad y no del
        //    acortador (p. ej. pegar desde X un t.co de HuggingFace no debe quedar como X/t.co).
        //    Punto único [[LibraryCompleter]]. No-op si no es un acortador.
        await LibraryCompleter.resolveIfShortened(link, in: context)
        // Si el acortador resolvía a un enlace que ya existía, `resolveIfShortened` lo soft-borra
        // (dedup): no seguimos enriqueciendo un enlace eliminado.
        guard link.modelContext != nil, link.deletedAt == nil else { return }
        // 1) Metadatos de red (imagen, nombre del sitio, plataforma; título si vacío).
        //    `enrichFromNetwork` ya llama internamente a `autoOrganize` y guarda.
        let protectedTitle = UserEditLedger.isTitleEdited(link.id) ? link.title : nil
        let protectsDetails = UserEditLedger.isDetailsEdited(link.id)
        let protectedDetails = protectsDetails ? link.details : nil
        await MacLinkEnricher.enrichFromNetwork(link, in: context, overwriteTitle: protectedTitle == nil)
        guard link.modelContext != nil else { return }
        if UserEditLedger.isTitleEdited(link.id) {
            if let edit = latestHumanText[bookmarkID] { link.title = edit.title }
            else if let protectedTitle { link.title = protectedTitle }
        }
        if UserEditLedger.isDetailsEdited(link.id) {
            if let edit = latestHumanText[bookmarkID] { link.details = edit.details }
            else if protectsDetails { link.details = protectedDetails }
        }
        applyUserOrganization(userOrganization, to: link, in: context, ticket: organizationTicket)

        // 1.25) COMANDO (npm i…, brew install…): `enrichFromNetwork` trajo los metadatos de la página
        //       del registro y de paso pisó plataforma/tipo/color con los GENÉRICOS del sitio → se
        //       perdía el badge del comando. Si es un comando, restaura su plataforma/tipo/color (el
        //       badge correcto que ya puso el alta). Solo afecta a comandos; el resto no se toca.
        if let cmd = link.command, !cmd.isEmpty, let info = CommandDetector.detect(cmd) {
            if link.platform != info.platform { link.platform = info.platform }
            if link.contentType != .code { link.contentType = .code }
            if link.platformColor != info.colorHex { link.platformColor = info.colorHex }
            context.saveLogging()
        }

        // 1.5) Limpieza DETERMINISTA del título (quita «GitHub - », «… - YouTube», «… -
        //      Wikipedia…»). Se hace aquí —no solo dentro de la IA— porque si la
        //      organización por reglas ya rellenó colección/etiquetas, el enlace no
        //      «necesita» IA y `enrichOne` no se ejecutaría: el título quedaría sucio.
        let cleanedTitle = TitleCleaner.clean(link.title, siteName: link.siteName, host: link.url.urlHost)
        if !UserEditLedger.isTitleEdited(link.id), !cleanedTitle.isEmpty, cleanedTitle != link.title {
            link.title = cleanedTitle
            context.saveLogging()
            SpotlightIndexer.index(link)
        }

        // 1.7) Reglas de clasificación del usuario (sección «Reglas»). Se aplican AQUÍ,
        //      al guardar, para que de verdad clasifiquen los enlaces nuevos —antes solo
        //      corrían vía `BatchEnricher`, que solo procesa enlaces que «necesitan
        //      enriquecido», así que un enlace ya completo NUNCA recibía las reglas.
        //      Van antes de la IA: así aplican aunque la IA esté apagada y la colección
        //      de una regla gana en contenido genérico (la IA no pisa una ya asignada).
        if userOrganization?.preservesCategory != true { applyUserRules(to: link, in: context) }

        // 1.75) Clasificación DETERMINISTA por dominio (señal fuerte): p. ej. cualquier enlace de
        //       huggingface.co/ollama/replicate… es de IA y va a «IA»/«LLM», NUNCA a «Videojuegos».
        //       Va ANTES de la IA y solo si aún no tiene colección, así que: (a) funciona aunque la
        //       IA esté apagada, y (b) la IA luego NO la pisa (su gate es `category == nil`). No
        //       depende del modelo: el fallo recurrente (un LLM con nombre llamativo → Videojuegos)
        //       deja de ser posible para estos dominios. Ver [[DomainCategoryRules]].
        if userOrganization?.preservesCategory != true { applyDomainCategory(to: link, in: context) }

        // 1.8) Favicon que CARGUE de verdad ya en el alta: prueba la cascada y persiste el
        //      primer candidato válido (no el globo). Así un enlace recién pegado nunca aparece
        //      con el icono genérico en la lista. Punto único reutilizado ([[LibraryCompleter]]).
        if link.modelContext != nil,
           await LibraryCompleter.ensureWorkingFavicon(link, allowRender: true) {
            context.saveLogging()
        }

        // 2) IA: solo si se pidió, el modelo Liquid está disponible y el enlace aún
        //    necesita huecos. Reutiliza el mapeo del editor/lote vía `AIBatchEnricher`.
        //    NO se cambia el modelo.
        if aiEnrich, isLiquidAvailable, link.modelContext != nil {
            // FUNDAMENTA la IA: el HTML estático de las SPAs (p. ej. huggingface.co/collections,
            // que se renderiza con JS) NO da prosa, así que la IA se SALTABA la descripción y las
            // etiquetas (blindaje `grounded`: sin contenido real no inventa). Si el texto estático
            // viene vacío, se RENDERIZA la página (mismo camino que «Mejorar con IA») para extraer
            // su texto REAL y dárselo a la IA. Si el estático ya da contenido, NO se renderiza
            // (barato, sin coste para la mayoría de páginas). Punto único [[LibraryCompleter]].
            var pageContent = await AIBatchEnricher.pageContentExcerpt(for: link.url)
            if (pageContent?.isEmpty ?? true), link.modelContext != nil {
                pageContent = await LibraryCompleter.renderAndApplyMeta(link)
            }
            if link.modelContext != nil {
                await AIBatchEnricher.enrichOne(link, in: context, provider: "liquid",
                                                language: language, prefetchedContent: pageContent)
            }
        }

        // 2.5) Funde colecciones/etiquetas DUPLICADAS por sinónimo/traducción EN EL ACTO. La
        //      clasificación del paquete (`autoOrganize`, que corre dentro de `enrichFromNetwork`)
        //      NO conoce el mapa de sinónimos de `CollectionMerger`, así que puede crear «Juegos»
        //      habiendo ya «Videojuegos». El auto-merge solo corría AL ARRANCAR, así que la
        //      duplicada se veía hasta el siguiente inicio. Aquí se reconcilia en cuanto el alta
        //      pudo crearla. Conservador (solo equivalentes claros) y barato (pocas colecciones);
        //      idempotente y sin coste cuando no hay duplicados.
        if link.modelContext != nil {
            _ = CollectionMerger.mergeDuplicates(in: context)
            _ = EntityResolver.mergeDuplicateTags(in: context)
        }

        // 3) Portada perfecta: si tras la red NO había `og:image`, busca la imagen «hero»
        //    del HTML o captura la página renderizada (SPAs/canvas). Punto único reutilizado
        //    (ver [[CoverEnsurer]]); best-effort y serializado para no abrir muchas a la vez.
        guard link.modelContext != nil else { return }
        await CoverEnsurer.ensure(for: link, in: context)

        // 4) TRADUCCIÓN AUTOMÁTICA: si el TÍTULO (u otro texto) quedó en un idioma no latino
        //    (chino, japonés, árabe…), avisa al motor de traducción automática ([[AutoTranslateEngine]],
        //    montado en la ventana) para pasarlo al idioma de la app AL INSTANTE. La traducción usa
        //    el framework `Translation` de Apple, que requiere una sesión de VISTA (por eso el motor
        //    vive en la ventana, no aquí). El lote de Mantenimiento sigue como red de seguridad.
        if link.modelContext != nil, LinkTranslator.needsTranslation(link) {
            NotificationCenter.default.post(name: .stacklumeAutoTranslate, object: nil)
        }
    }

    private static func applyUserOrganization(
        _ organization: UserOrganization?, to link: Bookmark, in context: ModelContext,
        ticket: UUID? = nil
    ) {
        guard link.modelContext != nil, link.deletedAt == nil,
              var organization = latestHumanOrganization[link.id] ?? organization else { return }
        if let ticket, !organizationGate.accepts(ticket, for: link.id) {
            guard let latest = latestHumanOrganization[link.id] else { return }
            organization = latest
        }
        if organization.preservesCategory {
            if let categoryID = organization.categoryID {
                var descriptor = FetchDescriptor<BookmarkCategory>(
                    predicate: #Predicate { $0.id == categoryID && $0.deletedAt == nil })
                descriptor.fetchLimit = 1
                if let category = try? context.fetch(descriptor).first { link.category = category }
            } else {
                link.category = nil
            }
        }
        guard organization.replacesTags || !organization.tagIDs.isEmpty else { return }
        let tags = (try? context.fetch(FetchDescriptor<Tag>(
            predicate: #Predicate { $0.deletedAt == nil }))) ?? []
        if organization.replacesTags {
            link.tags = tags.filter { organization.tagIDs.contains($0.id) }
        } else {
            let current = Set(link.tags.map(\.id))
            link.tags.append(contentsOf: tags.filter {
                organization.tagIDs.contains($0.id) && !current.contains($0.id)
            })
        }
    }

    /// Aplica las reglas de clasificación del usuario al enlace (igual que `BatchEnricher`,
    /// usando el [[ClassificationEngine]] compartido). Añade etiquetas y fija la colección
    /// si aún no tiene. No-op si no hay reglas. Persiste y reindexa solo si hace falta.
    private static func applyUserRules(to link: Bookmark, in context: ModelContext) {
        guard link.modelContext != nil else { return }
        let rules = (try? context.fetch(FetchDescriptor<ClassificationRule>())) ?? []
        guard !rules.isEmpty else { return }
        let categories = (try? context.fetch(FetchDescriptor<BookmarkCategory>())) ?? []
        let tags = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        ClassificationEngine.apply(to: link, rules: rules, categories: categories, tags: tags)
        context.saveLogging()
        SpotlightIndexer.index(link)
    }

    /// Clasificación DETERMINISTA por dominio (ver [[DomainCategoryRules]]): si el dominio tiene
    /// una colección inequívoca y el enlace aún no tiene ninguna, se la asigna. Resuelve por
    /// canónica ([[EntityResolver]]), así que cae en la colección real del usuario. No depende del
    /// modelo de IA: el fallo recurrente (un LLM con nombre llamativo → «Videojuegos») desaparece
    /// para los dominios cubiertos.
    private static func applyDomainCategory(to link: Bookmark, in context: ModelContext) {
        guard link.modelContext != nil, link.category == nil else { return }
        guard let name = DomainCategoryRules.categoryName(forURL: link.url,
                                                          title: link.title, details: link.details),
              let category = EntityResolver.category(name, in: context) else { return }
        link.category = category
        context.saveLogging()
        SpotlightIndexer.index(link)
    }

    /// El modelo Liquid local está listo para usarse sin forzar una descarga ni una
    /// autocarga que el usuario haya desactivado a mano. La carga del modelo en memoria
    /// la dispara la propia `UnifiedAIService` cuando hace falta (igual que el editor).
    private static var isLiquidAvailable: Bool {
        // Detección ROBUSTA (`isAvailable`: cargado, marcado o presente en disco) en vez del
        // flag `isDownloaded`, que puede quedar a false aunque el modelo esté instalado.
        // Se respeta la desactivación manual del usuario.
        LocalAIRunner.shared.isAvailable && !LocalAIRunner.shared.isDeactivated
    }

    /// Normaliza la URL para GUARDARLA: añade esquema si falta, **sube `http`→`https`** (ATS
    /// bloquea el HTTP en claro → con http la adquisición de metadatos falla) y pasa el **host a
    /// minúsculas** (es case-insensitive; evita duplicados como `Macfolio.com` vs `macfolio.com` y
    /// que los servicios de favicon devuelvan genérico). Elimina credenciales Basic Auth para no
    /// persistir contraseñas incrustadas por accidente. Conserva ruta/parámetros/fragmento. Si no
    /// se puede parsear, devuelve la entrada tal cual (no rompe nada).
    static func normalizeURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return raw }
        if !s.contains("://") { s = "https://" + s }
        guard var comps = URLComponents(string: s) else { return s }
        let host = (comps.host ?? "").lowercased()
        // NO subir http→https en hosts LOCALES (servidores de desarrollo http-only a propósito:
        // localhost, 127.x, ::1, *.local, IPs privadas) — romperían. Sí en el resto (ATS bloquea
        // el http en claro público). El host SIEMPRE se pasa a minúsculas (es case-insensitive).
        let isLocal = host == "localhost" || host == "::1" || host.hasSuffix(".local")
            || host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.")
        // El esquema SIEMPRE en minúsculas (es case-insensitive); además `http`→`https` (salvo
        // hosts locales). Antes un `HTTPS://` en mayúsculas se quedaba tal cual (no estándar).
        if let scheme = comps.scheme?.lowercased() {
            comps.scheme = (scheme == "http" && !isLocal) ? "https" : scheme
        }
        comps.user = nil
        comps.password = nil
        if let h = comps.host, h != h.lowercased() { comps.host = h.lowercased() }
        return comps.url?.absoluteString ?? s
    }
}
