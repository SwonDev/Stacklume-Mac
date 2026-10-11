import SwiftUI
import SwiftData
@preconcurrency import Translation
import StacklumeCore
import StacklumePersistence

extension Notification.Name {
    /// Un alta detectó texto en otro idioma (sobre todo un TÍTULO en script no latino): pide al
    /// motor automático que lo traduzca al idioma de la app. Lo emite [[LinkIngest]] tras enriquecer.
    static let stacklumeAutoTranslate = Notification.Name("stacklume.autoTranslate")
}

/// Textos de un enlace que cruzan al closure de la `TranslationSession` (Sendable: ids + Strings,
/// NUNCA el `@Model`).
private struct AutoTranslateTexts: Sendable {
    let id: PersistentIdentifier
    let title: String?
    let details: String?
    let summary: String?
}

/// Traduce AUTOMÁTICAMENTE al idioma de la app los textos extranjeros —sobre todo el TÍTULO en
/// script no latino (chino, japonés, árabe…)— en cuanto se añade un enlace, sin que el usuario
/// tenga que ir al lote «Traducir» de Mantenimiento. Reutiliza la detección de [[LinkTranslator]]
/// y el framework `Translation` de Apple (on-device), que SOLO funciona con una sesión de VISTA
/// (`.translationTask`): por eso este motor vive montado de forma permanente en la ventana
/// principal. Es silencioso (sin UI de progreso) y procesa POR IDIOMA DE ORIGEN (una sesión por
/// par de idiomas, igual que el lote manual). La PRIMERA vez que se traduce desde un idioma,
/// macOS puede pedir descargar su paquete (una vez).
private struct AutoTranslateModifier: ViewModifier {
    @Environment(\.modelContext) private var context

    @State private var config: TranslationSession.Configuration?
    @State private var items: [AutoTranslateTexts] = []
    /// Grupos pendientes por idioma de origen (solo ids: el `@Model` no cruza al closure).
    @State private var groups: [(lang: String, ids: [PersistentIdentifier])] = []
    @State private var busy = false
    @State private var madeAny = false
    /// Enlaces ya intentados en esta sesión: si la traducción falla (idioma no descargado/
    /// rechazado), NO se reintenta en bucle. Se reintenta al reabrir la app o desde Mantenimiento.
    @State private var attempted: Set<PersistentIdentifier> = []

    func body(content: Content) -> some View {
        content
            // Al abrir la ventana, traduce lo que quedó pendiente (títulos en chino ya guardados).
            .task {
                try? await Task.sleep(for: .seconds(6))
                kick()
            }
            // Cada alta con texto extranjero pide traducir (no-op si ya está procesando). Si la
            // petición viene FORZADA (botón «Mejorar con IA»), se limpia el ledger de intentos para
            // que vuelva a intentar lo que antes falló (p. ej. tras descargar el idioma).
            .onReceive(NotificationCenter.default.publisher(for: .stacklumeAutoTranslate)) { note in
                if note.userInfo?["force"] as? Bool == true { attempted.removeAll() }
                kick()
            }
            // Sesión de traducción de Apple: se activa al fijar `config`; cada idioma reejecuta el
            // closure con su `TranslationSession`. Solo cruzan Strings + ids (Sendable).
            .translationTask(config) { session in
                let snapshot = items
                var results: [AutoTranslateTexts] = []
                for item in snapshot {
                    var title: String?, details: String?, summary: String?
                    if let o = item.title { title = try? await session.translate(o).targetText }
                    if let o = item.details { details = try? await session.translate(o).targetText }
                    if let o = item.summary { summary = try? await session.translate(o).targetText }
                    results.append(AutoTranslateTexts(id: item.id, title: title, details: details, summary: summary))
                }
                apply(results)
                advance()
            }
    }

    private var targetLanguage: String {
        AppSettingsStore.current(in: context).language.rawValue
    }

    /// Arranca un ciclo si no hay otro en marcha: agrupa por idioma de origen los enlaces que
    /// necesitan traducción y aún no se han intentado esta sesión.
    private func kick() {
        guard !busy, config == nil else { return }
        let links = ((try? context.fetch(FetchDescriptor<Bookmark>())) ?? [])
            .filter { $0.deletedAt == nil && LinkTranslator.needsTranslation($0)
                && !attempted.contains($0.persistentModelID) }
        guard !links.isEmpty else { return }
        var byLang: [String: [PersistentIdentifier]] = [:]
        for link in links {
            let lang = LinkTranslator.sourceIdentifier(for: link) ?? "und"
            byLang[lang, default: []].append(link.persistentModelID)
        }
        groups = byLang.map { (lang: $0.key, ids: $0.value) }
        madeAny = false
        busy = true
        advance()
    }

    /// Prepara el siguiente idioma de origen: hace el snapshot de los textos extranjeros y fija la
    /// `Configuration` (dispara el `.translationTask`). Si no quedan grupos, cierra el ciclo.
    private func advance() {
        guard !groups.isEmpty else {
            config = nil
            busy = false
            if madeAny { SpotlightIndexer.reindexAll(in: context); WidgetReloader.reload() }
            // ¿Llegaron enlaces nuevos (no intentados) mientras traducíamos? Procésalos.
            let stillPending = ((try? context.fetch(FetchDescriptor<Bookmark>())) ?? [])
                .contains { $0.deletedAt == nil && LinkTranslator.needsTranslation($0)
                    && !attempted.contains($0.persistentModelID) }
            if stillPending { kick() }
            return
        }
        let group = groups.removeFirst()
        let all = (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
        var byID: [PersistentIdentifier: Bookmark] = [:]
        for link in all { byID[link.persistentModelID] = link }
        items = group.ids.compactMap { id in
            attempted.insert(id)   // marcado como intentado (aunque falle, no se reintenta en bucle)
            guard let link = byID[id], link.modelContext != nil else { return nil }
            // Título: solo script no latino (los nombres en inglés se respetan). Descripción/resumen:
            // solo si son traducibles (inglés real o no latino) — los ya en español NO se tocan.
            let title = LinkTranslator.isForeign(link.title) ? link.title : nil
            let details = (link.details.map { LinkTranslator.isTranslatableDescription($0) } == true) ? link.details : nil
            let summary = (link.summary.map { LinkTranslator.isTranslatableDescription($0) } == true) ? link.summary : nil
            guard title != nil || details != nil || summary != nil else { return nil }
            return AutoTranslateTexts(id: id, title: title, details: details, summary: summary)
        }
        guard !items.isEmpty, group.lang != "und" else { advance(); return }
        let sourceLang = Locale.Language(identifier: group.lang)
        let target = Locale.Language(identifier: targetLanguage)
        // CLAVE: NO disparar el diálogo de DESCARGA de idiomas de Apple (molesto, y reaparecía en
        // bucle: «se cierra y se vuelve a abrir solo»). Solo se traduce con Apple si el par de
        // idiomas YA está INSTALADO. Si falta, NO se fija la sesión (no hay prompt): la traducción
        // la hace la IA LOCAL (al alta y en «Mejorar con IA») o el lote MANUAL de Mantenimiento
        // (donde el prompt sí es esperado, porque lo dispara el usuario a propósito).
        Task { @MainActor in
            let installed = await LanguageAvailability().status(from: sourceLang, to: target) == .installed
            if installed {
                config = TranslationSession.Configuration(source: sourceLang, target: target)
            } else {
                advance()   // idioma no instalado → saltar este grupo SIN molestar
            }
        }
    }

    /// Escribe las traducciones recibidas en los enlaces (por id).
    private func apply(_ results: [AutoTranslateTexts]) {
        let all = (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
        var byID: [PersistentIdentifier: Bookmark] = [:]
        for link in all { byID[link.persistentModelID] = link }
        for result in results {
            guard let link = byID[result.id], link.modelContext != nil else { continue }
            var changed = false
            if let t = result.title, !t.isEmpty, t != link.title { link.title = t; changed = true }
            if let d = result.details, !d.isEmpty, d != link.details { link.details = d; changed = true }
            if let s = result.summary, !s.isEmpty, s != link.summary { link.summary = s; changed = true }
            if changed { link.updatedAt = Date(); SpotlightIndexer.index(link); madeAny = true }
        }
        context.saveLogging()
    }
}

extension View {
    /// Monta el motor de traducción automática de textos extranjeros (títulos no latinos, etc.).
    /// Aplícalo UNA vez en la ventana principal.
    func autoTranslateForeignText() -> some View {
        modifier(AutoTranslateModifier())
    }
}
