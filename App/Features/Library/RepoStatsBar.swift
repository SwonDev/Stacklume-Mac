import SwiftUI
import StacklumeCore
import StacklumeDesignSystem

/// Barra de estadísticas en vivo de un repositorio de GitHub: estrellas, forks y
/// lenguaje. Se muestra en el detalle cuando `Bookmark.repoInfo` está presente.
///
/// El color del punto de lenguaje delega en `RepoLanguageColor` (definido en
/// `DiscoverWidgetSupport.swift`), el helper canónico del Mac para esta paleta.
/// La lógica de colores NO se duplica aquí.
struct RepoStatsBar: View {
    @Environment(\.themePalette) private var palette
    let repo: RepoInfo

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Label(repo.starsText, systemImage: "star.fill")
                .readableTint(palette.accent, palette: palette, on: [palette.background, palette.surface, palette.popover])
            Label(repo.forksText, systemImage: "arrow.triangle.branch")
                .foregroundStyle(palette.textSecondary)
            if let language = repo.language, !language.isEmpty {
                HStack(spacing: 5) {
                    Circle()
                        .fill(RepoLanguageColor.color(for: language))
                        .frame(width: 9, height: 9)
                    Text(language)
                        .foregroundStyle(palette.textSecondary)
                }
            }
        }
        .stacklumeFont(.caption.weight(.semibold))
        .stacklumeLineLimit(1)
    }
}
