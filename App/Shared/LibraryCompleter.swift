import Foundation
import SwiftData
import StacklumeCore
import StacklumeDesignSystem
import StacklumeMetadata

/// Orquestador ÚNICO de la «capa garantizada» (SIN IA, solo red) que asegura que NINGÚN
/// enlace quede incompleto de vista: metadatos, un favicon que CARGUE de verdad (no el globo)
/// y —en la pasada exhaustiva— portada y salud. No duplica nada: reutiliza el motor existente
/// (`MacLinkEnricher.enrichFromNetwork`, `CoverEnsurer`, `HealthChecker`) y la misma cascada de
/// favicon que la cuadrícula/detalle (`PreviewImage.favicon`).
///
/// Tres entradas:
/// - `complete(_:…)` — por enlace, reutilizada por el botón, el autocurativo y el alta.
/// - `completeAll(…)` — pasada COMPLETA del botón de Mantenimiento: TODOS los enlaces, sin
///   límite ni libro mayor («se va haciendo poco a poco hasta acabar»). Cancelable.
/// - `runIfNeeded(…)` — autocurativo en 2.º plano: mop-up incremental del backlog importado,
///   cediendo ante la interacción (NO toca la GPU/MLX → no reintroduce el entrecorte).
///
/// La capa IA (MLX) NO vive aquí: sigue corriendo solo en 2.º plano/inactividad como antes.
@MainActor
enum LibraryCompleter {

    // MARK: - Por enlace (botón, autocurativo y alta)

    /// Asegura, SIN IA, que un enlace esté «completo de vista». Devuelve `true` si cambió algo.
    /// - `coverAndHealth`: en la pasada exhaustiva del botón también asegura portada y salud
    ///   (en 2.º plano eso lo cubren sus propias pasadas: [[CoverAutoFiller]], [[LinkHealthMonitor]]).
    @discardableResult
    static func complete(_ link: Bookmark, in context: ModelContext,
                         coverAndHealth: Bool, allowSnapshot: Bool = true,
                         allowRenderFavicon: Bool = false) async -> Bool {
        guard link.modelContext != nil, link.fileKind == nil else { return false }
        var changed = false

        // 0) Acortador (t.co, bit.ly…): EXPÁNDELO a su destino real ANTES de pedir metadatos, para
        //    que el favicon/imagen/título salgan de la página de verdad y «Abrir original» lleve al
        //    sitio correcto (no a la pantalla de X). Punto único [[ShortLinkResolver]].
        if await resolveIfShortened(link, in: context) { changed = true }
        guard link.modelContext != nil, link.deletedAt == nil else { return changed }

        // 0.5) Normaliza URLs viejas: sube `http`→`https` (ATS bloquea el http en claro → no se
        //      podían descargar sus metadatos, p. ej. `http://Macfolio.com`) y pasa el host a
        //      minúsculas. Si la normalizada ya existe en otro enlace, este es duplicado → se borra.
        if normalizeIfNeeded(link, in: context) { changed = true }
        guard link.modelContext != nil, link.deletedAt == nil else { return changed }

        // 1) Metadatos de red si faltan los básicos (imagen/siteName/título/plataforma) o no hay
        //    favicon. `enrichFromNetwork` ya rellena el favicon de respaldo y auto-organiza.
        // El título ALUCINADO/ajeno al enlace ([[TitleCoherence]]) también dispara la pasada de
        // red: recupera el `og:title` REAL (p. ej. «owner/repo» de GitHub) sin necesitar el MLX.
        // Un título EDITADO a mano ([[UserEditLedger]]) NO se considera ajeno ni se refresca.
        let titleEdited = UserEditLedger.isTitleEdited(link.id)
        let titleUnrelated = !titleEdited && TitleCoherence.titleLikelyUnrelated(title: link.title, url: link.url)
        if BatchEnricher.needsEnrichment(link) || (link.faviconURL?.isEmpty != false) || titleUnrelated {
            let overwriteTitle = !titleEdited && (link.title.isEmpty
                || link.title.lowercased() == link.url.urlHost.lowercased()
                || titleUnrelated)
            await MacLinkEnricher.enrichFromNetwork(link, in: context, overwriteTitle: overwriteTitle)
            guard link.modelContext != nil else { return changed }
            // Si se refrescó por título ajeno, limpia el ruido del sitio del `og:title` recién
            // traído («GitHub - owner/repo: …» → «owner/repo»), sin esperar al barrido con IA.
            if titleUnrelated {
                let cleaned = TitleCleaner.clean(link.title, siteName: link.siteName, host: link.url.urlHost)
                if !cleaned.isEmpty, cleaned != link.title { link.title = cleaned }
            }
            changed = true
        }

        // 2) Favicon que CARGUE de verdad: deja persistido el primer candidato válido de la
        //    cascada para que la fila no caiga al monograma y su 1.er candidato ya funcione.
        if await ensureWorkingFavicon(link, allowRender: allowRenderFavicon) { changed = true }
        guard link.modelContext != nil else { return changed }

        // 3) Portada + salud (solo en la pasada exhaustiva del botón).
        if coverAndHealth {
            if await CoverEnsurer.ensure(for: link, in: context, allowSnapshot: allowSnapshot) { changed = true }
            guard link.modelContext != nil else { return changed }
            await MacHealthChecker.check(link)   // el guardado lo hace el llamante
            changed = true
        }
        return changed
    }

    /// Expande un enlace acortado (t.co, bit.ly…) a su URL real y reajusta plataforma/portada
    /// para que se reenriquezca desde la página de verdad. Evita crear un duplicado lógico: si ya
    /// existe otro enlace con esa URL, NO la reescribe. Devuelve `true` si cambió la URL.
    /// `internal` para reutilizarlo desde el alta ([[LinkIngest]]): pegar/arrastrar un t.co debe
    /// resolverse igual que en el barrido.
    @discardableResult
    static func resolveIfShortened(_ link: Bookmark, in context: ModelContext) async -> Bool {
        guard ShortLinkResolver.isShortened(link.url),
              let resolved = await ShortLinkResolver.resolve(link.url),
              link.modelContext != nil else { return false }
        let key = CanonicalURL.key(resolved)
        let duplicate = (((try? context.fetch(FetchDescriptor<Bookmark>(
            predicate: #Predicate { $0.deletedAt == nil }))) ?? [])
            .first { $0.id != link.id && CanonicalURL.key($0.url) == key })
        if duplicate != nil {
            // El acortador apunta a un enlace que YA existe: este t.co es REDUNDANTE. En vez de
            // dejarlo a medias (URL t.co, favicon/imagen de X y descripción inventada), se
            // soft-borra (dedup correcto): el destino canónico ya está en la biblioteca.
            SpotlightIndexer.remove(id: link.id)
            link.deletedAt = Date()
            context.saveLogging()
            return false
        }
        link.url = resolved
        let detection = PlatformDetector.detect(resolved)
        link.platform = detection.platform
        link.contentType = detection.contentType
        link.platformColor = detection.brandColorHex
        // El favicon/portada eran del acortador (logo de X): que se recalculen para el host real.
        link.faviconURL = nil
        link.imageURL = nil
        link.updatedAt = Date()
        return true
    }

    /// Normaliza la URL guardada (sube `http`→`https`, host a minúsculas) y reajusta plataforma/
    /// portada. Arregla enlaces viejos que ATS no podía descargar (http) o duplicados por
    /// mayúsculas. Si la URL normalizada YA existe en otro enlace, este es redundante → soft-delete
    /// (dedup). Devuelve `true` si cambió la URL. Síncrono (no hace red).
    @discardableResult
    private static func normalizeIfNeeded(_ link: Bookmark, in context: ModelContext) -> Bool {
        guard link.modelContext != nil else { return false }
        let normalized = LinkIngest.normalizeURL(link.url)
        guard normalized != link.url else { return false }
        let key = CanonicalURL.key(normalized)
        let duplicate = (((try? context.fetch(FetchDescriptor<Bookmark>(
            predicate: #Predicate { $0.deletedAt == nil }))) ?? [])
            .first { $0.id != link.id && CanonicalURL.key($0.url) == key })
        if duplicate != nil {
            SpotlightIndexer.remove(id: link.id)
            link.deletedAt = Date()
            context.saveLogging()
            return false
        }
        link.url = normalized
        let detection = PlatformDetector.detect(normalized)
        link.platform = detection.platform
        link.contentType = detection.contentType
        link.platformColor = detection.brandColorHex
        link.faviconURL = nil   // recalcular para el esquema/host correctos
        link.imageURL = nil
        link.updatedAt = Date()
        return true
    }

    /// Prueba la cascada de favicon (`faviconURL` guardado → Google → DuckDuckGo, vía
    /// `PreviewImage.favicon`) y, si alguno CARGA como imagen real, lo guarda en `faviconURL`
    /// (solo si cambia, para no invalidar el `@Query` sin necesidad). Usa la `ImageCache`
    /// compartida, así que de paso deja el favicon PRECARGADO para la fila. Devuelve `true` si
    /// dejó un favicon válido distinto al que había.
    @discardableResult
    static func ensureWorkingFavicon(_ link: Bookmark, allowRender: Bool = false) async -> Bool {
        guard link.modelContext != nil, link.fileKind == nil else { return false }
        let host = link.url.urlHost
        let stored = link.faviconURL?.trimmingCharacters(in: .whitespaces)
        var candidates = [stored].compactMap { $0 }.filter { !$0.isEmpty }
        if !host.isEmpty {
            // Rutas ESTÁNDAR que muchas webs NO declaran en el HTML pero sí sirven, antes de los
            // servicios de respaldo (que devuelven un icono genérico para dominios que no conocen).
            candidates += [
                "https://\(host)/favicon.ico",
                "https://\(host)/apple-touch-icon.png",
            ]
        }
        candidates += PreviewImage.favicon(for: link.url)   // Google s2 + DuckDuckGo
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if await SecureImageCache.shared.image(for: url) != nil {
                guard link.modelContext != nil else { return false }
                if link.faviconURL != candidate {
                    link.faviconURL = candidate
                    link.updatedAt = Date()
                    return true
                }
                return false   // el que ya tenía ya cargaba: nada que cambiar
            }
        }
        // ÚLTIMO RECURSO (caro): webs que INYECTAN el favicon/título por JavaScript (Framer/Webflow/
        // SPA), cuyo favicon no está en el HTML estático ni en `/favicon.ico` ni lo tienen los
        // servicios. Renderiza la página UNA vez y lee el `<link rel=icon>` real Y el título en
        // vivo. Solo si se pide (`allowRender`). Punto único [[FaviconRenderer]].
        if allowRender, !host.isEmpty {
            let meta = await FaviconRenderer.render(of: link.url)
            guard link.modelContext != nil else { return false }
            var changed = false
            if let fav = meta.favicon, let url = URL(string: fav),
               await SecureImageCache.shared.image(for: url) != nil,
               link.modelContext != nil, link.faviconURL != fav {
                link.faviconURL = fav
                link.updatedAt = Date()
                changed = true
            }
            if link.modelContext != nil, let t = meta.title, applyRenderedTitle(t, to: link) {
                changed = true
            }
            return changed
        }
        return false
    }

    /// Aplica el título RENDERIZADO (lo que la web muestra AHORA, vía JS) si es mejor que el actual:
    /// el HTML estático a veces trae un título VIEJO (p. ej. «Islet» cuando la web ya se llama
    /// «DynamicLake»). El renderizado es el vigente, así que se prefiere salvo que sea genérico o
    /// igual al actual. Es DETERMINISTA a propósito: la IA juzgaría sobre el MISMO contenido
    /// estático viejo del que salió «Islet», así que no daría una respuesta más certera. Devuelve
    /// `true` si lo cambió.
    @discardableResult
    static func applyRenderedTitle(_ rendered: String, to link: Bookmark) -> Bool {
        guard link.modelContext != nil, !UserEditLedger.isTitleEdited(link.id) else { return false }
        let cleaned = TitleCleaner.clean(rendered, siteName: link.siteName, host: link.url.urlHost)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isMeaningfulTitle(cleaned, host: link.url.urlHost) else { return false }
        let current = link.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.caseInsensitiveCompare(current) != .orderedSame else { return false }
        link.title = cleaned
        link.updatedAt = Date()
        SpotlightIndexer.index(link)
        return true
    }

    /// ¿El título tiene sentido (no es genérico ni solo el dominio)? Evita pisar uno bueno con
    /// «Home»/«Loading»/«React App» que algunas SPAs ponen como `document.title` placeholder.
    static func isMeaningfulTitle(_ t: String, host: String) -> Bool {
        let trimmed = t.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        let lower = trimmed.lowercased()
        let generic: Set<String> = ["home", "inicio", "loading", "cargando", "untitled",
                                    "sin título", "index", "page", "página", "app", "website",
                                    "react app", "vite app", "next app", "create react app"]
        if generic.contains(lower) { return false }
        if lower == host.lowercased() { return false }
        return true
    }

    /// Renderiza la página UNA vez (favicon + título + texto), APLICA favicon y título in situ y
    /// devuelve el TEXTO renderizado para que el llamante lo use como contenido fundamentado de la
    /// IA. Para «Mejorar con IA» de webs JS (dynamicmaclake), cuyo HTML estático no da favicon,
    /// título actual ni prosa. `nil` si no hubo texto aprovechable.
    static func renderAndApplyMeta(_ link: Bookmark) async -> String? {
        guard link.modelContext != nil else { return nil }
        let meta = await FaviconRenderer.render(of: link.url)
        guard link.modelContext != nil else { return nil }
        if let fav = meta.favicon, let url = URL(string: fav),
           await SecureImageCache.shared.image(for: url) != nil,
           link.modelContext != nil, link.faviconURL != fav {
            link.faviconURL = fav
            link.updatedAt = Date()
        }
        if link.modelContext != nil, let t = meta.title { applyRenderedTitle(t, to: link) }
        return meta.text
    }

    // MARK: - Pasada COMPLETA (botón de Mantenimiento) — TODOS, sin saltarse ninguno

    /// Recorre TODOS los enlaces activos asegurando metadatos + favicon + portada + salud.
    /// Ignora el libro mayor (acción manual exhaustiva) y NO tiene límite: avanza hasta acabar.
    /// Cancelable con `Task.cancel()`. Devuelve cuántos enlaces cambiaron.
    @discardableResult
    static func completeAll(in context: ModelContext,
                            onProgress: @MainActor (Int, Int) -> Void = { _, _ in }) async -> Int {
        let all = ((try? context.fetch(FetchDescriptor<Bookmark>())) ?? [])
            .filter { $0.deletedAt == nil }
        guard !all.isEmpty else { return 0 }
        var touched = 0
        for (index, link) in all.enumerated() {
            if Task.isCancelled { break }
            onProgress(index, all.count)
            guard link.modelContext != nil else { continue }
            // Pasada manual exhaustiva: permite renderizar para sacar favicons inyectados por JS.
            if await complete(link, in: context, coverAndHealth: true, allowRenderFavicon: true) { touched += 1 }
            if link.modelContext != nil { EnrichmentLedger.markCompleterAttempt(link.id) }
        }
        context.saveLogging()
        return touched
    }

    // MARK: - Autocurativo en 2.º plano — incremental, cede ante la interacción

    private static var ranThisSession = false
    /// Tope por sesión: el resto se cubre en sesiones siguientes (no de golpe). La portada y la
    /// salud tienen sus propias pasadas, así que aquí solo arreglamos metadatos+favicon (barato).
    private static let maxPerPass = 40

    /// Mop-up incremental del backlog importado: a los enlaces aún incompletos que NO se han
    /// intentado ([[EnrichmentLedger]]) les asegura metadatos + favicon que cargue, cediendo el
    /// paso mientras el usuario interactúa (sin tocar la GPU/MLX). Una vez por sesión.
    static func runIfNeeded(in context: ModelContext) async {
        guard !ranThisSession else { return }
        ranThisSession = true
        await UserActivityMonitor.shared.waitUntilIdle()
        if Task.isCancelled { return }
        let active = ((try? context.fetch(FetchDescriptor<Bookmark>(
            predicate: #Predicate { $0.deletedAt == nil }))) ?? [])
        var processed = 0, changed = 0
        for link in active {
            if Task.isCancelled || processed >= maxPerPass { break }
            guard link.modelContext != nil else { continue }
            // Solo los incompletos aún NO intentados: sin favicon, sin metadatos básicos o
            // acortados sin resolver (t.co…).
            guard !EnrichmentLedger.hasCompleterAttempt(link.id),
                  (link.faviconURL?.isEmpty != false)
                    || BatchEnricher.needsEnrichment(link)
                    || ShortLinkResolver.isShortened(link.url)
            else { continue }
            await UserActivityMonitor.shared.waitUntilIdle()   // cede mientras interactúa
            if Task.isCancelled { break }
            if await complete(link, in: context, coverAndHealth: false) { changed += 1 }
            if link.modelContext != nil { EnrichmentLedger.markCompleterAttempt(link.id) }
            processed += 1
        }
        if changed > 0 { context.saveLogging(); WidgetReloader.reload() }
    }
}
