import SwiftUI
import SwiftData
@preconcurrency import Translation
import StacklumeCore
import StacklumeDesignSystem
import StacklumeMetadata
import StacklumePersistence

/// Mantenimiento de la biblioteca (paridad con el iPhone, adaptado a macOS):
/// enriquecer metadatos en lote (con IA o solo red), comprobar enlaces rotos,
/// buscar duplicados y vaciar la papelera. Incluye la preferencia «Confirmar
/// antes de eliminar» (`AppSettings.confirmBeforeDelete`).
struct MaintenanceSettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.themePalette) private var palette
    @Query private var settingsList: [AppSettings]
    /// Enlaces en papelera (para el contador). `@Query` → solo se recalcula cuando
    /// cambian los datos, no en cada render del Form (a diferencia de un `fetchCount`).
    @Query(filter: #Predicate<Bookmark> { $0.deletedAt != nil }) private var trashedLinks: [Bookmark]
    @State private var runner = LocalAIRunner.shared

    @State private var maintaining = false
    @State private var progress = (done: 0, total: 0)
    @State private var label = ""
    @State private var statusMessage: String?
    @State private var showStatus = false
    @State private var showEmptyTrash = false
    @State private var showDuplicates = false
    @State private var showEnrichOptions = false
    @State private var showAISettings = false
    @State private var enrichTask: Task<Void, Never>?

    // Traducción con el framework `Translation` de Apple: se procesa POR IDIOMA DE ORIGEN
    // (una `Configuration` por idioma; la sesión llega vía `.translationTask`). Solo cruzan
    // Strings + ids (Sendable) entre el MainActor y el closure de la sesión.
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var translationGroups: [(lang: String, links: [Bookmark])] = []
    @State private var translationItems: [LinkTexts] = []
    @State private var translationDone = 0
    @State private var translationMade = 0
    @State private var translationTotal = 0
    /// Si la traducción se lanzó ENCADENADA tras el botón universal, lleva los recuentos de las
    /// fases previas (completar + IA) para mostrar un único resumen al terminar la traducción.
    /// `nil` = la traducción se lanzó suelta desde su propio botón.
    @State private var pendingEnrichCounts: (completados: Int, ai: Int)?

    private var trashedCount: Int { trashedLinks.count }

    private var aiReady: Bool { runner.isReady }
    private var language: String { (settingsList.first?.language ?? .es).rawValue }

    // MARK: - Estado del modelo de IA

    /// `true` mientras el modelo carga o se descarga (anima el icono).
    private var aiBusy: Bool {
        switch runner.state { case .loading, .downloading: return true; default: return false }
    }

    private var aiStatusText: String {
        if runner.isDeactivated { return "Desactivada — actívala para usar las funciones de IA" }
        switch runner.state {
        case .ready: return "Cargada y lista"
        case .loading: return "Cargando en memoria…"
        case .downloading(let fraction): return "Descargando… \(Int((fraction * 100).rounded()))%"
        case .failed(let message): return "Error: \(message)"
        case .notLoaded:
            return runner.isAvailable
                ? "Descargada · pulsa «Cargar» para usarla"
                : "No instalada · se descarga la primera vez que uses una función de IA"
        }
    }

    private var aiStatusIcon: String {
        if runner.isDeactivated { return "pause.circle.fill" }
        switch runner.state {
        case .ready: return "checkmark.seal.fill"
        case .loading, .downloading: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        case .notLoaded: return runner.isAvailable ? "arrow.down.circle.fill" : "sparkles"
        }
    }

    private var aiStatusColor: Color {
        if runner.isDeactivated { return palette.textSecondary }
        switch runner.state {
        case .ready: return .green
        case .failed: return Color(hex: "#F97316")
        default: return palette.accent
        }
    }

    @ViewBuilder
    private var aiActionButton: some View {
        switch runner.state {
        case .loading, .downloading:
            ProgressView().controlSize(.small)
        default:
            if runner.isDeactivated || (!runner.isReady && runner.isAvailable) {
                Button(runner.isDeactivated ? "Activar" : "Cargar") { loadAIModel() }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
            } else if runner.isReady {
                Button("Desactivar") { runner.deactivate() }
                    .buttonStyle(.bordered)
            }
        }
    }

    /// Carga (o reactiva) el modelo local en memoria a petición del usuario.
    private func loadAIModel() {
        Task { @MainActor in _ = await runner.ensureReady(userInitiated: true) }
    }

    private var confirmBinding: Binding<Bool> {
        Binding(
            get: { settingsList.first?.confirmBeforeDelete ?? true },
            set: { newValue in
                let current = AppSettingsStore.current(in: context)
                current.confirmBeforeDelete = newValue
                context.saveLogging()
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Confirmar antes de eliminar", isOn: confirmBinding)
            } footer: {
                Text("Pide confirmación antes de mover enlaces a la papelera o borrarlos definitivamente.")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            }

            Section {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: aiStatusIcon)
                        .font(.title3)
                        .foregroundStyle(aiStatusColor)
                        .frame(width: 26)
                        .symbolEffect(.pulse, isActive: aiBusy)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(runner.selectedModel.displayName)
                            .stacklumeFont(.callout.weight(.medium))
                            .foregroundStyle(palette.textPrimary)
                        Text(aiStatusText)
                            .stacklumeFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                    }
                    Spacer()
                    aiActionButton
                }
                Button("Elegir modelo y opciones de IA") { showAISettings = true }
            } header: {
                Text("Inteligencia artificial · 100 % en tu Mac")
            } footer: {
                Text("La inferencia se ejecuta en tu Mac. Elige el modelo local y controla las consultas web desde las opciones de IA.")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            }

            Section {
                Button { showEnrichOptions = true } label: {
                    Label("Enriquecer biblioteca", systemImage: "wand.and.stars.inverse")
                }
                .disabled(maintaining)
                Button { fillMissingCovers() } label: {
                    Label("Rellenar portadas que faltan", systemImage: "photo.on.rectangle.angled")
                }
                .disabled(maintaining)
                Button { indexLocalDocuments() } label: {
                    Label("Indexar PDFs, EPUB e imágenes", systemImage: "text.viewfinder")
                }
                .disabled(maintaining)
                Button { regenerateCollectionIcons() } label: {
                    Label("Regenerar iconos de colecciones (IA)", systemImage: "wand.and.stars")
                }
                .disabled(maintaining || !runner.isAvailable)
                Button { generateSummaries() } label: {
                    Label("Generar resúmenes (TL;DR) con IA", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .disabled(maintaining || !runner.isAvailable)
                Button { translateForeignLinks() } label: {
                    Label("Traducir descripciones a español (cualquier idioma)", systemImage: "character.bubble")
                }
                .disabled(maintaining || !runner.isAvailable)
                Button { checkHealth() } label: {
                    Label("Comprobar enlaces", systemImage: "heart.text.square")
                }
                .disabled(maintaining)
                Button { showDuplicates = true } label: {
                    Label("Buscar duplicados", systemImage: "doc.on.doc")
                }
                .disabled(maintaining)
                Button { cleanTags() } label: {
                    Label("Optimizar etiquetas (limpiar y fusionar)", systemImage: "tag.slash")
                }
                .disabled(maintaining)
                Button { removeUnusedTags() } label: {
                    Label("Eliminar etiquetas y colecciones sin usar", systemImage: "minus.circle")
                }
                .disabled(maintaining)
                Button { mergeCollections() } label: {
                    Label("Fusionar colecciones y etiquetas duplicadas («Development» → «Desarrollo»…)", systemImage: "rectangle.stack.badge.minus")
                }
                .disabled(maintaining)
                Button { cleanTitles() } label: {
                    Label("Limpiar títulos (quitar «- YouTube», «| GitHub»…)", systemImage: "textformat.abc.dottedunderline")
                }
                .disabled(maintaining)
            } header: {
                Text("Biblioteca")
            } footer: {
                Text(aiReady
                     ? "Enriquecer usa el modelo local elegido para mejorar títulos, redactar descripciones y proponer colecciones y etiquetas, rellenando solo lo que falte."
                     : "Completa los metadatos que falten. Para un enriquecido inteligente carga el modelo en la sección IA del lateral.")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            }

            Section {
                Button(role: .destructive) {
                    if confirmBinding.wrappedValue { showEmptyTrash = true } else { emptyTrash() }
                } label: {
                    Label("Vaciar papelera", systemImage: "trash")
                }
                .disabled(trashedCount == 0)
            } header: {
                Text("Papelera")
            } footer: {
                Text(trashedCount == 0
                     ? "No hay enlaces eliminados."
                     : "\(trashedCount) enlace\(trashedCount == 1 ? "" : "s") eliminado\(trashedCount == 1 ? "" : "s"). Vaciar la papelera los borra permanentemente.")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(WindowBackground())
        .overlay { if maintaining { progressOverlay } }
        // Sesión de traducción de Apple: se activa al fijar `translationConfig`; cada cambio
        // (un idioma de origen) reejecuta el closure con su `TranslationSession`. Las llamadas
        // a la sesión se hacen AQUÍ (closure no aislado); solo cruzan Strings con el MainActor.
        .translationTask(translationConfig) { session in
            // El closure es @MainActor: se accede al estado DIRECTAMENTE (sin `await` a
            // métodos propios, que haría «cruzar» la sesión a contexto no aislado).
            let items = translationItems
            var results: [LinkTexts] = []
            for item in items {
                var title: String?, details: String?, summary: String?
                if let original = item.title { title = try? await session.translate(original).targetText }
                if let original = item.details { details = try? await session.translate(original).targetText }
                if let original = item.summary { summary = try? await session.translate(original).targetText }
                results.append(LinkTexts(id: item.id, title: title, details: details, summary: summary))
            }
            applyTranslations(results)
        }
        .sheet(isPresented: $showDuplicates) { DuplicatesView() }
        .sheet(isPresented: $showAISettings) {
            EditorScaffold(title: "IA", confirmTitle: "Listo", cancelTitle: nil,
                           onCancel: { showAISettings = false }, onConfirm: { showAISettings = false }) {
                AISettingsView()
            }
            .frame(width: 540, height: 560)
            .themedSheet(palette)
        }
        .alert("Stacklume", isPresented: $showStatus) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text(statusMessage ?? "")
        }
        .confirmationDialog("Enriquecer biblioteca", isPresented: $showEnrichOptions, titleVisibility: .visible) {
            if aiReady {
                Button("Completar lo que falte + IA — recomendado") { startEnrich(useAI: true) }
                Button("Re-enriquecer TODO a fondo (cada enlace)") { startEnrich(useAI: true, deep: true) }
                Button("Solo completar (sin IA)") { startEnrich(useAI: false) }
            } else {
                Button("Completar todos los enlaces") { startEnrich(useAI: false) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(aiReady
                 ? "Pasa por TODOS los enlaces asegurando favicon, imagen y metadatos. Con IA, además mejora títulos, redacta descripciones (renderizando las webs que lo necesiten), traduce al español y propone colecciones y etiquetas. «A fondo» RE-HACE cada enlace, lo tenga ya o no (más lento pero no deja ninguno mal)."
                 : "Pasa por TODOS los enlaces asegurando favicon, imagen y metadatos que falten, y comprueba que funcionen. Para un enriquecido inteligente con IA, cárgala en la sección IA del lateral.")
        }
        .confirmationDialog("¿Vaciar la papelera?", isPresented: $showEmptyTrash, titleVisibility: .visible) {
            Button("Borrar permanentemente", role: .destructive) { emptyTrash() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Esta acción no se puede deshacer.")
        }
    }

    private var progressOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: DesignSystem.Spacing.sm) {
                ProgressView()
                Text(label).stacklumeFont(.subheadline).foregroundStyle(palette.textPrimary)
                if progress.total > 0 {
                    Text("\(progress.done) / \(progress.total)")
                        .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                }
                if enrichTask != nil {
                    Button("Detener") { enrichTask?.cancel() }
                        .buttonStyle(.bordered)
                        .tint(palette.accent)
                        .padding(.top, DesignSystem.Spacing.xs)
                }
            }
            .padding(DesignSystem.Spacing.lg)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    /// Lanza la pasada universal en primer plano. Cancelable con «Detener». SIEMPRE corre
    /// primero la CAPA GARANTIZADA (sin IA) sobre TODOS los enlaces ([[LibraryCompleter]]):
    /// favicon que cargue + imagen + metadatos + salud, sin saltarse ninguno. Si `useAI`,
    /// además pasa la IA local en BUCLE por tandas de 200 hasta agotar los pendientes
    /// (anti-bucle-infinito: si una tanda no mejora ninguno, para).
    private func startEnrich(useAI: Bool, deep: Bool = false) {
        maintaining = true
        label = "Completando todos los enlaces…"
        progress = (0, 0)
        enrichTask = Task {
            // 1) CAPA GARANTIZADA: TODOS los enlaces (favicon válido + imagen + metadatos + salud).
            let completados = await LibraryCompleter.completeAll(in: context) { d, t in
                progress = (d, t)
            }

            // 2) CAPA IA (opcional): mejora título/descripción/colección/etiquetas de los que aún
            //    lo necesiten, en tandas, hasta agotar.
            var aiEnriquecidos = 0
            if useAI, !Task.isCancelled {
                if deep {
                    // A FONDO: re-enriquece CADA enlace que exista (force) — título, descripción,
                    // traducción, colección y etiquetas —, RENDERIZANDO los que no dan texto (SPAs)
                    // y SIN la puerta de actividad (es manual, da igual lo que tarde). No deja ninguno.
                    label = "Re-enriqueciendo a fondo cada enlace…"
                    progress = (0, 0)
                    aiEnriquecidos = await AIBatchEnricher.enrich(
                        in: context, provider: "liquid", language: language,
                        limit: Int.max, ignoreLedger: true, force: true,
                        renderIfEmpty: true, respectActivityGate: false
                    ) { d, t in progress = (d, t) }
                } else {
                    label = "Enriqueciendo con IA…"
                    progress = (0, 0)
                    let batchSize = 200
                    var pendientesPrevios = Int.max
                    repeat {
                        if Task.isCancelled { break }
                        let all = (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
                        let pendientesAhora = all.filter {
                            $0.deletedAt == nil && AIBatchEnricher.needsAIEnrichment($0)
                        }.count
                        guard pendientesAhora > 0, pendientesAhora < pendientesPrevios else { break }
                        pendientesPrevios = pendientesAhora
                        let tandaTotal = min(pendientesAhora, batchSize)
                        let baseOffset = aiEnriquecidos
                        // Manual → renderiza los SPAs sin texto y NO pausa por actividad.
                        let tandaEnriquecidos = await AIBatchEnricher.enrich(
                            in: context, provider: "liquid", language: language,
                            limit: batchSize, ignoreLedger: true,
                            renderIfEmpty: true, respectActivityGate: false
                        ) { d, _ in
                            progress = (baseOffset + d, baseOffset + tandaTotal)
                        }
                        aiEnriquecidos += tandaEnriquecidos
                        if tandaEnriquecidos == 0 { break }
                    } while !Task.isCancelled
                }
            }

            // 2b) DESCRIPCIONES en español: traduce de cualquier idioma Y enriquece las cortas,
            //     regenerando SOLO la descripción con IA (el título/nombre se respeta). Es lo que
            //     pidió el usuario: «descripciones en español siempre».
            var descripcionesES = 0
            if useAI, !Task.isCancelled {
                descripcionesES = await regenerateSpanishDescriptions()
            }

            let ai = aiEnriquecidos + descripcionesES
            if Task.isCancelled {
                finishUniversal(completados: completados, ai: ai, traducidos: 0, cancelled: true)
                return
            }
            // 3) RED DE SEGURIDAD: traducción de Apple de lo que SIGA en otro idioma (descripciones
            //    que el LLM pudo «ecoar» en inglés, o el camino sin IA). Encadenada: su final
            //    muestra el resumen único. Si no hay nada que traducir, cierra directamente.
            pendingEnrichCounts = (completados, ai)
            label = "Traduciendo a español lo que falte…"
            beginTranslationPhase()
        }
    }

    /// Regenera en español la descripción de los enlaces que lo necesitan (vacía, corta o en otro
    /// idioma). Progreso y cancelable. Devuelve cuántas se rehicieron.
    private func regenerateSpanishDescriptions() async -> Int {
        label = "Descripciones en español…"; progress = (0, 0)
        let links = ((try? context.fetch(FetchDescriptor<Bookmark>())) ?? [])
            .filter { $0.deletedAt == nil && AIBatchEnricher.needsSpanishDescription($0) }
        guard !links.isEmpty else { return 0 }
        var made = 0
        for (index, link) in links.enumerated() {
            if Task.isCancelled { break }
            progress = (index, links.count)
            if link.modelContext != nil,
               await AIBatchEnricher.regenerateDescription(
                link, in: context, provider: "liquid", language: language) {
                made += 1
            }
        }
        return made
    }

    /// Cierra la pasada universal: reindexa/recarga si hubo cambios y muestra un único resumen.
    private func finishUniversal(completados: Int, ai: Int, traducidos: Int, cancelled: Bool) {
        if completados + ai + traducidos > 0 {
            SpotlightIndexer.reindexAll(in: context)
            WidgetReloader.reload()
        }
        maintaining = false
        enrichTask = nil
        present(universalSummary(completados: completados, ai: ai, traducidos: traducidos, cancelled: cancelled))
    }

    /// Mensaje de resultado de la pasada universal, distinguiendo cada capa.
    private func universalSummary(completados: Int, ai: Int, traducidos: Int, cancelled: Bool) -> String {
        let prefix = cancelled ? "Detenido. " : ""
        if completados == 0 && ai == 0 && traducidos == 0 {
            return cancelled ? "Detenido sin cambios." : "Todos tus enlaces ya estaban completos."
        }
        var parts: [String] = []
        if completados > 0 {
            parts.append("completé \(completados) (favicon, imagen y metadatos)")
        }
        if ai > 0 {
            parts.append("redacté en español \(ai) descripción\(ai == 1 ? "" : "es")")
        }
        if traducidos > 0 {
            parts.append("traduje \(traducidos)")
        }
        return prefix + parts.joined(separator: ", ") + "."
    }

    /// Genera el TL;DR (`summary`) con IA de los enlaces que aún no lo tienen, en segundo
    /// plano, con progreso y cancelable. Punto único [[LinkSummarizer]]. Escanear sin abrir.
    private func generateSummaries() {
        maintaining = true; label = "Generando resúmenes con IA…"; progress = (0, 0)
        enrichTask = Task {
            let links = ((try? context.fetch(FetchDescriptor<Bookmark>())) ?? [])
                .filter { $0.deletedAt == nil && ($0.summary?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) }
            guard !links.isEmpty else {
                maintaining = false; enrichTask = nil
                present("Todos tus enlaces ya tienen resumen.")
                return
            }
            var done = 0, made = 0
            for link in links {
                if Task.isCancelled { break }
                progress = (done, links.count)
                if link.modelContext != nil,
                   await LinkSummarizer.summarize(link, in: context, language: language) { made += 1 }
                done += 1
            }
            let cancelled = Task.isCancelled
            if made > 0 { SpotlightIndexer.reindexAll(in: context); WidgetReloader.reload() }
            maintaining = false; enrichTask = nil
            present(cancelled
                    ? "Detenido. \(made) resumen(es) generado(s)."
                    : (made == 0
                       ? "No se pudieron generar resúmenes (¿está la IA disponible?)."
                       : "Generé \(made) resumen(es) (TL;DR)."))
        }
    }

    /// Traduce al idioma de la app los enlaces cuyos textos están en un idioma que no es
    /// inglés ni español, con el framework `Translation` de Apple (on-device, fiable). Como
    /// la sesión es POR PAR de idiomas, se agrupan los enlaces por idioma de ORIGEN y se
    /// procesa un grupo por cada `Configuration` (ver `advanceTranslation`/`runTranslationGroup`).
    /// En la primera traducción de un idioma, macOS puede pedir descargar su paquete.
    /// Botón SUELTO de traducción: no viene encadenado del botón universal.
    private func translateForeignLinks() {
        pendingEnrichCounts = nil
        beginTranslationPhase()
    }

    /// Traduce a español los textos extranjeros (títulos en script no latino; descripciones en
    /// CUALQUIER idioma que no sea español, incluido el inglés). Reutilizado por el botón suelto y,
    /// ENCADENADO, como red de seguridad del botón universal. Si no hay nada que traducir, cierra
    /// según el contexto (resumen universal si venía encadenado).
    private func beginTranslationPhase() {
        let links = ((try? context.fetch(FetchDescriptor<Bookmark>())) ?? [])
            .filter { $0.deletedAt == nil && LinkTranslator.needsTranslation($0) }
        guard !links.isEmpty else {
            if let c = pendingEnrichCounts {
                pendingEnrichCounts = nil
                finishUniversal(completados: c.completados, ai: c.ai, traducidos: 0, cancelled: false)
            } else {
                present("No hay enlaces en otros idiomas que traducir.")
            }
            return
        }
        var groups: [String: [Bookmark]] = [:]
        for link in links {
            let lang = LinkTranslator.sourceIdentifier(for: link) ?? "und"
            groups[lang, default: []].append(link)
        }
        translationGroups = groups.map { (lang: $0.key, links: $0.value) }
        translationTotal = links.count
        translationDone = 0
        translationMade = 0
        maintaining = true
        label = "Traduciendo enlaces a tu idioma…"
        progress = (0, translationTotal)
        advanceTranslation()
    }

    /// Prepara el SIGUIENTE idioma de origen pendiente: saca su grupo, hace el snapshot de
    /// los textos extranjeros y fija la `Configuration` (dispara el `.translationTask`). Si
    /// no quedan grupos, cierra y muestra el resultado.
    private func advanceTranslation() {
        guard !translationGroups.isEmpty else {
            translationConfig = nil
            if let c = pendingEnrichCounts {
                // Venía ENCADENADO del botón universal: un único resumen (finishUniversal reindexa).
                pendingEnrichCounts = nil
                finishUniversal(completados: c.completados, ai: c.ai, traducidos: translationMade, cancelled: false)
            } else {
                maintaining = false
                if translationMade > 0 { SpotlightIndexer.reindexAll(in: context); WidgetReloader.reload() }
                present(translationMade == 0
                        ? "No se pudo traducir (revisa que el idioma esté disponible para descargar)."
                        : "Traduje \(translationMade) enlace(s) a tu idioma.")
            }
            return
        }
        let group = translationGroups.removeFirst()
        translationItems = group.links.compactMap { link in
            guard link.modelContext != nil else { return nil }
            // Títulos: solo script no latino (nombres en inglés se respetan). Descripciones: solo
            // inglés real o script no latino (conservador, sin cascada de idiomas mal detectados).
            let title = LinkTranslator.isForeign(link.title) ? link.title : nil
            let details = (link.details.map { LinkTranslator.isTranslatableDescription($0) } == true) ? link.details : nil
            let summary = (link.summary.map { LinkTranslator.isTranslatableDescription($0) } == true) ? link.summary : nil
            guard title != nil || details != nil || summary != nil else { return nil }
            return LinkTexts(id: link.persistentModelID, title: title, details: details, summary: summary)
        }
        let source: Locale.Language? = group.lang == "und" ? nil : Locale.Language(identifier: group.lang)
        translationConfig = TranslationSession.Configuration(
            source: source, target: Locale.Language(identifier: language))
    }

    /// Aplica las traducciones recibidas a los enlaces (por id), actualiza el progreso y
    /// pasa al siguiente idioma de origen.
    private func applyTranslations(_ results: [LinkTexts]) {
        let all = (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
        var byID: [PersistentIdentifier: Bookmark] = [:]
        for link in all { byID[link.persistentModelID] = link }
        for result in results {
            translationDone += 1
            progress = (translationDone, translationTotal)
            guard let link = byID[result.id], link.modelContext != nil else { continue }
            var changed = false
            // Solo cuenta como traducción si el texto CAMBIÓ: Apple Translation a veces devuelve el
            // original (eco por idioma no instalado), y sin este guard el contador inflaba el total.
            if let t = result.title, !t.isEmpty, t != link.title { link.title = t; changed = true }
            if let d = result.details, !d.isEmpty, d != link.details { link.details = d; changed = true }
            if let s = result.summary, !s.isEmpty, s != link.summary { link.summary = s; changed = true }
            if changed { link.updatedAt = Date(); SpotlightIndexer.index(link); translationMade += 1 }
        }
        context.saveLogging()
        advanceTranslation()
    }

    private func checkHealth() {
        maintaining = true; label = "Comprobando enlaces…"; progress = (0, 0)
        Task {
            let count = await MacHealthChecker.checkAll(in: context) { d, t in progress = (d, t) }
            maintaining = false
            present("Comprobados \(count) enlaces.")
        }
    }

    /// Rellena la portada de TODOS los enlaces que no tienen imagen, sin IA: punto único
    /// [[CoverEnsurer]] (og:image/`<img>` hero del HTML → captura del hero renderizado para
    /// las SPAs). Las capturas van serializadas (una ventana a la vez), con progreso y
    /// cancelable con «Detener». Cierra el círculo de «adquirir todas las imágenes que faltan».
    private func fillMissingCovers() {
        maintaining = true; label = "Rellenando portadas…"; progress = (0, 0)
        enrichTask = Task {
            let links = ((try? context.fetch(FetchDescriptor<Bookmark>())) ?? [])
                .filter { $0.deletedAt == nil && !CoverEnsurer.hasCover($0) }
            guard !links.isEmpty else {
                maintaining = false; enrichTask = nil
                present("Todos tus enlaces ya tienen portada.")
                return
            }
            var filled = 0
            for (index, link) in links.enumerated() {
                if Task.isCancelled { break }
                progress = (index, links.count)
                if link.modelContext != nil, await CoverEnsurer.ensure(for: link, in: context) {
                    filled += 1
                }
            }
            let cancelled = Task.isCancelled
            if filled > 0 { WidgetReloader.reload() }
            maintaining = false; enrichTask = nil
            present(cancelled
                    ? "Detenido. Añadí \(filled) portada\(filled == 1 ? "" : "s")."
                    : (filled == 0
                       ? "No encontré portada para los enlaces que faltaban."
                       : "Añadí \(filled) portada\(filled == 1 ? "" : "s")."))
        }
    }

    /// Hace buscables todos los adjuntos antiguos que todavía no tengan `offlineText`.
    /// PDFKit aprovecha la capa de texto, Vision aplica OCR a escaneos y los EPUB se
    /// recorren por capítulos; todo trabaja on-device y el usuario puede detener el lote.
    private func indexLocalDocuments() {
        maintaining = true
        label = "Indexando documentos locales…"
        progress = (0, 0)
        enrichTask = Task { @MainActor in
            let links = ((try? context.fetch(FetchDescriptor<Bookmark>())) ?? []).filter {
                $0.deletedAt == nil && $0.fileKind != nil && $0.offlineText == nil
            }
            guard !links.isEmpty else {
                maintaining = false
                enrichTask = nil
                present("Todos tus PDFs, EPUB e imágenes ya están indexados.")
                return
            }

            var indexed = 0
            var withText = 0
            for (index, link) in links.enumerated() {
                if Task.isCancelled { break }
                progress = (index, links.count)
                do {
                    if let result = try await DocumentTextCoordinator.indexIfNeeded(
                        link, in: context, waitForIdle: false
                    ) {
                        indexed += 1
                        if !result.text.isEmpty { withText += 1 }
                    }
                } catch is CancellationError {
                    break
                } catch {
                    // Un archivo dañado no detiene el resto del lote; queda pendiente para
                    // poder reintentarlo desde su ficha.
                    continue
                }
            }

            let cancelled = Task.isCancelled
            progress = (links.count, links.count)
            maintaining = false
            enrichTask = nil
            present(cancelled
                    ? "Detenido. Indexé \(indexed) documento\(indexed == 1 ? "" : "s")."
                    : "Indexé \(indexed) documento\(indexed == 1 ? "" : "s"); \(withText) ya se pueden encontrar por su contenido.")
        }
    }

    /// Reasigna con IA el icono de cada colección, eligiendo del catálogo curado el SF Symbol que
    /// mejor le va por su nombre (conserva el color). Progreso y cancelable. Punto único
    /// [[CollectionIconSuggester]].
    private func regenerateCollectionIcons() {
        maintaining = true; label = "Eligiendo iconos con IA…"; progress = (0, 0)
        enrichTask = Task {
            let changed = await CollectionIconSuggester.regenerateAll(in: context) { d, t in
                progress = (d, t)
            }
            let cancelled = Task.isCancelled
            if changed > 0 { WidgetReloader.reload() }
            maintaining = false; enrichTask = nil
            present(cancelled
                    ? "Detenido. Cambié \(changed) icono\(changed == 1 ? "" : "s")."
                    : (changed == 0
                       ? "No se cambió ningún icono (¿está la IA disponible?)."
                       : "Actualicé \(changed) icono\(changed == 1 ? "" : "s") de colección con IA."))
        }
    }

    /// Optimiza las etiquetas de un toque: (1) ELIMINA las sin valor (percent-encoding
    /// corrupto «meteorolog%c3a», numéricas «7 días», coletillas) con el mismo saneador
    /// del auto-etiquetado, y (2) FUSIONA las duplicadas por mayúsculas/tildes (p. ej.
    /// «Código» y «codigo»), reasignando sus enlaces a una sola. Raindrop solo borra/
    /// renombra; aquí se limpia y unifica automáticamente.
    private func cleanTags() {
        var tags = ((try? context.fetch(FetchDescriptor<Tag>())) ?? []).filter { $0.deletedAt == nil }
        // 1) Eliminar basura.
        var removed = 0
        for tag in tags where TagSanitizer.clean(tag.name) == nil {
            for link in Array(tag.links) { link.tags.removeAll { $0.id == tag.id } }
            tag.deletedAt = Date()
            removed += 1
        }
        tags.removeAll { $0.deletedAt != nil }
        // 2) Fusionar duplicadas por clave canónica (sin tildes ni mayúsculas).
        var groups: [String: [Tag]] = [:]
        for t in tags { groups[TagSanitizer.key(t.name), default: []].append(t) }
        var mergedCount = 0
        for (_, group) in groups where group.count > 1 {
            let sorted = group.sorted { $0.links.count > $1.links.count }   // conserva la más usada
            let kept = sorted[0]
            for dup in sorted.dropFirst() {
                for link in Array(dup.links) {
                    link.tags.removeAll { $0.id == dup.id }
                    if !link.tags.contains(where: { $0.id == kept.id }) { link.tags.append(kept) }
                }
                dup.deletedAt = Date()
                mergedCount += 1
            }
        }
        if removed > 0 || mergedCount > 0 { context.saveLogging(); WidgetReloader.reload() }
        if removed == 0 && mergedCount == 0 {
            present("Tus etiquetas ya están limpias: nada que optimizar.")
        } else {
            var parts: [String] = []
            if removed > 0 { parts.append("\(removed) sin valor eliminada\(removed == 1 ? "" : "s")") }
            if mergedCount > 0 { parts.append("\(mergedCount) duplicada\(mergedCount == 1 ? "" : "s") fusionada\(mergedCount == 1 ? "" : "s")") }
            present("Etiquetas optimizadas: " + parts.joined(separator: " y ") + ".")
        }
    }

    /// Limpia en lote el ruido del sitio en los títulos (determinista, sin IA): aplica
    /// `TitleCleaner` a cada enlace activo y guarda solo los que cambian. Reutiliza la
    /// misma limpieza que el enriquecido, pero a demanda sobre toda la biblioteca.
    private func cleanTitles() {
        let links = ((try? context.fetch(FetchDescriptor<Bookmark>())) ?? [])
            .filter { $0.deletedAt == nil }
        var changed = 0
        for link in links {
            let cleaned = TitleCleaner.clean(link.title, siteName: link.siteName, host: link.url.urlHost)
            if !cleaned.isEmpty, cleaned != link.title {
                link.title = cleaned
                link.updatedAt = Date()
                SpotlightIndexer.index(link)
                changed += 1
            }
        }
        if changed > 0 { context.saveLogging(); WidgetReloader.reload() }
        present(changed == 0
                ? "Tus títulos ya están limpios: nada que ajustar."
                : "Limpié \(changed) título\(changed == 1 ? "" : "s") (quité el nombre del sitio).")
    }

    /// Elimina etiquetas y colecciones VACÍAS (sin enlaces activos). Para no romper la
    /// jerarquía, solo borra las «hoja» (sin subetiquetas/subcolecciones). Útil para
    /// quitar las etiquetas que la IA generó y luego quedaron sin uso (paridad Raindrop).
    private func removeUnusedTags() {
        var removedTags = 0, removedCols = 0
        let tags = ((try? context.fetch(FetchDescriptor<Tag>())) ?? []).filter { $0.deletedAt == nil }
        for t in tags where t.activeLinkCount == 0 && t.children.isEmpty {
            t.deletedAt = Date(); removedTags += 1
        }
        let cols = ((try? context.fetch(FetchDescriptor<BookmarkCategory>())) ?? []).filter { $0.deletedAt == nil }
        for c in cols where c.activeLinkCount == 0 && c.children.isEmpty {
            c.deletedAt = Date(); removedCols += 1
        }
        if removedTags > 0 || removedCols > 0 { context.saveLogging(); WidgetReloader.reload() }
        guard removedTags > 0 || removedCols > 0 else {
            present("No hay etiquetas ni colecciones vacías que eliminar.")
            return
        }
        var parts: [String] = []
        if removedTags > 0 { parts.append("\(removedTags) etiqueta\(removedTags == 1 ? "" : "s")") }
        if removedCols > 0 { parts.append("\(removedCols) colección\(removedCols == 1 ? "" : "es")") }
        present("Eliminé " + parts.joined(separator: " y ") + " sin usar.")
    }

    private func mergeCollections() {
        let cols = CollectionMerger.mergeDuplicates(in: context)
        let tags = EntityResolver.mergeDuplicateTags(in: context)
        if cols > 0 || tags > 0 { WidgetReloader.reload() }
        let parts = [
            cols > 0 ? "\(cols) colección\(cols == 1 ? "" : "es")" : nil,
            tags > 0 ? "\(tags) etiqueta\(tags == 1 ? "" : "s")" : nil,
        ].compactMap { $0 }
        present(parts.isEmpty
                ? "No hay colecciones ni etiquetas duplicadas que fusionar."
                : "Fusioné \(parts.joined(separator: " y ")) en su equivalente.")
    }

    private func emptyTrash() {
        let descriptor = FetchDescriptor<Bookmark>(predicate: #Predicate { $0.deletedAt != nil })
        let trashed = (try? context.fetch(descriptor)) ?? []
        let count = trashed.count
        BookmarkActions.deleteForever(trashed, in: context)
        present("Papelera vaciada: \(count) enlace\(count == 1 ? "" : "s") eliminado\(count == 1 ? "" : "s") permanentemente.")
    }

    private func present(_ message: String) {
        statusMessage = message; showStatus = true
    }
}

/// Textos de un enlace a traducir / traducidos (Sendable): es lo ÚNICO que cruza entre el
/// MainActor y el closure no aislado de la `TranslationSession` (ids y Strings, no `@Model`).
private struct LinkTexts: Sendable {
    let id: PersistentIdentifier
    let title: String?
    let details: String?
    let summary: String?
}
