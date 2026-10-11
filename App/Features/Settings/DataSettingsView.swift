import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import StacklumeCore
import StacklumeDesignSystem
import StacklumePersistence
import StacklumeMetadata

/// Importar / exportar la biblioteca.
struct DataSettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var links: [Bookmark]

    @State private var exportDoc: DataFile?
    @State private var exportType: UTType = .json
    @State private var exportName = "Stacklume"
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var importTypes: [UTType] = [.json]
    @State private var message: String?
    @State private var showResetConfirm = false

    // Importación nativa de navegadores (autodetectada).
    @State private var detectedBrowsers: [DetectedBrowser] = []
    @State private var scanning = false
    @State private var importingBrowser: String?

    // Importar estrellas de GitHub (por usuario).
    @State private var githubUser = ""
    @State private var importingGitHub = false

    // Copia sin conexión automática (opt-in). Misma clave que lee `OfflineAutoSaver`.
    @AppStorage(OfflineAutoSaver.defaultsKey) private var autoOffline = false
    // Detección automática de enlaces rotos en 2.º plano (opt-out). La lee `RootWindowView`.
    @AppStorage("stacklume.linkHealthAuto") private var autoHealth = true
    // Backup automático de la biblioteca (opt-out). La lee `AutoBackup`.
    @AppStorage(AutoBackup.enabledKey) private var autoBackup = true
    // Copia de seguridad DIARIA a una hora elegida, que sobrescribe la anterior (opt-out). `DailyBackup`.
    @AppStorage(DailyBackup.enabledKey) private var dailyBackup = true
    @AppStorage(DailyBackup.minuteOfDayKey) private var dailyMinute = DailyBackup.defaultMinuteOfDay
    // Adquisición automática de portadas en 2.º plano (opt-out). La lee `CoverAutoFiller`.
    @AppStorage(CoverAutoFiller.defaultsKey) private var autoCover = true

    private var activeLinks: [Bookmark] { links.filter { $0.deletedAt == nil } }

    var body: some View {
        Form {
            browsersSection
            Section("Exportar") {
                Button("Exportar a JSON") { exportJSON() }
                Button("Exportar a HTML (marcadores)") { exportHTML() }
                Button("Exportar a Markdown") { exportMarkdown() }
                Button("Exportar a CSV") { exportCSV() }
                Button("Exportar a PDF") { exportPDF() }
            }
            Section {
                Button("Importar desde JSON") { importTypes = [.json]; isImporting = true }
                Button("Importar desde HTML") { importTypes = [.html]; isImporting = true }
                Button("Importar desde CSV") { importTypes = [.commaSeparatedText]; isImporting = true }
            } header: {
                Text("Importar")
            } footer: {
                Text("HTML y CSV admiten las exportaciones de Pocket, Raindrop, Pinboard y los navegadores: las carpetas se convierten en colecciones, se omiten los duplicados y todo se autorrellena con la IA local. JSON restaura una copia de Stacklume.")
                    .stacklumeFont(.caption)
            }
            githubStarsSection
            offlineSection
            if let message {
                Section { Text(message).stacklumeFont(.callout).foregroundStyle(.secondary) }
            }
            Section {
                Button(role: .destructive) { showResetConfirm = true } label: {
                    Label("Restablecer aplicación…", systemImage: "trash.fill")
                }
            } header: {
                Text("Zona de peligro")
            } footer: {
                Text("Borra la biblioteca activa y todos los chats para empezar de cero. Conserva tus preferencias y las copias de seguridad, que solo se recuperarán si lo solicitas. Si quieres conservar tu biblioteca, expórtala antes.")
                    .stacklumeFont(.caption)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(WindowBackground())
        .confirmationDialog("¿Restablecer Stacklume?", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("Borrar todo definitivamente", role: .destructive) { performReset() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se eliminarán \(activeLinks.count) enlace\(activeLinks.count == 1 ? "" : "s"), las colecciones, etiquetas, proyectos, sesiones, resaltados y chats. Las copias de seguridad se conservan para una restauración manual.")
        }
        .fileExporter(isPresented: $isExporting, document: exportDoc,
                      contentType: exportType, defaultFilename: exportName) { result in
            if case .failure(let error) = result {
                message = "No se pudo exportar: \(error.localizedDescription)"
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: importTypes) { result in
            if case .success(let url) = result { importFrom(url) }
        }
        .task { if detectedBrowsers.isEmpty { scan() } }
    }

    // MARK: - Copia sin conexión automática (opt-in)

    /// Sección del guardado offline automático. DESACTIVADO por defecto: guardar la copia
    /// de toda la biblioteca puede ocupar bastante disco, así que lo decide el usuario.
    /// Puente entre los MINUTOS desde medianoche que guarda `DailyBackup` y el `Date` que pide el
    /// `DatePicker` (solo hora/minuto). Hoy a esa hora; al cambiarlo, persiste hora·60 + minuto.
    private var dailyTimeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: dailyMinute / 60, minute: dailyMinute % 60,
                                      second: 0, of: Date()) ?? Date()
            },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                dailyMinute = (c.hour ?? 9) * 60 + (c.minute ?? 0)
            }
        )
    }

    private var offlineSection: some View {
        Section {
            Toggle("Guardar copia sin conexión automáticamente", isOn: $autoOffline)
            Toggle("Detectar enlaces rotos automáticamente", isOn: $autoHealth)
            Toggle("Obtener portadas automáticamente", isOn: $autoCover)
            Toggle("Backup automático de la biblioteca", isOn: $autoBackup)
            Toggle("Copia de seguridad diaria", isOn: $dailyBackup)
            if dailyBackup {
                DatePicker("Hora de la copia diaria", selection: dailyTimeBinding,
                           displayedComponents: .hourAndMinute)
                Button("Hacer la copia diaria ahora") {
                    message = DailyBackup.runNow(in: context)
                        ? "Copia diaria guardada."
                        : "No se pudo hacer la copia diaria."
                }
            }
        } header: {
            Text("Sin conexión, enlaces y backup")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Al activar la copia sin conexión, Stacklume descarga en segundo plano una copia legible de cada enlace para leerlo y resaltarlo sin conexión. Se guarda de pocos en pocos. Desactivado por defecto porque puede ocupar bastante disco; puedes seguir guardando copias a mano desde la ficha de cada enlace.")
                Text("«Detectar enlaces rotos» comprueba poco a poco, en segundo plano, si tus enlaces siguen vivos y marca los caídos (los verás en el filtro «Enlaces rotos» del lateral). Solo contacta con las páginas que ya guardaste; si no hay conexión, no marca nada.")
                Text("«Obtener portadas automáticamente» busca en segundo plano la imagen de los enlaces que se quedaron sin ella (sobre todo importaciones masivas), de pocos en pocos. Usa la imagen de la propia página (og:image o el «hero»); 100 % local. Si lo desactivas, puedes obtenerla a mano desde el botón de portada de cada ficha.")
                Text("«Backup automático» guarda cada pocos días una copia COMPLETA de tu biblioteca (con resaltados, notas, recordatorios y portadas) en «Application Support/Stacklume/Backups», conservando los últimos 7. Es local; nada sale de tu Mac. La papelera se vacía sola pasados 30 días.")
                Text("«Copia de seguridad diaria» guarda CADA DÍA, a la hora que elijas, una copia COMPLETA que sobrescribe la del día anterior («stacklume-diario.json», siempre la más reciente). Es una red de seguridad extra, además de los backups automáticos y los que hagas a mano. Si la app está cerrada a esa hora, se hace en cuanto la abras ese día.")
            }
            .stacklumeFont(.caption)
        }
    }

    // MARK: - Importar desde navegadores (autodetectado)

    @ViewBuilder
    private var browsersSection: some View {
        Section {
            if scanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Buscando navegadores…").foregroundStyle(.secondary)
                }
            } else if detectedBrowsers.isEmpty {
                Text("No se detectaron navegadores con marcadores. Safari requiere darle a Stacklume «Acceso a Disco Completo» en Ajustes del sistema › Privacidad y seguridad.")
                    .stacklumeFont(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(detectedBrowsers) { detected in
                    HStack(spacing: 10) {
                        Image(systemName: detected.browser.icon)
                            .foregroundStyle(.tint)
                            .frame(width: 22)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(detected.displayName)
                            Text("\(detected.count) marcador\(detected.count == 1 ? "" : "es")")
                                .stacklumeFont(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if importingBrowser == detected.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Importar") { importBrowser(detected) }
                        }
                    }
                }
            }
            Button { scan() } label: {
                Label("Volver a buscar", systemImage: "arrow.clockwise")
            }
            .stacklumeFont(.caption)
            .disabled(scanning)
            .themedHelp("Vuelve a buscar los navegadores instalados con marcadores")
        } header: {
            Text("Importar desde tus navegadores")
        } footer: {
            Text("Stacklume lee los marcadores directamente de los navegadores instalados (Chrome, Brave, Edge, Vivaldi, Opera) — sin exportar nada. Las carpetas se convierten en colecciones y los enlaces se autorrellenan (imagen, descripción, categoría y etiquetas) con la IA local.")
                .stacklumeFont(.caption)
        }
    }

    /// Detecta los navegadores con marcadores (fuera del hilo principal; lectura rápida).
    private func scan() {
        scanning = true
        Task { @MainActor in
            let found = await Task.detached(priority: .userInitiated) { BrowserImporter.detect() }.value
            detectedBrowsers = found
            scanning = false
        }
    }

    /// Importa los marcadores de un navegador reutilizando el runner compartido
    /// ([[BrowserImportRunner]]): colecciones desde carpetas, dedup por URL y
    /// autoenriquecido (red + IA local) en 2.º plano.
    private func importBrowser(_ detected: DetectedBrowser) {
        importingBrowser = detected.id
        let r = BrowserImportRunner.run(detected, in: context)
        importingBrowser = nil
        if let error = r.error { message = error; return }
        message = "Importados \(r.added) marcadores de \(detected.displayName)"
            + (r.skipped > 0 ? " (\(r.skipped) duplicado\(r.skipped == 1 ? "" : "s") omitido\(r.skipped == 1 ? "" : "s"))." : ".")
        scan()
    }

    // MARK: - Importar estrellas de GitHub

    @ViewBuilder
    private var githubStarsSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                TextField("Usuario de GitHub", text: $githubUser)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit { importGitHubStars() }
                    .disabled(importingGitHub)
                if importingGitHub {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Importar") { importGitHubStars() }
                        .disabled(githubUser.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } header: {
            Text("Importar estrellas de GitHub")
        } footer: {
            Text("Trae los repositorios que has marcado con estrella a una colección «GitHub Stars», con su descripción y lenguaje. Se autorrellenan con la IA local. Sin necesidad de iniciar sesión.")
                .stacklumeFont(.caption)
        }
    }

    /// Trae las estrellas de GitHub del usuario (API pública, en 2.º plano) y las pasa por
    /// el núcleo de ingesta compartido ([[BrowserImportRunner]]): colección, dedup y IA.
    private func importGitHubStars() {
        let user = githubUser.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !importingGitHub else { return }
        importingGitHub = true
        message = nil
        Task { @MainActor in
            defer { importingGitHub = false }
            do {
                let entries = try await GitHubStarsImporter.fetch(username: user)
                guard !entries.isEmpty else {
                    message = "@\(user) no tiene repositorios con estrella públicos."
                    return
                }
                let r = BrowserImportRunner.ingest(entries, in: context)
                if let error = r.error { message = error; return }
                message = "Importadas \(r.added) estrellas de @\(user)"
                    + (r.skipped > 0 ? " (\(r.skipped) ya estaba\(r.skipped == 1 ? "" : "n")). Organizando con IA…" : ". Organizando con IA…")
            } catch {
                message = (error as? GitHubStarsImporter.ImportError)?.errorDescription
                    ?? "No se pudo importar: \(error.localizedDescription)"
            }
        }
    }

    /// Restablece la app: borra todo el contenido (conservando preferencias) y devuelve
    /// la ventana principal a «Todos» para que no quede apuntando a algo ya borrado.
    private func performReset() {
        let count: Int
        do { count = try LibraryReset.wipeEverything(in: context) }
        catch {
            context.rollback()
            message = "No se pudo completar el restablecimiento: \(error.localizedDescription)"
            return
        }
        NotificationCenter.default.post(name: .stacklumeGoToSection, object: NavTarget.all.key)
        message = count == 0
            ? "Aplicación restablecida. La biblioteca ya estaba vacía."
            : "Aplicación restablecida: \(count) enlace\(count == 1 ? "" : "s") y todo el contenido eliminados."
    }

    private func present(_ data: Data, type: UTType, name: String) {
        exportDoc = DataFile(data); exportType = type; exportName = name; isExporting = true
    }
    private func exportJSON() {
        do {
            // Export COMPLETO: base del paquete + extras (resaltados/notas/recordatorios/
            // progreso/portadas/búsquedas guardadas), para que el round-trip no pierda nada.
            let data = try CompleteBackupService.export(from: context)
            present(data, type: .json, name: "Stacklume")
        } catch {
            message = "No se pudo exportar: \(error.localizedDescription)"
        }
    }
    private func exportHTML() {
        let html = NetscapeBookmarks.export(activeLinks)
        present(Data(html.utf8), type: .html, name: "Stacklume-marcadores")
    }
    private func exportPDF() {
        present(PDFExporter.makePDF(from: activeLinks), type: .pdf, name: "Stacklume")
    }
    private func exportMarkdown() {
        let md = Self.makeMarkdown(activeLinks)
        let type = UTType(filenameExtension: "md") ?? .plainText
        present(Data(md.utf8), type: type, name: "Stacklume")
    }
    private func exportCSV() {
        present(Data(Self.makeCSV(activeLinks).utf8), type: .commaSeparatedText, name: "Stacklume")
    }

    /// Markdown agrupado por colección: `- [título](url) — #tags`. Reimportable como texto.
    private static func makeMarkdown(_ links: [Bookmark]) -> String {
        let grouped = Dictionary(grouping: links) { $0.category?.name ?? "Sin colección" }
        var out = "# Stacklume\n\n"
        for key in grouped.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            out += "## \(key)\n\n"
            for l in (grouped[key] ?? []).sorted(by: { $0.createdAt < $1.createdAt }) {
                let title = l.title.isEmpty ? l.url : l.title
                out += "- [\(title)](\(l.url))"
                if !l.tags.isEmpty { out += " — " + l.tags.map { "#\($0.name)" }.joined(separator: " ") }
                out += "\n"
            }
            out += "\n"
        }
        return out
    }

    /// CSV reimportable (mismas columnas que reconoce el importador): url, title, tags, folder, note, created.
    private static func makeCSV(_ links: [Bookmark]) -> String {
        let df = ISO8601DateFormatter()
        var out = "url,title,tags,folder,note,created\n"
        for l in links.sorted(by: { $0.createdAt < $1.createdAt }) {
            let cols = [
                l.url,
                l.title,
                l.tags.map(\.name).joined(separator: ", "),
                l.category?.name ?? "",
                l.notes ?? "",
                df.string(from: l.createdAt),
            ]
            out += cols.map(CSVFieldEncoder.encode).joined(separator: ",") + "\n"
        }
        return out
    }
    private func importFrom(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Lectura incremental: el límite se aplica aunque el proveedor no publique `fileSize`.
        guard let data = try? BoundedFileReader.read(
            url,
            maximumBytes: 256 * 1_024 * 1_024
        ) else {
            message = "No se pudo leer el archivo o supera el máximo de 256 MB."
            return
        }
        let ext = url.pathExtension.lowercased()
        do {
            if ["csv", "html", "htm"].contains(ext), data.count > ImportSafety.maximumTextBytes {
                throw ImportSafetyError.limitExceeded
            }
            if ext == "csv" {
                try importCSV(data)
            } else if ext == "html" || ext == "htm" {
                // Parser CON carpetas + núcleo de ingesta compartido: igual de completo que el
                // import de navegadores (dedup, carpetas → colecciones y autoenriquecido con IA).
                let entries = try NetscapeHTMLImporter.parseChecked(String(decoding: data, as: UTF8.self))
                let r = BrowserImportRunner.ingest(entries, in: context)
                if let error = r.error { message = error; return }
                message = "Importados \(r.added) marcadores del archivo"
                    + (r.skipped > 0 ? " (\(r.skipped) duplicado\(r.skipped == 1 ? "" : "s") omitido\(r.skipped == 1 ? "" : "s"))." : ".")
            } else {
                do {
                    let r: BackupService.MergeResult
                    var additionalAttachmentLinks = 0
                    _ = try ImportSafety.jsonObject(data)
                    if WindowsBackupImporter.canImport(data) {
                        // Export del Stacklume de WINDOWS (formato relacional): se traduce al formato
                        // del Mac y se fusiona con la misma lógica (dedup, jerarquía, enums).
                        r = try WindowsBackupImporter.merge(data, into: context)
                    } else {
                        // Biblioteca NATIVA del Mac.
                        r = try MacBackupImport.merge(data, into: context)
                        // Restaura los extras del backup completo (resaltados/notas/recordatorios/
                        // progreso/portadas/búsquedas). Si el archivo no los lleva, no hace nada.
                        let extras = CompleteBackupService.restoreExtras(from: data, in: context)
                        additionalAttachmentLinks = extras.createdLinks
                    }
                    message = "Añadidos: \(r.addedLinks + additionalAttachmentLinks) enlaces, \(r.addedCategories) colecciones, \(r.addedTags) etiquetas."
                } catch is DecodingError {
                    message = "El archivo no es una biblioteca válida."
                } catch {
                    message = "No se pudo importar: \(error.localizedDescription)"
                }
            }
        } catch {
            message = "No se pudo importar: \(error.localizedDescription)"
        }
    }

    /// Importa un CSV de Pocket / Raindrop / navegadores. Detecta las columnas por su
    /// cabecera (url, title, tags, folder), omite los duplicados por URL y reutiliza las
    /// colecciones y etiquetas existentes (sin duplicarlas).
    private func importCSV(_ data: Data) throws {
        let rows = try BoundedCSVImporter.parse(String(decoding: data, as: UTF8.self))
        guard rows.count > 1 else { message = "El CSV está vacío o no tiene datos."; return }
        let header = rows[0].map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func col(_ names: [String]) -> Int? { names.lazy.compactMap { header.firstIndex(of: $0) }.first }
        guard let urlIdx = col(["url", "link", "uri"]) else {
            message = "El CSV no tiene una columna de URL (url/link)."; return
        }
        let titleIdx = col(["title", "name"])
        let tagsIdx = col(["tags", "tag", "labels"])
        let folderIdx = col(["folder", "collection", "category"])

        for row in rows.dropFirst() {
            for index in [urlIdx, titleIdx, folderIdx, tagsIdx].compactMap({ $0 }) where index < row.count {
                guard row[index].utf8.count <= ImportSafety.maximumShortFieldBytes else {
                    throw ImportSafetyError.limitExceeded
                }
            }
            if let index = tagsIdx, index < row.count,
               row[index].split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "|" }).count > 256 {
                throw ImportSafetyError.limitExceeded
            }
        }

        var existing = Set(activeLinks.map { BrowserImportRunner.normalizeURL($0.url) })
        var catCache: [String: BookmarkCategory] = [:]
        for c in (((try? context.fetch(FetchDescriptor<BookmarkCategory>())) ?? []).filter { $0.deletedAt == nil }) {
            catCache[CollectionMerger.canonical(c.name)] = c
        }
        var tagCache: [String: Tag] = [:]
        for t in ((try? context.fetch(FetchDescriptor<Tag>())) ?? []).filter({ $0.deletedAt == nil }) {
            tagCache[EntityResolver.tagKey(t.name)] = t
        }
        func field(_ row: [String], _ idx: Int?) -> String {
            guard let idx, idx < row.count else { return "" }
            return row[idx].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var added = 0, skipped = 0
        var newLinks: [Bookmark] = []
        for row in rows.dropFirst() {
            let raw = field(row, urlIdx)
            // Acepta también comandos de instalación (npm i…, pip install…): se guardan
            // apuntando a la página del paquete con el comando para copiar → «importa todo».
            let commandInfo = CommandDetector.detect(raw)
            let candidateURL = commandInfo?.registryURL ?? raw
            guard let validatedURL = DroppedContentImporter.validatedWebURL(candidateURL) else {
                skipped += 1
                continue
            }
            let effectiveURL = validatedURL.absoluteString
            let key = BrowserImportRunner.normalizeURL(effectiveURL)
            if existing.contains(key) { skipped += 1; continue }
            existing.insert(key)
            let detected = PlatformDetector.detect(effectiveURL)
            let csvTitle = field(row, titleIdx)
            let link = Bookmark(url: effectiveURL,
                                title: csvTitle.isEmpty ? (commandInfo?.packageName ?? "") : csvTitle,
                                platform: commandInfo?.platform ?? detected.platform,
                                contentType: commandInfo != nil ? .code : detected.contentType)
            link.platformColor = commandInfo?.colorHex ?? detected.brandColorHex
            link.command = commandInfo?.command
            let folder = field(row, folderIdx)
            if !folder.isEmpty, folder.lowercased() != "unsorted" {
                link.category = BrowserImportRunner.resolveCategory(folder, in: context, cache: &catCache)
            }
            for rawTag in field(row, tagsIdx).split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "|" }) {
                guard let name = TagSanitizer.clean(String(rawTag)),
                      let tag = EntityResolver.tag(name, in: context, cache: &tagCache) else { continue }
                if !link.tags.contains(where: { $0.id == tag.id }) { link.tags.append(tag) }
            }
            context.insert(link)
            newLinks.append(link)
            added += 1
        }
        do {
            try context.save()
            NotificationCenter.default.post(name: .stacklumeModelDidSave, object: nil)
            WidgetReloader.reload()
            // Autoenriquecido en 2.º plano (metadatos de red + IA si está lista), igual que
            // el resto de importadores: el CSV ya no deja enlaces «en crudo».
            BrowserImportRunner.autoEnrich(newLinks, in: context)
            message = "Importados \(added) enlaces del CSV"
                + (skipped > 0 ? " (\(skipped) duplicado\(skipped == 1 ? "" : "s") omitido\(skipped == 1 ? "" : "s"))." : ".")
        } catch {
            message = "No se pudo importar: \(error.localizedDescription)"
        }
    }


}

/// Importa exports JSON del **Stacklume de Windows** (formato RELACIONAL: `links` / `categories`
/// / `tags` / `linkTags`, con ids UUID, colores con NOMBRE de Tailwind y fechas ISO con
/// milisegundos). Los traduce al formato `BackupData` del Mac y reutiliza `BackupService.merge`
/// (misma lógica probada: reutiliza colecciones/etiquetas por nombre, deduplica enlaces por URL,
/// reconstruye la jerarquía y mapea los enums). El JSON NATIVO del Mac lo sigue gestionando
/// `MacBackupImport.merge` (este importador solo actúa si detecta el formato Windows).
///
/// Por qué hacía falta: el export de Windows no decodificaba como `BackupData` (claves distintas
/// —`color` vs `colorHex`, `categoryId` vs `categoryID`, `imageUrl` vs `imageURL`, `isRead` vs
/// `readingStatus`—, etiquetas en una tabla de unión en vez de `tagIDs`, colores con nombre y
/// fechas con milisegundos que `.iso8601` no parsea). Por eso «no importaba nada».
enum WindowsBackupImporter {

    // MARK: - Formato del export de Windows (lo que LEEMOS)

    private struct WinBackup: Decodable {
        var links: [WinLink]
        var categories: [WinCategory]
        var tags: [WinTag]
        var linkTags: [WinLinkTag]
    }
    private struct WinCategory: Decodable {
        var id: String
        var name: String
        var icon: String?
        var color: String?
        var order: Int?
        var parentCategoryId: String?
        var description: String?
    }
    private struct WinTag: Decodable {
        var id: String
        var name: String
        var color: String?
        var order: Int?
    }
    private struct WinLink: Decodable {
        var id: String
        var url: String
        var title: String?
        var description: String?
        var imageUrl: String?
        var faviconUrl: String?
        var categoryId: String?
        var siteName: String?
        var isFavorite: Bool?
        var isRead: Bool?
        var platform: String?
        var contentType: String?
        var platformColor: String?
        var order: Int?
        var createdAt: String?
        var notes: String?
    }
    private struct WinLinkTag: Decodable {
        var linkId: String
        var tagId: String
    }

    // MARK: - Formato BackupData del Mac (lo que ESCRIBIMOS). Mismas CLAVES que los DTO del
    // paquete (sin CodingKeys propias), pero structs nuestras porque el init memberwise de los
    // DTO públicos del paquete es `internal` (no accesible desde la App).

    private struct OutBackup: Encodable {
        let version: String
        let exportedAt: Date
        let categories: [OutCategory]
        let tags: [OutTag]
        let links: [OutLink]
        let rules: [String]   // siempre vacío → JSON `[]`, válido como `[RuleDTO]`
    }
    private struct OutCategory: Encodable {
        let id: UUID
        let name: String
        let details: String?
        let icon: String
        let colorHex: String
        let order: Int
        let parentID: UUID?
        let coverImageData: Data?
    }
    private struct OutTag: Encodable {
        let id: UUID
        let name: String
        let colorHex: String
        let order: Int
        let parentID: UUID?
    }
    private struct OutLink: Encodable {
        let id: UUID
        let url: String
        let title: String
        let details: String?
        let imageURL: String?
        let faviconURL: String?
        let siteName: String?
        let isFavorite: Bool
        let notes: String?
        let readingStatus: String
        let platform: String
        let contentType: String
        let platformColor: String?
        let order: Int
        let categoryID: UUID?
        let tagIDs: [UUID]
        let createdAt: Date
        let command: String?
    }

    // MARK: - API

    /// ¿Es un export de Stacklume Windows? La firma inequívoca es la tabla de unión `linkTags`
    /// (el formato del Mac mete las etiquetas dentro de cada enlace como `tagIDs`).
    static func canImport(_ data: Data) -> Bool {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return obj["linkTags"] != nil && obj["links"] is [Any] && obj["categories"] != nil
    }

    /// Traduce y fusiona. Conserva nombres, colores (mapeados a hex), iconos, favoritos, notas,
    /// fechas, y las relaciones colección/etiquetas tal cual en el JSON.
    @MainActor
    static func merge(_ data: Data, into context: ModelContext) throws -> BackupService.MergeResult {
        _ = try ImportSafety.jsonObject(data)
        let win = try JSONDecoder().decode(WinBackup.self, from: data)
        guard win.links.count <= ImportSafety.maximumRecords,
              win.categories.count <= ImportSafety.maximumRecords,
              win.tags.count <= ImportSafety.maximumRecords,
              win.linkTags.count <= 200_000 else { throw ImportSafetyError.limitExceeded }

        // Tabla de unión → etiquetas por enlace.
        var tagsByLink: [String: [UUID]] = [:]
        for lt in win.linkTags {
            guard let tid = UUID(uuidString: lt.tagId) else { continue }
            tagsByLink[lt.linkId, default: []].append(tid)
        }

        let categories = win.categories.map { c in
            OutCategory(id: UUID(uuidString: c.id) ?? UUID(),
                        name: c.name,
                        details: Self.nonEmpty(c.description),
                        icon: Self.nonEmpty(c.icon) ?? "folder",
                        colorHex: Self.hex(c.color),
                        order: c.order ?? 0,
                        parentID: c.parentCategoryId.flatMap { UUID(uuidString: $0) },
                        coverImageData: nil)
        }
        let tags = win.tags.map { t in
            OutTag(id: UUID(uuidString: t.id) ?? UUID(),
                   name: t.name,
                   colorHex: Self.hex(t.color),
                   order: t.order ?? 0,
                   parentID: nil)
        }
        let links = win.links.map { l in
            OutLink(id: UUID(uuidString: l.id) ?? UUID(),
                    url: l.url,
                    title: Self.nonEmpty(l.title) ?? l.url,
                    details: Self.nonEmpty(l.description),
                    imageURL: Self.nonEmpty(l.imageUrl),
                    faviconURL: Self.nonEmpty(l.faviconUrl),
                    siteName: Self.nonEmpty(l.siteName),
                    isFavorite: l.isFavorite ?? false,
                    notes: Self.nonEmpty(l.notes),
                    readingStatus: (l.isRead == true) ? "done" : "inbox",
                    platform: Self.platform(l.platform),
                    contentType: Self.contentType(l.contentType),
                    platformColor: Self.nonEmpty(l.platformColor),
                    order: l.order ?? 0,
                    categoryID: l.categoryId.flatMap { UUID(uuidString: $0) },
                    tagIDs: tagsByLink[l.id] ?? [],
                    createdAt: Self.date(l.createdAt),
                    command: nil)
        }

        let out = OutBackup(version: "windows-import", exportedAt: Date(),
                            categories: categories, tags: tags, links: links, rules: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601   // misma estrategia que el decoder de `merge`
        let translated = try encoder.encode(out)
        return try MacBackupImport.merge(translated, into: context)
    }

    // MARK: - Mapeos

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// Color con NOMBRE (paleta Tailwind del export de Windows) → hex `#RRGGBB`. Si ya es hex,
    /// se respeta; desconocido → azul de marca por defecto.
    private static func hex(_ raw: String?) -> String {
        guard let n = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { return "#7AA2F7" }
        if n.hasPrefix("#") { return n }
        return namedColors[n.lowercased()] ?? "#7AA2F7"
    }
    private static let namedColors: [String: String] = [
        "amber": "#F59E0B", "blue": "#3B82F6", "cyan": "#06B6D4", "emerald": "#10B981",
        "fuchsia": "#D946EF", "gold": "#D4A853", "green": "#22C55E", "indigo": "#6366F1",
        "lime": "#84CC16", "orange": "#F97316", "pink": "#EC4899", "purple": "#A855F7",
        "red": "#EF4444", "rose": "#F43F5E", "sky": "#0EA5E9", "slate": "#64748B",
        "teal": "#14B8A6", "violet": "#8B5CF6", "yellow": "#EAB308",
        "gray": "#94A3B8", "grey": "#94A3B8", "magenta": "#D946EF", "turquoise": "#14B8A6",
    ]

    /// Plataforma de Windows → rawValue de `Platform` del Mac (lo que no coincide cae a `.generic`
    /// en `merge`). La mayoría coinciden literalmente (github, twitter, steam, itch, codepen…).
    private static func platform(_ s: String?) -> String {
        switch (s ?? "").lowercased() {
        case "google-drive", "googledrive": return "googleDrive"
        case "google-docs", "googledocs": return "googleDocs"
        case "apple-music", "applemusic": return "appleMusic"
        case "hacker-news", "hackernews": return "hackerNews"
        case "app-store", "appstore": return "appStore"
        case "", "generic": return "generic"
        default: return s ?? "generic"
        }
    }
    /// Tipo de contenido de Windows → rawValue de `ContentType` del Mac. «image» no existe en el
    /// Mac → «design» (lo más cercano); lo demás coincide (article, code, document, game, social…).
    private static func contentType(_ s: String?) -> String {
        switch (s ?? "").lowercased() {
        case "image": return "design"
        case "": return "website"
        default: return s ?? "website"
        }
    }

    private nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    /// Parsea la fecha ISO de Windows (con milisegundos `…51.958Z`, que `.iso8601` no acepta).
    private static func date(_ s: String?) -> Date {
        guard let s, !s.isEmpty else { return Date() }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s) ?? Date()
    }
}
