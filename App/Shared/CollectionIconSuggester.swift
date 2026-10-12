import Foundation
import SwiftData
import AppKit
import StacklumeCore

/// Asigna con IA el ICONO más representativo a cada colección, eligiendo el SF Symbol del
/// catálogo curado ([[IconCatalog]]) que mejor le va por su nombre. Restringir la elección al
/// catálogo garantiza que SIEMPRE sea un símbolo válido (el modelo local no inventa nombres que
/// luego no renderizan). Conserva el color; solo cambia el icono.
///
/// EVITA REPETIR iconos: para cada colección la IA propone los 3 mejores (en orden) y se elige el
/// primero que aún NO se haya usado; solo se repite si no queda alternativa. Con el catálogo
/// ampliado, muchas colecciones del mismo tema (varias de IA) reciben iconos distintos pero
/// coherentes. Si la IA no da nada válido, mapeo determinista por palabra clave.
@MainActor
enum CollectionIconSuggester {

    /// Regenera el icono de TODAS las colecciones activas, evitando repeticiones. Devuelve cuántas
    /// cambió. Cancelable, con progreso por colección.
    @discardableResult
    static func regenerateAll(in context: ModelContext,
                              onProgress: @MainActor (Int, Int) -> Void = { _, _ in }) async -> Int {
        // Orden estable (alfabético) para que el reparto de iconos sea reproducible.
        let cols = ((try? context.fetch(FetchDescriptor<BookmarkCategory>())) ?? [])
            .filter { $0.deletedAt == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !cols.isEmpty else { return 0 }
        // El modelo debe estar cargado: `complete` devuelve nil si no. Lo pide el usuario.
        _ = await LocalAIRunner.shared.ensureReady(userInitiated: true)

        // Catálogo VALIDADO: descarta nombres que no existan en esta versión de macOS (no
        // renderizarían). Se calcula una vez por pasada.
        let catalog = IconCatalog.all.filter {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
        }
        guard !catalog.isEmpty else { return 0 }

        var used = Set<String>()
        var changed = 0
        for (index, col) in cols.enumerated() {
            if Task.isCancelled { break }
            onProgress(index, cols.count)
            guard col.modelContext != nil else { continue }

            let ranked = await suggestIcons(for: col.name, examples: catalog)
            // 1.º propuesto aún no usado; si todos están usados, 2.º un icono del catálogo curado
            // sin usar (para mantener variedad); si no queda ninguno, repite el mejor / conserva.
            let chosen = ranked.first { !used.contains($0) }
                ?? catalog.first { !used.contains($0) }
                ?? ranked.first
                ?? col.icon
            used.insert(chosen)
            guard col.modelContext != nil, chosen != col.icon else { continue }
            col.icon = chosen
            changed += 1
        }
        context.saveLogging()
        return changed
    }

    /// Los 3 MEJORES SF Symbols para una colección (en orden), elegidos LIBREMENTE por la IA de
    /// TODO el catálogo de SF Symbols del sistema (no de una lista fija) y VALIDADOS uno a uno con
    /// `NSImage(systemSymbolName:)` para descartar nombres inventados que no renderizarían. La
    /// lista `examples` (catálogo curado) se le pasa solo como EJEMPLOS y red de seguridad.
    static func suggestIcons(for name: String, examples: [String]) async -> [String] {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }

        // Muestra diversa de ejemplos (no toda la lista, para no anclar al modelo a ella): le
        // enseña el formato de nombre y le da opciones, pero puede usar CUALQUIER SF Symbol válido.
        let sample = exampleSample(from: examples)
        let system = "Eres un experto en SF Symbols de Apple. Para una colección de marcadores, "
            + "eliges los SF Symbols del sistema que MEJOR la representan. Respondes SOLO con "
            + "nombres EXACTOS de SF Symbols (minúsculas y puntos, p. ej. gamecontroller.fill), "
            + "separados por comas, sin explicación."
        let prompt = """
        Colección: «\(clean)»

        Dame los 3 MEJORES SF Symbols EN ORDEN (el más representativo primero), separados por comas.
        Usa el nombre EXACTO del sistema. Puedes usar CUALQUIER SF Symbol válido; ejemplos del estilo:
        \(sample)
        """
        if let response = await LocalAIRunner.shared.complete(
            system: system, prompt: prompt, maxTokens: 48, enableThinking: true) {
            let picks = parseSymbols(response)
            if !picks.isEmpty { return picks }
        }
        if let kw = keywordIcon(for: clean), isValidSymbol(kw) { return [kw] }
        return []
    }

    /// Extrae hasta 3 nombres de SF Symbol de la respuesta (en orden, sin repetir), VALIDANDO cada
    /// uno contra el sistema. Tolera numeración («1. …»), comillas y texto alrededor.
    private static func parseSymbols(_ response: String) -> [String] {
        var out: [String] = []
        let segments = response.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: ",\n;•*"))
        for segment in segments {
            // El nombre del símbolo suele ser el último «token» del segmento (tras «1. »).
            let last = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).last.map(String.init)
            let candidate = (last ?? segment)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()[]:"))
            guard candidate.range(of: "^[a-z0-9.]+$", options: .regularExpression) != nil,
                  candidate.count >= 2, isValidSymbol(candidate), !out.contains(candidate)
            else { continue }
            out.append(candidate)
            if out.count >= 3 { break }
        }
        return out
    }

    /// ¿Existe ese SF Symbol en ESTA versión de macOS? Valida contra TODO el catálogo del sistema.
    private static func isValidSymbol(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// Una muestra diversa (≈30) del catálogo curado para enseñar el formato sin anclar al modelo.
    private static func exampleSample(from catalog: [String]) -> String {
        guard catalog.count > 30 else { return catalog.joined(separator: ", ") }
        let step = catalog.count / 30
        let picked = stride(from: 0, to: catalog.count, by: max(1, step)).map { catalog[$0] }
        return picked.prefix(30).joined(separator: ", ")
    }

    /// Mapeo determinista nombre→icono como red de seguridad cuando la IA no da iconos válidos.
    private static func keywordIcon(for name: String) -> String? {
        let n = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let map: [(key: String, icon: String)] = [
            ("videojuego", "gamecontroller.fill"), ("consola", "formfitting.gamecontroller.fill"),
            ("juego", "gamecontroller.fill"), ("game", "gamecontroller.fill"),
            ("pixel", "paintbrush.pointed.fill"), ("stable diffusion", "wand.and.stars"),
            ("diffusion", "wand.and.stars"), ("lora", "wand.and.rays"),
            ("imagen", "photo.stack.fill"), ("foto", "photo.fill"), ("3d", "cube"),
            ("diseñ", "paintpalette.fill"), ("design", "swatchpalette.fill"), ("ui", "rectangle.3.group.fill"),
            ("animacion", "film.fill"), ("video", "play.rectangle.fill"),
            ("musica", "music.note"), ("music", "music.note"), ("sound", "waveform"),
            ("voice", "music.mic"), ("audio", "headphones"), ("tts", "speaker.wave.3.fill"),
            ("voz", "music.mic"), ("ocr", "doc.text.fill"),
            ("agente", "point.3.connected.trianglepath.dotted"), ("vlm", "eye.fill"),
            ("llm", "brain"), ("modelo", "cpu"), ("machine learning", "brain.head.profile"),
            (" ia", "brain.head.profile"), ("ia ", "brain.head.profile"), ("ai", "brain.head.profile"),
            ("base de dato", "cylinder.fill"), ("database", "cylinder.fill"),
            ("deploy", "paperplane.fill"), ("nube", "icloud.fill"), ("cloud", "cloud.fill"),
            ("desarrollo", "chevron.left.forwardslash.chevron.right"), ("code", "curlybraces"),
            ("codigo", "curlybraces"), ("github", "chevron.left.forwardslash.chevron.right"),
            ("dev", "hammer.fill"), ("api", "antenna.radiowaves.left.and.right"),
            ("herramienta", "wrench.and.screwdriver.fill"), ("tool", "wrench.adjustable.fill"),
            ("util", "slider.horizontal.3"),
            ("trading", "chart.line.uptrend.xyaxis"), ("finanz", "dollarsign.circle.fill"),
            ("seo", "magnifyingglass"),
            ("social", "person.3.fill"), ("red", "antenna.radiowaves.left.and.right"),
            ("navegador", "macwindow"), ("browser", "macwindow"), ("web", "globe"),
            ("sistema operativo", "desktopcomputer"), ("ios", "iphone"), ("ipad", "ipad"),
            ("mac", "desktopcomputer"), ("android", "laptopcomputer"), ("windows", "macwindow"),
            ("fuente", "textformat"), ("tipograf", "textformat.size"), ("font", "character"),
            ("lectura", "book.fill"), ("doc", "doc.richtext.fill"), ("recurso", "archivebox.fill"),
            ("seguridad", "shield.lefthalf.filled"), ("security", "lock.fill"),
        ]
        for entry in map where n.contains(entry.key) {
            if isValidSymbol(entry.icon) { return entry.icon }
        }
        return nil
    }
}
