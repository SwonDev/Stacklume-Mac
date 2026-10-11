import SwiftUI
import SwiftData
import StacklumeCore
import StacklumeDesignSystem
import StacklumeMetadata
import StacklumePersistence

// MARK: - Runner reutilizable

/// Ejecuta la importación de un navegador en el `ModelContext`: crea colecciones desde
/// las carpetas, deduplica por URL y lanza el autoenriquecido (red + IA local) en 2.º
/// plano. Compartido por Ajustes › Datos y el onboarding del estado vacío (no duplicar).
@MainActor
enum BrowserImportRunner {
    struct Result { let added: Int; let skipped: Int; var error: String? = nil }

    @discardableResult
    static func run(_ detected: DetectedBrowser, in context: ModelContext) -> Result {
        do { return ingest(try BrowserImporter.parseChecked(detected), in: context) }
        catch { return Result(added: 0, skipped: 0, error: error.localizedDescription) }
    }

    /// Núcleo de ingesta compartido por TODOS los orígenes (navegadores, archivo HTML de
    /// marcadores, GitHub Stars…): deduplica por URL ([[CanonicalURL]]), convierte las
    /// carpetas en colecciones (reutilizando las existentes), siembra la descripción si el
    /// origen la trae y lanza el autoenriquecido (red + IA local) en 2.º plano. Centralizar
    /// aquí evita duplicar la lógica de guardado por cada origen.
    @discardableResult
    static func ingest(_ bookmarks: [BrowserBookmark], in context: ModelContext) -> Result {
        do { try ImportSafety.validateBookmarks(bookmarks) }
        catch { return Result(added: 0, skipped: 0, error: error.localizedDescription) }
        let activeDescriptor = FetchDescriptor<Bookmark>(
            predicate: #Predicate { $0.deletedAt == nil }
        )
        let active = (try? context.fetch(activeDescriptor)) ?? []
        var existing = Set(active.map { normalizeURL($0.url) })
        var catCache: [String: BookmarkCategory] = [:]
        let categoryDescriptor = FetchDescriptor<BookmarkCategory>(
            predicate: #Predicate { $0.deletedAt == nil }
        )
        for c in (try? context.fetch(categoryDescriptor)) ?? [] {
            catCache[CollectionMerger.canonical(c.name)] = c
        }
        var added = 0, skipped = 0
        var newLinks: [Bookmark] = []
        for bm in bookmarks {
            // Todo origen externo converge aquí. No basta con `hasPrefix("http")`:
            // también aceptaría esquemas como `httpx:` y URLs con credenciales.
            guard let acceptedURL = DroppedContentImporter.validatedWebURL(bm.url) else {
                skipped += 1
                continue
            }
            let storedURL = acceptedURL.absoluteString
            let key = normalizeURL(storedURL)
            if existing.contains(key) { skipped += 1; continue }
            existing.insert(key)
            let d = PlatformDetector.detect(storedURL)
            let link = Bookmark(url: storedURL, title: bm.title,
                                platform: d.platform, contentType: d.contentType)
            link.platformColor = d.brandColorHex
            if let detail = bm.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
               !detail.isEmpty {
                link.details = detail
            }
            if !bm.folder.isEmpty {
                link.category = resolveCategory(bm.folder, in: context, cache: &catCache)
            }
            context.insert(link)
            newLinks.append(link)
            added += 1
        }
        context.saveLogging()
        WidgetReloader.reload()
        autoEnrich(newLinks, in: context)
        return Result(added: added, skipped: skipped)
    }

    /// Clave de deduplicación EXACTA ([[CanonicalURL]]): solo se omite al importar el
    /// MISMO enlace (normaliza host/esquema y barra final; no toca query/fragmento/www).
    static func normalizeURL(_ url: String) -> String { CanonicalURL.key(url) }

    /// Find-or-create de colección CANÓNICO (reutiliza equivalentes por sinónimo/traducción/
    /// acento; ver `EntityResolver`). `nil` solo si el nombre queda vacío.
    static func resolveCategory(_ name: String, in context: ModelContext,
                                cache: inout [String: BookmarkCategory]) -> BookmarkCategory? {
        EntityResolver.category(name, in: context, cache: &cache)
    }

    /// Autoenriquecido en 2.º plano de los enlaces recién importados: si la IA local
    /// está lista, hace red + IA (categoría/etiquetas/descripción); si no, solo red.
    /// Compartido por todos los importadores (navegador, HTML, CSV) para no duplicar.
    static func autoEnrich(_ links: [Bookmark], in context: ModelContext) {
        guard !links.isEmpty else { return }
        let language = AppSettingsStore.current(in: context).language.rawValue
        let aiOn = (UserDefaults.standard.object(forKey: "stacklume.aiAutoEnrich") as? Bool) ?? true
        Task { @MainActor in
            if aiOn, LocalAIRunner.shared.isDownloaded, !LocalAIRunner.shared.isDeactivated {
                await AIBatchEnricher.enrich(in: context, provider: "liquid",
                                             language: language, limit: max(200, links.count))
            } else {
                for link in links where link.modelContext != nil {
                    await MacLinkEnricher.enrichFromNetwork(link, in: context, overwriteTitle: false)
                }
            }
            WidgetReloader.reload()
        }
    }
}

// MARK: - Onboarding del estado vacío

/// Tarjeta que aparece en el estado vacío de la biblioteca (primer uso): autodetecta
/// los navegadores instalados y ofrece traer sus marcadores con un clic. Es el momento
/// donde «automático/autodetectable» más valor aporta. Si no hay navegadores legibles,
/// no muestra nada.
struct BrowserImportOnboarding: View {
    @Environment(\.modelContext) private var context
    @Environment(\.themePalette) private var palette

    @State private var browsers: [DetectedBrowser] = []
    @State private var importing: String?
    @State private var resultMessage: String?

    var body: some View {
        Group {
            if !browsers.isEmpty {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "square.and.arrow.down.on.square.fill")
                            .foregroundStyle(palette.accent)
                        Text("Importa tus marcadores")
                            .stacklumeFont(.headline)
                            .foregroundStyle(palette.textPrimary)
                    }
                    Text("Hemos detectado tus navegadores. Tráelos con un clic: las carpetas se vuelven colecciones y todo se autorrellena con la IA local.")
                        .stacklumeFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(browsers) { detected in
                        Divider().overlay(palette.border.opacity(0.4))
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Image(systemName: detected.browser.icon)
                                .foregroundStyle(palette.accent)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(detected.displayName)
                                    .stacklumeFont(.subheadline.weight(.medium))
                                    .foregroundStyle(palette.textPrimary)
                                Text("\(detected.count) marcador\(detected.count == 1 ? "" : "es")")
                                    .stacklumeFont(.caption2)
                                    .foregroundStyle(palette.textSecondary)
                            }
                            Spacer(minLength: 0)
                            if importing == detected.id {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Importar") { runImport(detected) }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .tint(palette.accent)
                            }
                        }
                    }
                    if let resultMessage {
                        Text(resultMessage)
                            .stacklumeFont(.caption2)
                            .foregroundStyle(Color(hex: "#22C55E"))
                    }
                }
                .padding(DesignSystem.Spacing.md)
                .frame(maxWidth: 420)
                .background(palette.surface,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.border.opacity(0.5), lineWidth: 0.5))
            } else {
                // Vista REAL de tamaño 0: un `Group` que solo produce `EmptyView` no
                // dispara `.task`, así que la detección nunca correría y la tarjeta no
                // llegaría a mostrarse. Con esto el `.task` siempre se ejecuta.
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .task {
            if browsers.isEmpty {
                browsers = await Task.detached(priority: .userInitiated) {
                    BrowserImporter.detect()
                }.value
            }
        }
    }

    private func runImport(_ detected: DetectedBrowser) {
        importing = detected.id
        let result = BrowserImportRunner.run(detected, in: context)
        importing = nil
        if let error = result.error { resultMessage = error; return }
        resultMessage = "Importados \(result.added) marcadores de \(detected.displayName). Organizando con IA…"
    }
}
