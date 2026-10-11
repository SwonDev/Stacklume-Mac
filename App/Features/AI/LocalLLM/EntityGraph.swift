import Foundation

/// GRAFO de conocimiento del usuario con VALIDEZ TEMPORAL (estilo MemPalace: add / query /
/// invalidate / timeline). Almacena HECHOS como tripletas `(sujeto, relación, objeto)` con
/// marca de tiempo; cuando un hecho de ESTADO cambia, el anterior se INVALIDA (no se borra:
/// se conserva la historia para la línea de tiempo). Nativo, on-device, persistido en JSON.
///
/// Es el «grafo de entidades» que pidió el usuario, en su forma útil para un gestor de
/// marcadores: el PERFIL duradero del usuario (proyectos, intereses, preferencias, a qué se
/// dedica), consultable y con memoria de cómo ha ido cambiando.
@MainActor
final class EntityGraph {
    static let shared = EntityGraph()
    private init() {}

    struct Edge: Codable, Sendable {
        let id: UUID
        let subject: String
        let relation: String
        let object: String
        let createdAt: Date
        var invalidatedAt: Date?   // nil = VIGENTE
    }

    private var edges: [Edge] = []
    private var loaded = false
    private var saveScheduled = false
    private var saveGeneration: UInt = 0
    private var saveTask: Task<Void, Never>?
    private static let maxEdges = 400
    nonisolated private static let ioQueue = DispatchQueue(
        label: "com.swondev.stacklume.entity-graph", qos: .utility)

    /// Relaciones de ESTADO (valor único): al añadir una nueva con el mismo sujeto+relación y
    /// objeto distinto, la anterior se INVALIDA (cambio de estado, validez temporal). Las que no
    /// están aquí son ADITIVAS (multi-valor: «usa», «guarda enlaces de»…) y conviven.
    private static let singleValued: Set<String> = [
        "es", "prefiere", "trabaja en", "se dedica a", "esta en", "está en", "quiere",
        "necesita", "prioriza", "usa principalmente", "su proyecto es"
    ]

    // MARK: - API

    /// Añade una tripleta. Dedup de vigentes iguales; invalidación temporal de las de estado.
    func add(subject: String, relation: String, object: String) {
        ensureLoaded()
        let s = AssistantActionPolicy.sanitizedUserInput(subject)
        let r = AssistantActionPolicy.sanitizedUserInput(relation).lowercased()
        let o = AssistantActionPolicy.sanitizedUserInput(object)
        guard s.count > 1, r.count > 1, o.count > 1, s.count < 80, o.count < 120 else { return }
        // Ya existe vigente idéntica → nada.
        if edges.contains(where: { $0.invalidatedAt == nil && norm($0.subject) == norm(s) && norm($0.relation) == norm(r) && norm($0.object) == norm(o) }) { return }
        // Invalidación temporal: relación de estado con objeto distinto → caduca la anterior.
        if Self.singleValued.contains(norm(r)) {
            let now = Date()
            for i in edges.indices where edges[i].invalidatedAt == nil
                && norm(edges[i].subject) == norm(s) && norm(edges[i].relation) == norm(r) {
                edges[i].invalidatedAt = now
            }
        }
        edges.append(Edge(id: UUID(), subject: s, relation: r, object: o, createdAt: Date(), invalidatedAt: nil))
        if edges.count > Self.maxEdges { edges = Array(edges.suffix(Self.maxEdges)) }
        scheduleSave()
    }

    /// Aristas VIGENTES formateadas como frases para el perfil del usuario.
    func profileLines(limit: Int = 10) -> [String] {
        ensureLoaded()
        return edges.filter { $0.invalidatedAt == nil }.suffix(limit).map { "\($0.subject) \($0.relation) \($0.object)" }
    }

    /// Aristas vigentes RELEVANTES a una consulta (solapamiento de palabras). Si la consulta no
    /// aporta palabras útiles, cae al perfil reciente.
    func relevant(to query: String, limit: Int = 8) -> [String] {
        ensureLoaded()
        let qWords = Set(norm(query).split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 3 })
        guard !qWords.isEmpty else { return profileLines(limit: limit) }
        let hits = edges.filter { e in
            guard e.invalidatedAt == nil else { return false }
            let text = norm("\(e.subject) \(e.relation) \(e.object)")
            return qWords.contains { text.contains($0) }
        }
        return hits.suffix(limit).map { "\($0.subject) \($0.relation) \($0.object)" }
    }

    /// LÍNEA DE TIEMPO de una entidad: todos sus hechos (vigentes e invalidados), por fecha.
    func timeline(of entity: String) -> [String] {
        ensureLoaded()
        let e = norm(entity)
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; f.locale = Locale(identifier: "es_ES")
        return edges
            .filter { norm($0.subject).contains(e) || norm($0.object).contains(e) || e.contains(norm($0.subject)) }
            .sorted { $0.createdAt < $1.createdAt }
            .map { ed in
                let tag = ed.invalidatedAt == nil ? "" : " (ya no)"
                return "\(f.string(from: ed.createdAt)) — \(ed.subject) \(ed.relation) \(ed.object)\(tag)"
            }
    }

    /// Borra TODO el grafo (olvidar el perfil del usuario).
    func clear() { ensureLoaded(); edges = []; scheduleSave() }

    /// Borra el grafo y su archivo inmediatamente (restablecimiento total de biblioteca).
    func removeAll() {
        ensureLoaded()
        saveTask?.cancel()
        saveTask = nil
        saveScheduled = false
        saveGeneration &+= 1
        edges = []
        Self.ioQueue.sync {
            if let url = Self.fileURL() { try? FileManager.default.removeItem(at: url) }
        }
    }

    var isEmpty: Bool { ensureLoaded(); return edges.allSatisfy { $0.invalidatedAt != nil } }

    private func norm(_ s: String) -> String {
        s.lowercased().folding(options: .diacriticInsensitive, locale: nil).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Persistencia (JSON en Application Support)

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
        return dir.appendingPathComponent("entity-graph.json")
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let url = Self.fileURL(),
              let data = try? BoundedFileReader.read(url, maximumBytes: 8 * 1_024 * 1_024),
              let decoded = try? JSONDecoder().decode([Edge].self, from: data) else { return }
        edges = Array(decoded.suffix(Self.maxEdges))
    }

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
                let snapshot = self.edges
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

    /// Escritura síncrona antes del `_exit(0)` requerido por MLX/Metal.
    func flushNow() {
        ensureLoaded()
        saveTask?.cancel()
        saveTask = nil
        saveScheduled = false
        saveGeneration &+= 1
        let snapshot = edges
        Self.ioQueue.sync { Self.write(snapshot) }
    }

    nonisolated private static func write(_ snapshot: [Edge]) {
        guard let url = fileURL(), let data = try? JSONEncoder().encode(snapshot) else { return }
        try? PrivateFileIO.write(data, to: url)
    }
}
