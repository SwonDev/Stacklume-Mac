import SwiftUI
import StacklumeCore
import StacklumeDesignSystem

// MARK: - Modelo

/// Una historia de la comunidad técnica Lobsters (lobste.rs). Complementa a Hacker
/// News con un foco más técnico y etiquetado por temas.
struct LobsterStory: Identifiable, Hashable {
    var id: String { shortID }
    let shortID: String
    let title: String
    let url: String            // vacío en posts de solo texto
    let score: Int
    let commentCount: Int
    let commentsURL: String
    let tags: [String]
    let author: String

    /// Enlace a abrir: el artículo enlazado o, si es un post de texto, el hilo.
    var openURL: String { url.isEmpty ? commentsURL : url }
    /// Preview: favicon del dominio de la historia (cascada de respaldos).
    var imageCandidates: [String] { PreviewImage.favicon(for: openURL, size: 64) }
}

// MARK: - Servicio (API pública lobste.rs, sin auth)

/// Obtiene las historias «hottest» de Lobsters. API abierta JSON, paginable con
/// `?page=N`. Patrón calcado de los servicios de descubrir (caché + TTL).
actor LobstersService {
    static let shared = LobstersService()

    private var cache: [LobsterStory] = []
    private var lastFetch: Date?
    private let ttl: TimeInterval = 60 * 15   // 15 min

    func hottest(limit: Int = 25) async -> [LobsterStory] {
        if let lastFetch, Date().timeIntervalSince(lastFetch) < ttl, !cache.isEmpty {
            return Array(cache.prefix(limit))
        }
        let result = await fetch(page: 1)
        if !result.isEmpty { cache = result; lastFetch = Date() }
        return Array((cache.isEmpty ? result : cache).prefix(limit))
    }

    /// Página para la vista ampliada (scroll infinito). `page` empieza en 1.
    func page(_ page: Int) async -> [LobsterStory] {
        await fetch(page: max(page, 1))
    }

    private func fetch(page: Int) async -> [LobsterStory] {
        guard var components = URLComponents(string: "https://lobste.rs/hottest.json") else { return [] }
        if page > 1 { components.queryItems = [URLQueryItem(name: "page", value: "\(page)")] }
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12
        guard let result = try? await ExternalHTTPClient.shared.data(
            for: request,
            maximumBytes: 4 * 1_024 * 1_024,
            allowedMIMEPrefixes: ["application/json"]
        ),
        let items = try? JSONDecoder().decode([LobstersAPIStory].self, from: result.data) else {
            return []
        }
        return items.map { item in
            LobsterStory(
                shortID: item.short_id,
                title: item.title,
                url: item.url ?? "",
                score: item.score ?? 0,
                commentCount: item.comment_count ?? 0,
                commentsURL: item.comments_url ?? "https://lobste.rs/s/\(item.short_id)",
                tags: item.tags ?? [],
                author: item.submitter_user?.value ?? "")
        }
    }
}

private struct LobstersAPIStory: Decodable {
    let short_id: String
    let title: String
    let url: String?
    let score: Int?
    let comment_count: Int?
    let comments_url: String?
    let tags: [String]?
    let submitter_user: SubmitterUser?

    /// `submitter_user` es un string (API actual) o un objeto `{username}` (API
    /// antigua). Se decodifica de forma flexible para no romper en ninguno de los dos.
    enum SubmitterUser: Decodable {
        case name(String)
        var value: String { if case .name(let s) = self { return s }; return "" }
        init(from decoder: Decoder) throws {
            if let s = try? decoder.singleValueContainer().decode(String.self) {
                self = .name(s); return
            }
            let obj = try? decoder.container(keyedBy: CodingKeys.self)
            self = .name((try? obj?.decode(String.self, forKey: .username)) ?? "")
        }
        enum CodingKeys: String, CodingKey { case username }
    }
}

// MARK: - Fila

/// Fila de una historia de Lobsters: favicon del sitio, título, votos, comentarios
/// y la etiqueta principal. Clic abre el artículo; clic derecho guarda/copia.
struct LobsterRow: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.openURL) private var openURL
    let story: LobsterStory
    var expanded = false

    /// Rojo corporativo de Lobsters.
    private let lobstersRed = Color(hex: "#AC130D")

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            SecureRemoteImage(candidates: story.imageCandidates) {
                Image(systemName: "tortoise.fill")
                    .font(.caption2).foregroundStyle(lobstersRed)
            }
            .frame(width: expanded ? 40 : 28, height: expanded ? 40 : 28)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(story.title)
                    .stacklumeFont(.caption.weight(.medium))
                    .foregroundStyle(palette.textPrimary)
                    .stacklumeLineLimit(expanded ? 4 : 2)
                HStack(spacing: 10) {
                    Label("\(story.score)", systemImage: "arrowtriangle.up.fill")
                        .foregroundStyle(lobstersRed)
                        .accessibilityLabel("\(story.score) votos")
                    Label("\(story.commentCount)", systemImage: "bubble.left.fill")
                        .foregroundStyle(palette.textSecondary)
                        .accessibilityLabel("\(story.commentCount) comentarios")
                    if let tag = story.tags.first {
                        Text(tag)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(palette.textSecondary.opacity(0.14), in: Capsule())
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                .stacklumeFont(.caption2)
                .stacklumeLineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .discoverRow(url: story.openURL, title: story.title) {
            if let url = StacklumeAutomationPolicy.openableStoredURL(story.openURL) { openURL(url) }
        }
    }
}

// MARK: - Widget compacto

struct LobstersWidgetContent: View {
    var size: WidgetSize = .large
    @State private var stories: [LobsterStory] = []
    @State private var loading = true

    private var limit: Int {
        switch size {
        case .extraLarge: 8
        case .large: 6
        case .medium, .wide: 4
        default: 3
        }
    }

    var body: some View {
        Group {
            if stories.isEmpty {
                DiscoverPlaceholder(loading: loading)
            } else {
                DiscoverList(items: stories, limit: limit, spacing: 8) { LobsterRow(story: $0) }
            }
        }
        .task { await load() }
    }

    private func load() async {
        let result = await LobstersService.shared.hottest(limit: 30)
        await MainActor.run { stories = result; loading = false }
    }
}
