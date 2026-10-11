import SwiftUI
import SwiftData
import AppKit
import NaturalLanguage
import StacklumeCore
import StacklumeDesignSystem
import StacklumeMetadata
import StacklumePersistence

/// Caché en memoria (por sesión) de traducciones de descripciones de «Descubrir»,
/// para no volver a invocar a la IA local sobre el mismo texto al reabrir un ítem.
/// Aislada al `MainActor` (concurrencia estricta de Swift 6).
@MainActor
private final class DiscoverTranslationCache {
    static let shared = DiscoverTranslationCache()
    private var store: [String: String] = [:]
    func get(_ key: String) -> String? { store[key] }
    func set(_ key: String, _ value: String) { store[key] = value }
}

/// Panel de DETALLE (columna derecha) de un ítem de «Descubrir»: portada, fuente,
/// título, descripción (metadatos OG obtenidos bajo demanda) y acciones —abrir,
/// guardar en la biblioteca, copiar y compartir—. Hace los feeds navegables sin salir
/// de la app, igual que un enlace de la biblioteca.
struct DiscoverItemDetailView: View {
    let item: DiscoverItem
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(\.themePalette) private var palette

    @State private var description: String?
    @State private var resolvedImage: String?
    @State private var loading = true
    @State private var saved = false
    @State private var translating = false
    /// Captura REAL de la página (WebKit offscreen) usada como portada cuando el sitio no
    /// expone og:image ni una imagen social: así la preview nunca se queda con el favicon solo.
    @State private var snapshotImage: NSImage?
    @State private var capturing = false

    private var host: String {
        URL(string: item.url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? item.url
    }
    /// Portada de ALTA RESOLUCIÓN ya resuelta (OG del sitio). `nil` hasta cargarla o
    /// si el sitio no tiene una buena imagen (entonces se muestra el logo pequeño y
    /// nítido). NUNCA un favicon estirado.
    private var bestImage: String? {
        (resolvedImage?.isEmpty == false) ? resolvedImage : nil
    }
    private var linkURL: URL? { StacklumeAutomationPolicy.openableStoredURL(item.url) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                hero
                sourceBadge
                Text(item.title)
                    .stacklumeFont(.title2.weight(.bold))
                    .foregroundStyle(palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                hostRow
                actionBar
                descriptionSection
                Spacer(minLength: 0)
            }
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WindowBackground())
        .task(id: item.id) { await loadDetails() }
    }

    // MARK: - Secciones

    /// Portada premium: caja de alto fijo con `HeroCoverImage`, que nunca amplía la
    /// imagen por encima de su resolución nativa (fondo desenfocado + centrada y nítida).
    private var hero: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .overlay {
                if let snapshotImage {
                    Image(nsImage: snapshotImage).resizable().scaledToFill()
                } else {
                    HeroCoverImage(candidates: heroCandidates, fallbackSymbol: item.sourceIcon)
                    if capturing {
                        ProgressView().controlSize(.small).tint(palette.accent)
                    }
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.border.opacity(0.5), lineWidth: 0.5)
            )
            .id(item.id)
    }

    /// Candidatos de portada por calidad: imagen OG de alta resolución ya resuelta →
    /// logo del sitio nítido (favicon 256 px) como respaldo.
    private var heroCandidates: [String] {
        var c: [String] = []
        if let r = resolvedImage, !r.isEmpty { c.append(r) }
        c += PreviewImage.favicon(for: item.url, size: 256)
        return c
    }

    private var sourceBadge: some View {
        Label(item.sourceName, systemImage: item.sourceIcon)
            .stacklumeFont(.caption.weight(.semibold))
            .readableTint(palette.accent, palette: palette, on: [palette.background, palette.surface],
                          overlay: palette.accent.opacity(0.14))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(palette.accent.opacity(0.14),
                        in: Capsule())
    }

    private var hostRow: some View {
        Label(host, systemImage: "globe")
            .stacklumeFont(.callout)
            .foregroundStyle(palette.textSecondary)
            .stacklumeLineLimit(1)
    }

    private var actionBar: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Button {
                if let linkURL { openURL(linkURL) }
            } label: {
                Label("Abrir original", systemImage: "arrow.up.right.square")
                    .stacklumeFont(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .stacklumeButton()
            .disabled(linkURL == nil)

            HStack(spacing: DesignSystem.Spacing.sm) {
                    Button {
                        let ok = DiscoverWidget.save(url: item.url, title: item.title,
                                                     imageURL: bestImage, in: context)
                        withAnimation(.snappy) { saved = saved || ok }
                    } label: {
                        Label(saved ? "Guardado" : "Guardar",
                              systemImage: saved ? "checkmark.circle.fill" : "bookmark")
                            .stacklumeFont(.callout.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .stacklumeButton(prominent: false)
                    .disabled(saved)

                    if let linkURL {
                        ShareLink(item: linkURL) {
                            Image(systemName: "square.and.arrow.up")
                                .scaledFont(14, weight: .semibold, scalesWithText: false)
                                .foregroundStyle(palette.textPrimary)
                                .frame(width: 36, height: 30)
                        }
                        .stacklumeButton(prominent: false, compact: true)
                        .themedHelp("Compartir")
                        .accessibilityLabel("Compartir")
                    }
                    Button {
                        DiscoverWidget.copyToPasteboard(item.url)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .scaledFont(14, weight: .semibold, scalesWithText: false)
                            .foregroundStyle(palette.textPrimary)
                            .frame(width: 36, height: 30)
                    }
                    .stacklumeButton(prominent: false, compact: true)
                    .themedHelp("Copiar enlace")
                    .accessibilityLabel("Copiar enlace")
            }
            .stacklumeGlassContainer(spacing: DesignSystem.Spacing.sm)
        }
    }

    @ViewBuilder
    private var descriptionSection: some View {
        if loading {
            HStack(spacing: DesignSystem.Spacing.xs) {
                ProgressView().controlSize(.small)
                Text("Cargando descripción…")
                    .stacklumeFont(.callout).foregroundStyle(palette.textSecondary)
            }
        } else if let description, !description.isEmpty {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                if translating {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("Enriqueciendo con IA…")
                            .stacklumeFont(.caption.weight(.medium))
                            .readableTint(palette.accent, palette: palette, on: [palette.background, palette.surface])
                    }
                }
                Text(description)
                    .stacklumeFont(.body)
                    .foregroundStyle(palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if translating {
            HStack(spacing: DesignSystem.Spacing.xs) {
                ProgressView().controlSize(.small)
                Text("Enriqueciendo con IA…")
                    .stacklumeFont(.callout)
                    .readableTint(palette.accent, palette: palette, on: [palette.background, palette.surface])
            }
        } else {
            Text("Sin descripción. Ábrelo para ver el contenido completo, o guárdalo para enriquecerlo con IA.")
                .stacklumeFont(.callout)
                .foregroundStyle(palette.textSecondary)
        }
    }

    // MARK: - Carga

    /// Bookmark de la biblioteca que corresponde a esta URL (misma clave canónica), o nil.
    /// Permite reutilizar sus datos ya enriquecidos en vez de volver a pedirlos por red.
    private func existingBookmark() -> Bookmark? {
        let key = CanonicalURL.key(item.url)
        guard !key.isEmpty else { return nil }
        let all = (try? context.fetch(FetchDescriptor<Bookmark>(predicate: #Predicate { $0.deletedAt == nil }))) ?? []
        return all.first { CanonicalURL.key($0.url) == key }
    }

    /// «Social preview» oficial de un repo de GitHub (tarjeta con nombre, descripción, ⭐ y
    /// lenguaje), como portada cuando GitHub no expone og:image en el <head>. nil si la URL
    /// no es un repo `github.com/owner/repo`.
    static func githubSocialImage(for urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let host = url.host()?.lowercased().replacingOccurrences(of: "www.", with: ""),
              host == "github.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let reserved: Set<String> = ["features", "about", "pricing", "marketplace", "topics",
                                     "trending", "sponsors", "settings", "explore", "notifications",
                                     "new", "orgs", "apps", "login", "join", "search", "collections"]
        guard !reserved.contains(parts[0].lowercased()) else { return nil }
        // El primer segmento es un hash de caché; GitHub acepta cualquiera y sirve la imagen actual.
        return "https://opengraph.githubassets.com/1/\(parts[0])/\(parts[1])"
    }

    /// Si no hay portada OG/social, captura la página REAL con WebKit (offscreen) y la usa de
    /// hero, para que la preview no se quede solo con el favicon. Reutiliza la cola serial de
    /// `PageSnapshotService` (no satura con muchos WebViews a la vez).
    private func captureSnapshotIfNeeded() async {
        guard resolvedImage == nil, snapshotImage == nil,
              StacklumeAutomationPolicy.openableStoredURL(item.url) != nil else { return }
        capturing = true
        let img = await PageSnapshotService.snapshot(of: item.url)
        capturing = false
        guard !Task.isCancelled, let img else { return }
        snapshotImage = img
    }

    private func loadDetails() async {
        loading = true
        saved = false
        translating = false
        snapshotImage = nil
        // Si el enlace YA está en la biblioteca, reutiliza sus datos ENRIQUECIDOS (portada,
        // descripción/resumen de IA ya traducidos) — sin rehacer red ni traducción dos veces.
        if let bm = existingBookmark() {
            let img = (bm.imageURL?.isEmpty == false) ? bm.imageURL : item.imageURL
            let valid = (img?.isEmpty == false && !PreviewImage.isFavicon(img!)) ? img : nil
            resolvedImage = valid ?? Self.githubSocialImage(for: item.url)
            let d = (bm.details?.isEmpty == false) ? bm.details : bm.summary
            description = (d?.isEmpty == false) ? d : nil
            saved = true
            loading = false
            await captureSnapshotIfNeeded()
            return
        }
        let meta = await MacMetadataService().fetchMetadata(for: item.url)
        // Portada de ALTA RESOLUCIÓN: imagen OG de los metadatos → OG extraída del
        // <head> → imagen del propio ítem SOLO si no es un favicon. Nunca un favicon
        // diminuto estirado (se ve pixelado).
        var hero: String?
        if let m = meta.imageURL, !m.isEmpty, !PreviewImage.isFavicon(m) { hero = m }
        if hero == nil, let og = await OpenGraphImageService.shared.image(for: item.url),
           !PreviewImage.isFavicon(og) { hero = og }
        if hero == nil, let i = item.imageURL, !i.isEmpty, !PreviewImage.isFavicon(i) { hero = i }
        // GitHub no expone og:image en el <head>: usa su «social preview» oficial (tarjeta
        // generada con nombre, descripción, ⭐ y lenguaje del repo) en vez del favicon.
        if hero == nil { hero = Self.githubSocialImage(for: item.url) }
        resolvedImage = hero
        let original = (meta.details ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        description = original.isEmpty ? nil : original
        loading = false
        await captureSnapshotIfNeeded()

        // ENRIQUECIDO con IA local (Liquid): genera una descripción RICA «de qué va» el enlace
        // —el MISMO motor que al guardarlo (UnifiedAIService.enrich)—, no solo la og:description
        // cruda, para que la preview se vea completa aunque el enlace no esté guardado. Si la IA
        // no está disponible, cae a traducir la descripción de los metadatos. Cacheado por URL.
        let lang = AppSettingsStore.current(in: context).language.rawValue
        let enrichKey = "enrich:" + item.url
        if let cached = DiscoverTranslationCache.shared.get(enrichKey) { description = cached; return }
        guard LocalAIRunner.shared.isDownloaded, !LocalAIRunner.shared.isDeactivated else {
            await translateMetaDescription(original, to: lang); return
        }
        translating = true
        guard await LocalAIRunner.shared.ensureReady() != nil, !Task.isCancelled else {
            translating = false; await translateMetaDescription(original, to: lang); return
        }
        let pageContent = await AIBatchEnricher.pageContentExcerpt(for: item.url)
        guard !Task.isCancelled else { translating = false; return }
        let result = try? await UnifiedAIService(provider: "liquid").enrich(
            url: item.url, pageTitle: meta.title, pageDescription: meta.details,
            siteName: meta.siteName, existingCategories: [], language: lang, pageContent: pageContent)
        guard !Task.isCancelled else { translating = false; return }
        if let s = result?.summary.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            description = s
            DiscoverTranslationCache.shared.set(enrichKey, s)
        } else {
            await translateMetaDescription(original, to: lang)
        }
        translating = false
    }

    /// Traduce la descripción de los metadatos al idioma activo si hace falta (fallback cuando
    /// no se puede enriquecer con IA). El original se muestra mientras tanto.
    private func translateMetaDescription(_ original: String, to lang: String) async {
        guard !original.isEmpty, needsTranslation(original, to: lang) else { return }
        if let cached = DiscoverTranslationCache.shared.get(original) { description = cached; return }
        guard LocalAIRunner.shared.isDownloaded, !LocalAIRunner.shared.isDeactivated else { return }
        translating = true
        let translated = await LiquidAIService.translate(original, to: lang)
        translating = false
        guard !Task.isCancelled, let t = translated, !t.isEmpty else { return }
        DiscoverTranslationCache.shared.set(original, t)
        description = t
    }

    /// Detecta el idioma dominante (on-device, `NaturalLanguage`) y decide si hay que
    /// traducir. Solo traduce cuando hay confianza de que el texto NO está en el idioma
    /// destino (evita retraducir texto que ya está en español/inglés).
    private func needsTranslation(_ text: String, to lang: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let target: NLLanguage = (lang == "en") ? .english : .spanish
        guard let detected = recognizer.dominantLanguage, detected != target else { return false }
        // Solo traduce con CONFIANZA suficiente: el reconocedor clasifica texto corto/técnico con
        // poca certeza y disparaba traducciones innecesarias de contenido ya en el idioma destino.
        let confidence = recognizer.languageHypotheses(withMaximum: 3)[detected] ?? 0
        return confidence >= 0.55
    }
}
