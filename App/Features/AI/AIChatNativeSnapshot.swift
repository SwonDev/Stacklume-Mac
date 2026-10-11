import AppKit
import Foundation

@MainActor
struct AIChatNativeSnapshot {
    let sessionID: UUID
    let rows: [AIChatNativeRow]
    let metrics: [AIChatNativeMetric]
    let width: CGFloat
    let style: AIChatNativeStyle
    let addedURLs: Set<String>
    let generation: UInt64
    var height: CGFloat { metrics.reduce(0) { $0 + $1.height } }
    func index(of id: AIChatNativeRowID) -> Int? { rows.firstIndex { $0.id == id } }
    func origin(of index: Int) -> CGFloat { metrics.prefix(index).reduce(0) { $0 + $1.height } }
    func index(at y: CGFloat) -> Int {
        var end: CGFloat = 0
        for i in metrics.indices { end += metrics[i].height; if y < end { return i } }
        return max(0, metrics.count - 1)
    }
}

/// Medición cooperativa MainActor: AppKit queda local y cada publicación comprueba generación y sesión.
@MainActor
final class AIChatSnapshotEngine {
    struct Entry {
        let row: AIChatNativeRow
        let metric: AIChatNativeMetric
    }
    private var cache: [AIChatNativeRowID: Entry] = [:]
    private var task: Task<Void, Never>?
    private var session: UUID?
    private var width: CGFloat = 0
    private var style: AIChatNativeStyle?
    private var addedURLs = Set<String>()
    private let measurer = AIChatTextKitMeasurer()
    private(set) var generation: UInt64 = 0
    private(set) var published: AIChatNativeSnapshot?
    private(set) var cancelledGenerations = 0
    private(set) var cacheHits = 0
    var measurements: Int { measurer.measurements }
    var cacheEntries: Int { cache.count }
    var retainedMeasurementUTF16: Int { measurer.retainedUTF16 }
    var maximumMeasurementUTF16: Int { measurer.maximumUTF16 }
    deinit { task?.cancel() }

    @discardableResult
    func request(sessionID: UUID, rows: [AIChatNativeRow], width: CGFloat, style: AIChatNativeStyle,
                 addedURLs: Set<String>, publish: @escaping @MainActor (AIChatNativeSnapshot) -> Void) -> UInt64 {
        generation &+= 1
        let expected = generation
        if task != nil { task?.cancel(); cancelledGenerations += 1 }
        let sameGeometry = session == sessionID && self.width == width && self.style?.equivalent(to: style) == true
        if !sameGeometry { cache.removeAll(keepingCapacity: true) }
        let ids = Set(rows.map(\.id))
        cache = cache.filter { ids.contains($0.key) }
        // El lote de agregar puede alterar una cabecera, aunque las referencias permanezcan iguales.
        if self.addedURLs != addedURLs {
            for row in rows { if case .header = row { cache.removeValue(forKey: row.id) } }
        }
        session = sessionID; self.width = width; self.style = style; self.addedURLs = addedURLs
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var metrics: [AIChatNativeMetric] = []
            metrics.reserveCapacity(rows.count)
            let layout = AIChatNativeRowLayout(style: style, width: width, measurer: self.measurer, addedURLs: addedURLs)
            for row in rows {
                guard !Task.isCancelled, self.generation == expected, self.session == sessionID else { return }
                let metric: AIChatNativeMetric
                if let existing = self.cache[row.id], row.equivalent(to: existing.row) {
                    self.cacheHits += 1; metric = existing.metric
                } else {
                    metric = autoreleasepool { layout.content(for: row).metric }
                    guard !Task.isCancelled, self.generation == expected else { return }
                    self.cache[row.id] = .init(row: row, metric: metric)
                }
                metrics.append(metric)
                // También cede en hits: un historial completo nunca ocupa un bucle sin cancelación.
                await Task.yield()
            }
            guard !Task.isCancelled, self.generation == expected, self.session == sessionID else { return }
            let snapshot = AIChatNativeSnapshot(sessionID: sessionID, rows: rows, metrics: metrics,
                width: width, style: style, addedURLs: addedURLs, generation: expected)
            self.published = snapshot
            self.task = nil
            publish(snapshot)
        }
        return expected
    }
    func invalidate() {
        generation &+= 1; task?.cancel(); task = nil; cache.removeAll(); published = nil
        session = nil; style = nil; width = 0; addedURLs.removeAll()
    }
}

/// El punto de lectura se identifica por fila y carácter UTF16, nunca por porcentaje del documento.
struct AIChatReadingAnchor {
    let rowID: AIChatNativeRowID
    let character: Int?
    let lineOffset: CGFloat
    let rowOffset: CGFloat
}

/// Contadores de representación; OFF evita construir payloads o registrar contenido privado.
@MainActor
struct AIChatNativeMemoryCounters: Codable {
    var generation: UInt64
    var logicalRows: Int
    var metricEntries: Int
    var liveCells: Int
    var liveTextSystems: Int
    var measurementCount: Int
    var cacheHits: Int
    var cancelledGenerations: Int
    var retainedMeasurementUTF16: Int
    var maximumMeasurementUTF16: Int
    var presentedUTF16: Int
}
