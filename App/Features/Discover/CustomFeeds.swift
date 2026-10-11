import SwiftUI
import StacklumeCore
import StacklumeDesignSystem

// MARK: - Modelo de feed del usuario

/// Un feed RSS/Atom que el usuario ha añadido a mano a la sección «Descubrir». Se
/// serializa en `@AppStorage` como JSON, igual que [[SavedSearch]] (sin tocar el
/// esquema SwiftData compartido, que es de solo lectura).
struct CustomFeed: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: String

    /// Host del feed (para el subtítulo de la tarjeta).
    var host: String { URL(string: url)?.host ?? url }
}

/// Almacén ligero de feeds del usuario respaldado por un `String` JSON de
/// `@AppStorage` (el overload de `Data` no persiste de forma fiable — ver
/// [[SavedSearch]]).
enum CustomFeedStore {
    /// Clave de `@AppStorage` compartida por «Descubrir» y el gestor de feeds.
    static let storageKey = "stacklume.discover.customFeeds"

    static func decode(_ json: String) -> [CustomFeed] {
        guard let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([CustomFeed].self, from: data) else { return [] }
        return list
    }

    static func encode(_ list: [CustomFeed]) -> String {
        guard let data = try? JSONEncoder().encode(list) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Normaliza una URL escrita por el usuario (añade `https://` si falta) y valida
    /// que sea http(s). Devuelve `nil` si no es válida.
    static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://"), !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        guard var components = URLComponents(string: text) else { return nil }
        components.scheme = "https"
        guard let url = components.url,
              StacklumeAutomationPolicy.allowsAutomaticNetworkURL(url) else { return nil }
        return url.absoluteString
    }

    /// Nombre por defecto a partir del host (cuando el usuario no escribe título).
    static func defaultTitle(for url: String) -> String {
        guard let host = URL(string: url)?.host else { return "Feed" }
        let trimmed = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return trimmed
    }
}

// MARK: - Sugerencias curadas

/// Feed sugerido que el usuario puede añadir con un toque. Buena cosecha de fuentes
/// tech/Apple/open source con RSS público y estable.
struct SuggestedFeed: Identifiable, Hashable {
    let title: String
    let url: String
    let note: String
    var id: String { url }
}

enum SuggestedFeeds {
    static let all: [SuggestedFeed] = [
        .init(title: "The Verge", url: "https://www.theverge.com/rss/index.xml", note: "Tecnología y cultura"),
        .init(title: "Ars Technica", url: "https://feeds.arstechnica.com/arstechnica/index", note: "Tecnología en profundidad"),
        .init(title: "MacRumors", url: "https://feeds.macrumors.com/MacRumors-All", note: "Noticias de Apple"),
        .init(title: "9to5Mac", url: "https://9to5mac.com/feed/", note: "Apple, Mac e iPhone"),
        .init(title: "It's FOSS", url: "https://news.itsfoss.com/rss/", note: "Linux y open source"),
        .init(title: "OMG! Ubuntu", url: "https://www.omgubuntu.co.uk/feed", note: "Linux y Ubuntu"),
        .init(title: "Console.dev", url: "https://console.dev/rss.xml", note: "Herramientas para desarrolladores"),
        .init(title: "The Changelog", url: "https://changelog.com/feed", note: "Open source y software"),
        .init(title: "Smashing Magazine", url: "https://www.smashingmagazine.com/feed/", note: "Diseño y front-end"),
        .init(title: "Hacker News (portada)", url: "https://hnrss.org/frontpage", note: "Lo más alto de HN vía RSS"),
        .init(title: "GitHub Blog", url: "https://github.blog/feed/", note: "Novedades de GitHub"),
        .init(title: "Daring Fireball", url: "https://daringfireball.net/feeds/main", note: "Apple, por John Gruber"),
        // Desarrollo: lenguajes, plataformas y comunidad (feeds verificados).
        .init(title: "Swift.org", url: "https://www.swift.org/atom.xml", note: "Swift, blog oficial"),
        .init(title: "Swift by Sundell", url: "https://www.swiftbysundell.com/rss", note: "Swift e iOS, por John Sundell"),
        .init(title: "Android Developers", url: "https://android-developers.googleblog.com/feeds/posts/default", note: "Android, blog oficial de Google"),
        .init(title: "Rust Blog", url: "https://blog.rust-lang.org/feed.xml", note: "El lenguaje Rust, oficial"),
        .init(title: "The Go Blog", url: "https://go.dev/blog/feed.atom", note: "El lenguaje Go, oficial"),
        .init(title: "web.dev", url: "https://web.dev/feed.xml", note: "Web moderna, por Google"),
        .init(title: "CSS-Tricks", url: "https://css-tricks.com/feed/", note: "CSS y front-end"),
        .init(title: "JetBrains", url: "https://blog.jetbrains.com/feed/", note: "IDEs y herramientas dev"),
        .init(title: "Stack Overflow Blog", url: "https://stackoverflow.blog/feed/", note: "Programación y comunidad dev"),
        .init(title: "GitHub Changelog", url: "https://github.blog/changelog/feed/", note: "Novedades y cambios de GitHub"),
        .init(title: "DEV Community", url: "https://dev.to/feed", note: "Comunidad de desarrolladores"),
        .init(title: "Lobsters", url: "https://lobste.rs/rss", note: "Comunidad técnica al estilo HN"),
        .init(title: "Show HN", url: "https://hnrss.org/show", note: "Proyectos nuevos en Hacker News"),
    ]
}

// MARK: - Gestor de feeds (hoja)

/// Hoja para añadir, ver y borrar feeds del usuario, con sugerencias de un toque.
/// Edita directamente la misma clave de `@AppStorage` que lee «Descubrir», así los
/// cambios se reflejan al instante.
struct CustomFeedsManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @AppStorage(CustomFeedStore.storageKey) private var feedsJSON = ""

    @State private var newURL = ""
    @State private var newName = ""
    @State private var errorText: String?
    /// `true` mientras se comprueba que la URL es un feed RSS/Atom válido y alcanzable.
    @State private var validating = false
    /// URL normalizada que NO validó como feed: permite «añadir de todas formas» (falsos negativos).
    @State private var unvalidatedURL: String?

    private var feeds: [CustomFeed] { CustomFeedStore.decode(feedsJSON) }

    /// Sugerencias que aún no se han añadido (por URL).
    private var pendingSuggestions: [SuggestedFeed] {
        let have = Set(feeds.map { $0.url })
        return SuggestedFeeds.all.filter { !have.contains($0.url) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.border.opacity(0.4))
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    addSection
                    if !feeds.isEmpty { yourFeedsSection }
                    if !pendingSuggestions.isEmpty { suggestionsSection }
                }
                .padding(DesignSystem.Spacing.md)
            }
            .scrollIndicators(.hidden)
        }
        .frame(minWidth: 480, minHeight: 540)
        .background(palette.background)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.up.forward").foregroundStyle(palette.accent)
            Text("Tus feeds").stacklumeFont(.headline).foregroundStyle(palette.textPrimary)
            Spacer(minLength: 0)
            Button("Cerrar") { dismiss() }.tint(palette.accent)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
    }

    // MARK: Añadir

    private var addSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Añadir un feed RSS o Atom")
                .stacklumeFont(.caption.weight(.semibold))
                .foregroundStyle(palette.textSecondary)
            TextField("https://ejemplo.com/feed", text: $newURL)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            TextField("Nombre (opcional)", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            if let errorText {
                Text(errorText)
                    .stacklumeFont(.caption2)
                    .foregroundStyle(Color(hex: "#EF4444"))
            }
            HStack(spacing: DesignSystem.Spacing.sm) {
                if validating {
                    ProgressView().controlSize(.small)
                    Text("Comprobando el feed…")
                        .stacklumeFont(.caption2).foregroundStyle(palette.textSecondary)
                }
                Spacer()
                // Tras un fallo de validación: dejar añadirlo igualmente (falso negativo puntual).
                if let unvalidatedURL {
                    Button("Añadir de todas formas") { commit(url: unvalidatedURL) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button {
                    add()
                } label: {
                    Label("Añadir feed", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .disabled(validating || newURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(palette.border.opacity(0.5), lineWidth: 0.5))
    }

    // MARK: Tus feeds

    private var yourFeedsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Añadidos (\(feeds.count))")
                .stacklumeFont(.caption.weight(.semibold))
                .foregroundStyle(palette.textSecondary)
            ForEach(feeds) { feed in
                HStack(spacing: DesignSystem.Spacing.sm) {
                    SecureRemoteImage(candidates: PreviewImage.favicon(for: feed.url, size: 64)) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.caption).foregroundStyle(palette.accent)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(palette.accent.opacity(0.12))
                    }
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(feed.title).stacklumeFont(.subheadline.weight(.medium))
                            .foregroundStyle(palette.textPrimary).stacklumeLineLimit(1)
                        Text(feed.host).stacklumeFont(.caption2)
                            .foregroundStyle(palette.textSecondary).stacklumeLineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button(role: .destructive) {
                        remove(feed)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .themedHelp("Quitar feed")
                    .accessibilityLabel("Quitar feed")
                }
                .padding(.vertical, 4)
                if feed.id != feeds.last?.id {
                    Divider().overlay(palette.border.opacity(0.4))
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(palette.border.opacity(0.5), lineWidth: 0.5))
    }

    // MARK: Sugerencias

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Sugerencias")
                .stacklumeFont(.caption.weight(.semibold))
                .foregroundStyle(palette.textSecondary)
            ForEach(pendingSuggestions) { suggestion in
                Button {
                    addSuggestion(suggestion)
                } label: {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        SecureRemoteImage(candidates: PreviewImage.favicon(for: suggestion.url, size: 64)) {
                            Image(systemName: "globe")
                                .font(.caption).foregroundStyle(palette.textSecondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(palette.textSecondary.opacity(0.12))
                        }
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(suggestion.title).stacklumeFont(.subheadline.weight(.medium))
                                .foregroundStyle(palette.textPrimary).stacklumeLineLimit(1)
                            Text(suggestion.note).stacklumeFont(.caption2)
                                .foregroundStyle(palette.textSecondary).stacklumeLineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(palette.accent)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                if suggestion.id != pendingSuggestions.last?.id {
                    Divider().overlay(palette.border.opacity(0.4))
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(palette.border.opacity(0.5), lineWidth: 0.5))
    }

    // MARK: Acciones

    private func add() {
        errorText = nil
        unvalidatedURL = nil
        guard let url = CustomFeedStore.normalize(newURL) else {
            errorText = "Escribe una dirección válida (https://…)."
            return
        }
        guard !feeds.contains(where: { $0.url == url }) else {
            errorText = "Ese feed ya está añadido."
            return
        }
        // Validación: descarga y parsea el feed antes de guardarlo, para no meter feeds rotos o
        // URLs que no son RSS/Atom (el motivo nº1 de feeds «vacíos» en Descubrir). Si no devuelve
        // artículos, se ofrece añadirlo igualmente (por si es un falso negativo puntual).
        validating = true
        Task { @MainActor in
            let items = await RSSService.shared.items(for: url, limit: 3)
            validating = false
            guard items.count > 0 else {
                errorText = "No se encontró un feed RSS/Atom en esa dirección (o no responde). Comprueba la URL del feed."
                unvalidatedURL = url
                return
            }
            commit(url: url)
        }
    }

    /// Guarda el feed validado (o forzado con «añadir de todas formas»).
    private func commit(url: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let feed = CustomFeed(title: name.isEmpty ? CustomFeedStore.defaultTitle(for: url) : name, url: url)
        save(feeds + [feed])
        newURL = ""; newName = ""; errorText = nil; unvalidatedURL = nil
    }

    private func addSuggestion(_ suggestion: SuggestedFeed) {
        guard !feeds.contains(where: { $0.url == suggestion.url }) else { return }
        save(feeds + [CustomFeed(title: suggestion.title, url: suggestion.url)])
    }

    private func remove(_ feed: CustomFeed) {
        save(feeds.filter { $0.id != feed.id })
    }

    private func save(_ list: [CustomFeed]) {
        withAnimation(.snappy) { feedsJSON = CustomFeedStore.encode(list) }
    }
}
