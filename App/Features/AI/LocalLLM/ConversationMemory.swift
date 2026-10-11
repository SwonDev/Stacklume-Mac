import Foundation
import NaturalLanguage

/// Memoria SEMÁNTICA persistente de la conversación del asistente (estilo MemPalace, pero
/// NATIVA y 100% on-device). Guarda cada intercambio (pregunta + respuesta) como un
/// «recuerdo» con su embedding de oraciones de Apple (`NLEmbedding` — el MISMO motor que la
/// búsqueda semántica de la biblioteca: gratis, privado, sin red ni Python). En cada turno
/// recupera los recuerdos MÁS RELEVANTES a la pregunta actual para inyectarlos en el prompt.
///
/// Resultado: el asistente entiende el contexto aunque sea de hace MUCHOS turnos, y la ventana
/// del modelo NUNCA se satura — el historial reciente va acotado por tokens (autocompact) y lo
/// antiguo se RECUPERA por significado solo cuando es relevante.
@MainActor
final class ConversationMemory {
    struct Memory: Codable, Sendable {
        let id: UUID
        let text: String
        let vector: [Float]
        let createdAt: Date
        /// nil/"exchange" = un intercambio P/R; "summary" = resumen de un bloque (consolidación);
        /// "fact" = hecho/preferencia DURADERA del usuario (memoria de perfil, grafo de entidades).
        var kind: String? = nil
    }

    static let shared = ConversationMemory()
    private init() {}

    /// Recuerdos por sesión de chat (clave = uuidString de la sesión, para JSON).
    private var bySession: [String: [Memory]] = [:]
    /// Nº de intercambios ya CONSOLIDADOS (resumidos + hechos extraídos) por sesión. En
    /// UserDefaults (no rompe el formato del fichero de recuerdos).
    private var lastConsolidated: [String: Int] = [:]
    private var loaded = false
    private var saveScheduled = false
    private var saveGeneration: UInt = 0
    private var saveTask: Task<Void, Never>?
    /// Una sola consolidación por chat, identificada para que una tarea cancelada no pueda
    /// limpiar o sobrescribir el estado de otra posterior de la misma sesión.
    private var consolidationTasks: [String: Task<Void, Never>] = [:]
    private var consolidationTaskIDs: [String: UUID] = [:]

    private static let maxPerSession = 400
    private static let consolidateEvery = 8
    private static let consolidatedKey = "stacklume.convMemory.consolidated"
    nonisolated private static let ioQueue = DispatchQueue(
        label: "com.swondev.stacklume.conversation-memory", qos: .utility)

    // MARK: - API

    /// Guarda un intercambio (pregunta del usuario + respuesta del asistente) como recuerdo.
    func remember(session: UUID, user: String, assistant: String, language: String) {
        ensureLoaded()
        let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = assistant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty, !a.isEmpty else { return }
        let text = "P: \(String(u.prefix(2_000)))\nR: \(String(a.prefix(1_400)))"
        guard let v = Self.embed(text, language: language) else { return }
        var list = bySession[session.uuidString] ?? []
        list.append(Memory(id: UUID(), text: text, vector: v, createdAt: Date()))
        if list.count > Self.maxPerSession { list = Array(list.suffix(Self.maxPerSession)) }
        bySession[session.uuidString] = list
        scheduleSave()
    }

    /// Recupera los recuerdos más relevantes a `query` con un ranking HÍBRIDO (inspirado en el
    /// «Hybrid v4» de MemPalace): coseno semántico + solapamiento de PALABRAS CLAVE + proximidad
    /// TEMPORAL (lo reciente pesa algo más). Mucho mejor recall que el vector puro. Excluye los
    /// recuerdos que ya están en el historial RECIENTE (no duplicar lo que el modelo ya ve).
    func recall(session: UUID, query: String, language: String,
                excludingRecent recent: Set<String> = [], limit: Int = 4, threshold: Double = 0.18) -> [String] {
        ensureLoaded()
        guard let list = bySession[session.uuidString], !list.isEmpty,
              let qv = Self.embed(query, language: language) else { return [] }
        let qd = qv.map(Double.init)
        let qWords = Self.keywords(query)
        let oldest = list.map(\.createdAt).min() ?? Date()
        let newest = list.map(\.createdAt).max() ?? Date()
        let span = max(newest.timeIntervalSince(oldest), 1)
        var scored: [(text: String, score: Double)] = []
        for m in list where (m.kind ?? "exchange") != "fact" {   // los hechos van aparte (perfil)
            if recent.contains(where: { m.text.contains($0) }) { continue }
            let sem = Self.cosine(qd, m.vector.map(Double.init))
            let kw = qWords.isEmpty ? 0 : Double(qWords.intersection(Self.keywords(m.text)).count) / Double(qWords.count)
            let recency = m.createdAt.timeIntervalSince(oldest) / span   // 0 (viejo) … 1 (reciente)
            let score = sem * 0.72 + kw * 0.20 + recency * 0.08
            // Entra si hay relevancia SEMÁNTICA o un solapamiento LÉXICO fuerte (keyword boost).
            if sem >= threshold || kw >= 0.5 { scored.append((m.text, score)) }
        }
        return scored.sorted { $0.score > $1.score }.prefix(limit).map(\.text)
    }

    /// Palabras clave de un texto (minúsculas, sin tildes, >3 letras) para el boost léxico.
    nonisolated private static func keywords(_ s: String) -> Set<String> {
        let folded = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        return Set(folded.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 3 })
    }

    /// Hechos/preferencias DURADERAS aprendidas del usuario (memoria de perfil — el «grafo de
    /// entidades» en su forma útil para un gestor de marcadores). Se inyectan como contexto.
    func userFacts(session: UUID, limit: Int = 6) -> [String] {
        ensureLoaded()
        return (bySession[session.uuidString] ?? []).filter { ($0.kind ?? "") == "fact" }.suffix(limit).map(\.text)
    }

    /// Olvida la memoria de una sesión (al borrar ese chat).
    func forget(session: UUID) {
        ensureLoaded()
        let key = session.uuidString
        consolidationTasks[key]?.cancel()
        consolidationTasks[key] = nil
        consolidationTaskIDs[key] = nil
        bySession[key] = nil
        lastConsolidated[key] = nil
        saveConsolidated()
        scheduleSave()
    }

    /// Borra toda la memoria semántica y su contador de consolidación de forma inmediata.
    func removeAll() {
        ensureLoaded()
        saveTask?.cancel()
        saveTask = nil
        saveScheduled = false
        saveGeneration &+= 1
        for task in consolidationTasks.values { task.cancel() }
        consolidationTasks = [:]
        consolidationTaskIDs = [:]
        bySession = [:]
        lastConsolidated = [:]
        UserDefaults.standard.removeObject(forKey: Self.consolidatedKey)
        Self.ioQueue.sync {
            if let url = Self.fileURL() { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: - Consolidación (autocompact INTELIGENTE: resumen de bloque + hechos del usuario)

    /// Si se han acumulado bastantes intercambios nuevos, consolida EN SEGUNDO PLANO: resume el
    /// bloque con el modelo local y extrae hechos/preferencias duraderas del usuario. Así la
    /// memoria comprime (no solo recorta) y aprende un PERFIL del usuario entre conversaciones.
    func consolidateIfNeeded(session: UUID, language: String) {
        ensureLoaded()
        let key = session.uuidString
        let total = (bySession[key] ?? []).filter { ($0.kind ?? "exchange") == "exchange" }.count
        guard total - (lastConsolidated[key] ?? 0) >= Self.consolidateEvery,
              consolidationTasks[key] == nil else { return }
        let taskID = UUID()
        consolidationTaskIDs[key] = taskID
        consolidationTasks[key] = Task { @MainActor [weak self] in
            guard let self else { return }
            let completed = await self.consolidate(session: session, language: language)
            guard self.consolidationTaskIDs[key] == taskID else { return }
            if completed {
                self.lastConsolidated[key] = total
                self.saveConsolidated()
            }
            self.consolidationTasks[key] = nil
            self.consolidationTaskIDs[key] = nil
        }
    }

    @discardableResult
    private func consolidate(session: UUID, language: String) async -> Bool {
        let key = session.uuidString
        let exchanges = (bySession[key] ?? []).filter { ($0.kind ?? "exchange") == "exchange" }
        guard exchanges.count >= Self.consolidateEvery else { return false }
        // Cede mientras el usuario interactúa: la consolidación usa el modelo MLX (compite con el
        // chat y la UI por la GPU). Espera a que esté inactivo, igual que el barrido de enriquecido.
        await UserActivityMonitor.shared.waitUntilIdle()
        guard !Task.isCancelled, bySession[key] != nil else { return false }
        let block = exchanges.suffix(Self.consolidateEvery * 2).map(\.text).joined(separator: "\n")
        // 1) RESUMEN del bloque (comprime el contexto, no solo recorta).
        var producedUsefulMemory = false
        if let summary = await Self.summarize(block, language: language),
           !Task.isCancelled,
           bySession[key] != nil,
           let v = Self.embed("RESUMEN: " + summary, language: language) {
            bySession[key, default: []].append(Memory(id: UUID(), text: "RESUMEN: " + summary,
                                                       vector: v, createdAt: Date(), kind: "summary"))
            producedUsefulMemory = true
        }
        // 2) GRAFO DE ENTIDADES del usuario (perfil duradero con validez temporal): extrae
        // tripletas (sujeto, relación, objeto) y las añade al EntityGraph, que invalida las que
        // cambian de estado y conserva la línea de tiempo.
        if let triples = await Self.extractTriples(block, language: language) {
            guard !Task.isCancelled, bySession[key] != nil else { return false }
            for (s, r, o) in triples { EntityGraph.shared.add(subject: s, relation: r, object: o) }
            producedUsefulMemory = true
        }
        if producedUsefulMemory { scheduleSave() }
        return producedUsefulMemory
    }

    /// Resume un bloque de conversación con el modelo local (2-3 frases, sin preámbulos).
    nonisolated private static func summarize(_ text: String, language: String) async -> String? {
        await UnifiedAIService.ensureLiquidLoaded()
        guard await LocalAIRunner.shared.modelContainer != nil else { return nil }
        let target = language == "en" ? "English" : "español"
        let system = "Resume en \(target), en 2-3 frases, lo ESENCIAL de esta parte de la conversación entre un usuario y su asistente de marcadores (qué pidió, qué se hizo, qué quedó pendiente). Responde SOLO con el resumen, sin preámbulos ni viñetas."
        guard let raw = await LocalAIRunner.shared.complete(system: system, prompt: String(text.prefix(4000)),
                                                            maxTokens: 512, enableThinking: false) else { return nil }
        // Si el modelo no cerró su bloque de razonamiento (`</think>` ausente), `afterThinking`
        // devuelve el RAZONAMIENTO crudo: NO lo guardes como resumen (sería ruido en la memoria).
        guard raw.contains("</think>") || !raw.contains("<think>") else { return nil }
        let s = LiquidAIService.afterThinking(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count >= 12 ? String(s.prefix(600)) : nil
    }

    /// Extrae HECHOS DURADEROS del usuario como TRIPLETAS (sujeto, relación, objeto) para el
    /// grafo de entidades. Devuelve [] si no hay nada duradero.
    nonisolated private static func extractTriples(_ text: String, language: String) async -> [(String, String, String)]? {
        await UnifiedAIService.ensureLiquidLoaded()
        guard await LocalAIRunner.shared.modelContainer != nil else { return nil }
        let lang = language == "en" ? "English" : "español"
        let system = """
        De esta conversación entre un usuario y su asistente de marcadores, extrae los HECHOS \
        DURADEROS del usuario como TRIPLETAS (sujeto, relación, objeto). El sujeto suele ser «el \
        usuario» o un proyecto/tema suyo. Relaciones útiles: «trabaja en», «se dedica a», «usa», \
        «prefiere», «le interesa», «guarda enlaces de», «es». Escribe valores en \(lang), tomados \
        SOLO de lo que el usuario dijo de verdad (NO inventes ni copies ejemplos). Devuelve \
        EXCLUSIVAMENTE un array JSON, máximo 6, con esta FORMA (rellena con datos reales): \
        [{"s":"el usuario","r":"<relación>","o":"<proyecto, herramienta o tema real>"}]. Solo hechos \
        DURADEROS (no acciones puntuales de este turno). Si no hay nada, responde [].
        """
        guard let raw = await LocalAIRunner.shared.complete(system: system, prompt: String(text.prefix(4000)),
                                                            maxTokens: 512, enableThinking: false) else { return nil }
        return parseTriples(LiquidAIService.afterThinking(raw))
    }

    /// Parsea el array JSON `[{"s":…,"r":…,"o":…}]` de la respuesta del modelo.
    nonisolated private static func parseTriples(_ s: String) -> [(String, String, String)]? {
        guard let start = s.firstIndex(of: "["), let end = s.lastIndex(of: "]"), start < end else { return nil }
        let json = String(s[start...end])
        struct T: Decodable { let s: String?; let r: String?; let o: String? }
        guard let data = json.data(using: .utf8), let arr = try? JSONDecoder().decode([T].self, from: data) else { return nil }
        var out: [(String, String, String)] = []
        for t in arr {
            guard let sub = t.s, let rel = t.r, let obj = t.o,
                  !sub.isEmpty, !rel.isEmpty, !obj.isEmpty else { continue }
            // Descarta los PLACEHOLDERS del prompt sin rellenar (p. ej. «<relación>», «<proyecto…»):
            // que el modelo los copie no debe ensuciar el perfil del usuario.
            if [sub, rel, obj].contains(where: { $0.contains("<") || $0.contains(">") }) { continue }
            out.append((sub, rel, obj))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Embeddings on-device (NLEmbedding)

    nonisolated static func embed(_ text: String, language: String) -> [Float]? {
        let primary: NLLanguage = (language == "en") ? .english : .spanish
        guard let emb = NLEmbedding.sentenceEmbedding(for: primary) ?? NLEmbedding.sentenceEmbedding(for: .english),
              let v = emb.vector(for: text.lowercased()) else { return nil }
        return v.map(Float.init)
    }

    nonisolated private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let d = na.squareRoot() * nb.squareRoot()
        return d == 0 ? 0 : dot / d
    }

    // MARK: - Persistencia (archivo JSON en Application Support, como la caché semántica)

    nonisolated private static func fileURL() -> URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("Stacklume", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir.appendingPathComponent("conversation-memory.json")
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        if let d = UserDefaults.standard.data(forKey: Self.consolidatedKey),
           let dec = try? JSONDecoder().decode([String: Int].self, from: d) { lastConsolidated = dec }
        guard let url = Self.fileURL(),
              let data = try? BoundedFileReader.read(url, maximumBytes: 64 * 1_024 * 1_024),
              let decoded = try? JSONDecoder().decode([String: [Memory]].self, from: data) else { return }
        bySession = decoded.mapValues { Array($0.suffix(Self.maxPerSession)) }
    }

    private func saveConsolidated() {
        if let d = try? JSONEncoder().encode(lastConsolidated) {
            UserDefaults.standard.set(d, forKey: Self.consolidatedKey)
        }
    }

    /// Vuelca a disco con debounce de cola: espera dos segundos desde la ÚLTIMA mutación y captura
    /// entonces el estado más reciente. Así ninguna mutación queda fuera por llegar mientras ya
    /// había una escritura programada.
    private func scheduleSave() {
        saveGeneration &+= 1
        guard !saveScheduled else { return }
        saveScheduled = true
        saveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let generation = self.saveGeneration
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                guard generation == self.saveGeneration else { continue }
                let snapshot = self.bySession
                await withCheckedContinuation { continuation in
                    Self.ioQueue.async {
                        Self.write(snapshot)
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { return }
                if generation == self.saveGeneration {
                    self.saveScheduled = false
                    self.saveTask = nil
                    return
                }
            }
        }
    }

    /// Escritura síncrona para el cierre del proceso. Es imprescindible porque el workaround de
    /// MLX termina con `_exit(0)` y no deja que sobrevivan tareas diferidas.
    func flushNow() {
        ensureLoaded()
        for task in consolidationTasks.values { task.cancel() }
        consolidationTasks = [:]
        consolidationTaskIDs = [:]
        saveTask?.cancel()
        saveTask = nil
        saveScheduled = false
        saveGeneration &+= 1
        saveConsolidated()
        let snapshot = bySession
        Self.ioQueue.sync { Self.write(snapshot) }
    }

    nonisolated private static func write(_ snapshot: [String: [Memory]]) {
        guard let url = fileURL(), let data = try? JSONEncoder().encode(snapshot) else { return }
        try? PrivateFileIO.write(data, to: url)
    }
}
