import SwiftUI
import StacklumeCore
import StacklumeDesignSystem
import StacklumeMetadata

// MARK: - MAGI//ARCHIVE (repos curados de tom-doerr/repo_posts)

/// Fila de un repo curado de MAGI//ARCHIVE. Clic abre el repo en GitHub; clic
/// derecho lo guarda/copia.
struct RepoPostRow: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.openURL) private var openURL
    let post: RepoPost
    var expanded = false

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            SecureRemoteImage(candidates: [post.thumbnail, PreviewImage.githubAvatar(forRepoURL: post.repoURL)]) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.caption2).foregroundStyle(palette.textSecondary)
            }
            .frame(width: expanded ? 64 : 38, height: expanded ? 44 : 30)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(post.name)
                    .stacklumeFont(.caption.weight(.semibold))
                    .foregroundStyle(palette.textPrimary)
                    .stacklumeLineLimit(1)
                if !post.description.isEmpty {
                    Text(post.description)
                        .stacklumeFont(.caption2)
                        .foregroundStyle(palette.textSecondary)
                        .stacklumeLineLimit(expanded ? 4 : 2)
                }
            }
            Spacer(minLength: 0)
        }
        .discoverRow(url: post.repoURL, title: post.name, imageURL: post.thumbnail) {
            if let url = StacklumeAutomationPolicy.openableStoredURL(post.repoURL) { openURL(url) }
        }
    }
}

/// Widget compacto de MAGI//ARCHIVE.
struct RepoPostsWidgetContent: View {
    var size: WidgetSize = .large
    @State private var posts: [RepoPost] = []
    @State private var loading = true

    private var limit: Int {
        switch size {
        case .extraLarge: 6
        case .large: 4
        case .medium, .wide: 3
        default: 2
        }
    }

    var body: some View {
        Group {
            if posts.isEmpty {
                DiscoverPlaceholder(loading: loading)
            } else {
                DiscoverList(items: posts, limit: limit) { RepoPostRow(post: $0) }
            }
        }
        .task { await load() }
    }

    private func load() async {
        let result = await RepoPostsService.shared.latest(limit: 50)
        await MainActor.run { posts = result; loading = false }
    }
}

// MARK: - Hacker News

/// Fila de una historia de Hacker News. `rank` muestra la posición (compacto); si
/// es nil muestra un icono. Clic abre el artículo; clic derecho lo guarda/copia.
struct HNStoryRow: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.openURL) private var openURL
    let story: HNStory
    var rank: Int? = nil
    var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            if let rank {
                Text("\(rank)")
                    .stacklumeFont(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(palette.readableForeground(Color(hex: "#FF6600"), on: palette.surface))
                    .frame(width: 18, alignment: .trailing)
                    .accessibilityLabel("Posición \(rank)")
            } else {
                Image(systemName: "newspaper.fill")
                    .font(.caption2)
                    .foregroundStyle(Color(hex: "#FF6600"))
                    .frame(width: 18)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(story.title)
                    .stacklumeFont(.caption.weight(.medium))
                    .foregroundStyle(palette.textPrimary)
                    .stacklumeLineLimit(expanded ? 4 : 2)
                HStack(spacing: 10) {
                    Label("\(story.score)", systemImage: "arrowtriangle.up.fill")
                        .foregroundStyle(palette.readableForeground(Color(hex: "#FF6600"), on: palette.surface))
                        .accessibilityLabel("\(story.score) votos")
                    Label("\(story.comments)", systemImage: "bubble.left.fill")
                        .foregroundStyle(palette.textSecondary)
                        .accessibilityLabel("\(story.comments) comentarios")
                    if expanded, !story.author.isEmpty {
                        Text(story.author).foregroundStyle(palette.textSecondary)
                    }
                }
                .stacklumeFont(.caption2)
            }
            Spacer(minLength: 0)
        }
        .discoverRow(url: story.openURL, title: story.title) {
            if let url = StacklumeAutomationPolicy.openableStoredURL(story.openURL) { openURL(url) }
        }
    }
}

/// Widget compacto de Hacker News.
struct HackerNewsWidgetContent: View {
    var size: WidgetSize = .large
    @State private var stories: [HNStory] = []
    @State private var loading = true

    private var limit: Int {
        switch size {
        case .extraLarge: 9
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
                DiscoverList(items: ranked, limit: limit, spacing: 8) { item in
                    HNStoryRow(story: item.story, rank: item.rank)
                }
            }
        }
        .task { await load() }
    }

    private var ranked: [RankedStory] {
        stories.enumerated().map { RankedStory(rank: $0.offset + 1, story: $0.element) }
    }

    private struct RankedStory: Identifiable {
        let rank: Int
        let story: HNStory
        var id: Int { story.id }
    }

    private func load() async {
        let result = await HackerNewsService.shared.topStories(limit: 30)
        await MainActor.run { stories = result; loading = false }
    }
}

// MARK: - Artículos de dev.to

/// Fila de un artículo de dev.to. Clic abre el artículo; clic derecho lo guarda/copia.
struct DevArticleRow: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.openURL) private var openURL
    let article: DevArticle
    var expanded = false

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            SecureRemoteImage(candidates: [article.coverImage] + PreviewImage.favicon(for: article.url, size: 80).map { Optional($0) }) {
                Image(systemName: "doc.richtext")
                    .font(.caption2).foregroundStyle(palette.textSecondary)
            }
            .frame(width: expanded ? 64 : 40, height: expanded ? 44 : 30)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(article.title)
                    .stacklumeFont(.caption.weight(.semibold))
                    .foregroundStyle(palette.textPrimary)
                    .stacklumeLineLimit(expanded ? 3 : 2)
                HStack(spacing: 10) {
                    Label("\(article.reactions)", systemImage: "heart.fill")
                        .foregroundStyle(palette.readableForeground(Color(hex: "#EF4444"), on: palette.surface))
                        .accessibilityLabel("\(article.reactions) reacciones")
                    Label("\(article.comments)", systemImage: "bubble.left.fill")
                        .foregroundStyle(palette.textSecondary)
                        .accessibilityLabel("\(article.comments) comentarios")
                    Text("\(article.readingMinutes) min")
                        .foregroundStyle(palette.textSecondary)
                        .accessibilityLabel("\(article.readingMinutes) minutos de lectura")
                }
                .stacklumeFont(.caption2)
                .stacklumeLineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .discoverRow(url: article.url, title: article.title, imageURL: article.coverImage) {
            if let url = StacklumeAutomationPolicy.openableStoredURL(article.url) { openURL(url) }
        }
    }
}

/// Widget compacto de dev.to.
struct DevArticlesWidgetContent: View {
    var size: WidgetSize = .large
    @State private var articles: [DevArticle] = []
    @State private var loading = true

    private var limit: Int {
        switch size {
        case .extraLarge: 7
        case .large: 5
        case .medium, .wide: 3
        default: 2
        }
    }

    var body: some View {
        Group {
            if articles.isEmpty {
                DiscoverPlaceholder(loading: loading)
            } else {
                DiscoverList(items: articles, limit: limit) { DevArticleRow(article: $0) }
            }
        }
        .task { await load() }
    }

    private func load() async {
        let result = await DevArticlesService.shared.articles(limit: 50)
        await MainActor.run { articles = result; loading = false }
    }
}
