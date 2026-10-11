import Foundation

/// Libro mayor PERSISTENTE de «ya intentado», para que los barridos automáticos de fondo
/// (enriquecido con IA y adquisición de portadas) NO reprocesen en CADA arranque los enlaces
/// que ya pasaron por ellos una vez. Sin esto, un enlace que la IA no logró completar (no se
/// le pudo deducir categoría/etiquetas/descripción, o una importación masiva sin metadatos)
/// volvía a entrar en el barrido en cada lanzamiento: re-descarga de red + extracción de
/// contenido + inferencia MLX (que satura la GPU → entrecortado) + `CoverEnsurer`. Es decir,
/// «trabajo ya hecho» repetido indefinidamente.
///
/// Se implementa como side-store (UserDefaults indexado por UUID) porque el `@Model`
/// `Bookmark` vive en el paquete compartido read-only `StacklumeCore` y no podemos añadirle
/// un campo `enrichedAt`/`aiTriedAt`. Es el patrón ya usado en el proyecto para «campos»
/// laterales sin tocar el modelo (ver memoria «almacenamiento-lateral-modelo-readonly» y
/// p. ej. `HighlightNoteStore`, `ReadingProgressStore`).
///
/// CONTRATO (lo pidió el usuario, 2026-06-23): una vez cargado/enriquecido un enlace, no se
/// vuelve a tocar SOLO; si de casualidad uno se rompe o está mal enlazado, el usuario usa
/// «Mejorar con IA» / «Obtener imagen» (rutas `force`), que NO consultan este libro mayor.
@MainActor
enum EnrichmentLedger {
    private static let aiKey = "stacklume.ledger.aiAttempted"
    private static let coverKey = "stacklume.ledger.coverAttempted"
    private static let netKey = "stacklume.ledger.netAttempted"
    private static let completerKey = "stacklume.ledger.completerAttempted"

    /// Cachés en memoria para no leer UserDefaults en cada comprobación del lote.
    private static var aiSet: Set<String> = load(aiKey)
    private static var coverSet: Set<String> = load(coverKey)
    private static var netSet: Set<String> = load(netKey)
    private static var completerSet: Set<String> = load(completerKey)

    private static func load(_ key: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }
    private static func persist(_ set: Set<String>, _ key: String) {
        UserDefaults.standard.set(Array(set), forKey: key)
    }

    // MARK: - IA

    /// ¿Ya se intentó enriquecer este enlace con IA en alguna sesión?
    static func hasAIAttempt(_ id: UUID) -> Bool { aiSet.contains(id.uuidString) }

    /// Marca el enlace como ya intentado por la IA (haya quedado completo o no), para que el
    /// barrido automático no lo reprocese en futuros arranques.
    static func markAIAttempt(_ id: UUID) {
        if aiSet.insert(id.uuidString).inserted { persist(aiSet, aiKey) }
    }

    /// Quita la marca de «ya intentado por IA» para que el barrido automático vuelva a procesar
    /// este enlace UNA vez. Lo usa la migración que re-traduce las descripciones que se quedaron
    /// en otro idioma por el bug del gate (la IA nunca las miraba). Dirigida y puntual: NO es un
    /// reproceso continuo (tras el reintento se vuelve a marcar en `enrich`).
    static func clearAIAttempt(_ id: UUID) {
        if aiSet.remove(id.uuidString) != nil { persist(aiSet, aiKey) }
    }

    // MARK: - Portadas

    /// ¿Ya se intentó adquirir portada automáticamente para este enlace?
    static func hasCoverAttempt(_ id: UUID) -> Bool { coverSet.contains(id.uuidString) }

    /// Marca que ya se intentó la portada automática (la encontrara o no): así un enlace sin
    /// portada obtenible no se reintenta cada sesión.
    static func markCoverAttempt(_ id: UUID) {
        if coverSet.insert(id.uuidString).inserted { persist(coverSet, coverKey) }
    }

    // MARK: - Metadatos de red

    /// ¿Ya se intentó el enriquecido de RED (metadatos/og:image/auto-organización) de este enlace?
    /// Evita que el barrido automático cada 120 s reprocese los mismos enlaces incompletos
    /// (re-`autoOrganize` + escritura → invalida el @Query → hitch al interactuar).
    static func hasNetworkAttempt(_ id: UUID) -> Bool { netSet.contains(id.uuidString) }

    /// Marca el enlace como ya intentado por el enriquecido de red. El redo es manual
    /// (Ajustes › Mantenimiento, que pasa `force`).
    static func markNetworkAttempt(_ id: UUID) {
        if netSet.insert(id.uuidString).inserted { persist(netSet, netKey) }
    }

    // MARK: - Completer (capa garantizada sin IA)

    /// ¿Ya pasó este enlace por el [[LibraryCompleter]] (metadatos + favicon válido)? Evita que
    /// el autocurativo de 2.º plano reprocese el mismo backlog en cada arranque. El botón de
    /// Mantenimiento (pasada exhaustiva) IGNORA este libro: rehace todos.
    static func hasCompleterAttempt(_ id: UUID) -> Bool { completerSet.contains(id.uuidString) }

    /// Marca el enlace como ya completado por la capa garantizada (lo lograra del todo o no).
    static func markCompleterAttempt(_ id: UUID) {
        if completerSet.insert(id.uuidString).inserted { persist(completerSet, completerKey) }
    }

    // MARK: - Higiene

    /// Total de entradas registradas (todos los libros). Para decidir si compensa purgar.
    static var count: Int { aiSet.count + coverSet.count + netSet.count + completerSet.count }

    /// ¿Conviene purgar huérfanos? Solo si el libro ha derivado claramente respecto a los
    /// enlaces vivos (p. ej. tras borrar muchos), para no pagar un fetch completo en cada
    /// arranque. Los UUID huérfanos son inocuos (nunca casan con un enlace vivo) y minúsculos,
    /// así que la purga es mera higiene diferida.
    static func shouldPrune(liveCount: Int) -> Bool {
        count > max(500, liveCount * 2)
    }

    /// Elimina del libro los ids de enlaces que ya no existen. `keeping` = ids vivos.
    static func prune(keeping live: Set<UUID>) {
        let alive = Set(live.map(\.uuidString))
        let ai = aiSet.intersection(alive)
        if ai.count != aiSet.count { aiSet = ai; persist(aiSet, aiKey) }
        let cover = coverSet.intersection(alive)
        if cover.count != coverSet.count { coverSet = cover; persist(coverSet, coverKey) }
        let net = netSet.intersection(alive)
        if net.count != netSet.count { netSet = net; persist(netSet, netKey) }
        let completer = completerSet.intersection(alive)
        if completer.count != completerSet.count { completerSet = completer; persist(completerSet, completerKey) }
    }

    /// Elimina todas las marcas asociadas a enlaces borrados definitivamente.
    static func remove(_ ids: [UUID]) {
        let removed = Set(ids.map(\.uuidString))
        guard !removed.isEmpty else { return }
        let ai = aiSet.subtracting(removed)
        if ai.count != aiSet.count { aiSet = ai; persist(aiSet, aiKey) }
        let cover = coverSet.subtracting(removed)
        if cover.count != coverSet.count { coverSet = cover; persist(coverSet, coverKey) }
        let net = netSet.subtracting(removed)
        if net.count != netSet.count { netSet = net; persist(netSet, netKey) }
        let completer = completerSet.subtracting(removed)
        if completer.count != completerSet.count { completerSet = completer; persist(completerSet, completerKey) }
    }

    /// Restablecimiento total, incluida la caché estática en memoria.
    static func removeAll() {
        aiSet = []; coverSet = []; netSet = []; completerSet = []
        for key in [aiKey, coverKey, netKey, completerKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
