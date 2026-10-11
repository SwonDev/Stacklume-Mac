import SwiftUI
import StacklumeCore
import StacklumeDesignSystem
import StacklumeMetadata

/// Fila de un repo en tendencia (reutilizada en el widget compacto y en la vista
/// ampliada). Clic abre el repo; clic derecho lo guarda/copia.
struct TrendingRepoRow: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.openURL) private var openURL
    let repo: TrendingRepo
    var expanded = false

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            SecureRemoteImage(candidates: [repo.avatarURL]) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.caption2).foregroundStyle(palette.textSecondary)
            }
            .frame(width: 24, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(repo.fullName)
                    .stacklumeFont(.caption.weight(.semibold))
                    .foregroundStyle(palette.textPrimary)
                    .stacklumeLineLimit(1)
                if expanded, !repo.description.isEmpty {
                    Text(repo.description)
                        .stacklumeFont(.caption2)
                        .foregroundStyle(palette.textSecondary)
                        .stacklumeLineLimit(2)
                }
                HStack(spacing: 8) {
                    Label(repo.starsText, systemImage: "star.fill")
                        .foregroundStyle(palette.readableForeground(Color(hex: "#FBBF24"), on: palette.surface))
                        .accessibilityLabel("\(repo.starsText) estrellas")
                    if let lang = repo.language, !lang.isEmpty {
                        HStack(spacing: 3) {
                            Circle().fill(RepoLanguageColor.color(for: lang)).frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            Text(lang).foregroundStyle(palette.textSecondary)
                        }
                    }
                }
                .stacklumeFont(.caption2)
                .stacklumeLineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .discoverRow(url: repo.url, title: repo.fullName, imageURL: repo.avatarURL) {
            if let url = StacklumeAutomationPolicy.openableStoredURL(repo.url) { openURL(url) }
        }
    }
}

/// Contenido del widget «GitHub Trending»: repos en tendencia esta semana (API
/// oficial de búsqueda de GitHub). Se adapta al tamaño del widget.
struct GitHubTrendingWidgetContent: View {
    var size: WidgetSize = .large

    @State private var repos: [TrendingRepo] = []
    @State private var loading = true

    private var limit: Int {
        switch size {
        case .extraLarge: 8
        case .large: 5
        case .medium, .wide: 4
        default: 3
        }
    }

    var body: some View {
        Group {
            if repos.isEmpty {
                DiscoverPlaceholder(loading: loading)
            } else {
                DiscoverList(items: repos, limit: limit) { TrendingRepoRow(repo: $0) }
            }
        }
        .task { await load() }
    }

    private func load() async {
        let result = await GitHubTrendingService.shared.trending(since: GitHubTrendingDates.sinceLastWeek, limit: 50)
        await MainActor.run {
            repos = result
            loading = false
        }
    }
}

/// Fecha umbral (yyyy-MM-dd) de "creado en los últimos 7 días" para la paginación
/// de la vista ampliada de GitHub Trending.
enum GitHubTrendingDates {
    /// Formateador reutilizado (crear un DateFormatter es costoso).
    private static let isoDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static var sinceLastWeek: String {
        let since = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return isoDayFormatter.string(from: since)
    }
}
