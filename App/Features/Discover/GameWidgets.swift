import SwiftUI
import SwiftData
import StacklumeCore
import StacklumeDesignSystem
import StacklumeMetadata

// MARK: - Juegos gratis (GamerPower)

/// Fila de un juego gratis. Clic abre la página para reclamarlo; clic derecho lo
/// guarda/copia.
struct FreeGameRow: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.openURL) private var openURL
    let game: FreeGame
    var expanded = false

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            SecureRemoteImage(candidates: [game.thumbnail]) {
                Image(systemName: "gift")
                    .font(.caption2).foregroundStyle(palette.textSecondary)
            }
            .frame(width: expanded ? 72 : 56, height: expanded ? 54 : 42)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title)
                    .stacklumeFont(.caption.weight(.semibold))
                    .foregroundStyle(palette.textPrimary)
                    .stacklumeLineLimit(expanded ? 2 : 1)
                HStack(spacing: 6) {
                    Text("GRATIS")
                        .stacklumeFont(.caption2.weight(.bold))
                        .foregroundStyle(palette.readableForeground(Color(hex: "#22C55E"), on: palette.surface))
                        .accessibilityLabel(game.worth.map { "Gratis, antes \($0)" } ?? "Gratis")
                    if let worth = game.worth {
                        Text(worth)
                            .stacklumeFont(.caption2)
                            .strikethrough()
                            .foregroundStyle(palette.textSecondary)
                            .accessibilityHidden(true)
                    }
                }
                Text(game.platforms)
                    .stacklumeFont(.caption2)
                    .foregroundStyle(palette.textSecondary)
                    .stacklumeLineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .discoverRow(url: game.url, title: game.title, imageURL: game.thumbnail) {
            if let url = StacklumeAutomationPolicy.openableStoredURL(game.url) { openURL(url) }
        }
    }
}

/// Widget compacto de juegos gratis.
struct FreeGamesWidgetContent: View {
    var size: WidgetSize = .large
    @State private var games: [FreeGame] = []
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
            if games.isEmpty {
                DiscoverPlaceholder(loading: loading)
            } else {
                DiscoverList(items: games, limit: limit) { FreeGameRow(game: $0) }
            }
        }
        .task { await load() }
    }

    private func load() async {
        let result = await FreeGamesService.shared.giveaways(limit: 50)
        await MainActor.run { games = result; loading = false }
    }
}

// MARK: - Steam: destacados (top ventas / novedades / ofertas)

/// Fila de un juego destacado de Steam. Clic abre la ficha; clic derecho guarda/copia.
struct SteamSpotlightRow: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.openURL) private var openURL
    let item: SteamSpotlightItem
    var expanded = false

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            SecureRemoteImage(candidates: [item.image]) {
                Image(systemName: "gamecontroller")
                    .font(.caption2).foregroundStyle(palette.textSecondary)
            }
            .frame(width: expanded ? 72 : 56, height: expanded ? 34 : 26)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(item.name)
                .stacklumeFont(.caption.weight(.medium))
                .foregroundStyle(palette.textPrimary)
                .stacklumeLineLimit(expanded ? 2 : 1)
            Spacer(minLength: 0)
            if item.discountPercent > 0 {
                Text("-\(item.discountPercent)%")
                    .stacklumeFont(.caption2.weight(.bold))
                    .foregroundStyle(palette.readableForeground(Color(hex: "#22C55E"), on: palette.surface))
                    .accessibilityHidden(true)
            }
            Text(item.priceText)
                .stacklumeFont(.caption2.weight(.semibold))
                .foregroundStyle(item.isFree ? palette.readableForeground(Color(hex: "#22C55E"), on: palette.surface) : palette.textSecondary)
                .accessibilityLabel(item.discountPercent > 0
                    ? "Precio: \(item.priceText), \(item.discountPercent)% de descuento"
                    : "Precio: \(item.priceText)")
        }
        .discoverRow(url: item.url, title: item.name, imageURL: item.image) {
            if let url = StacklumeAutomationPolicy.openableStoredURL(item.url) { openURL(url) }
        }
    }
}

/// Selector de modo (top ventas / novedades / ofertas) reutilizado en el widget
/// compacto y en la vista ampliada. Persiste la elección en `widget.configText`.
struct SteamSpotlightControls: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.modelContext) private var context
    @Bindable var widget: DashboardWidget

    private var kind: SteamSpotlightKind {
        SteamSpotlightKind(rawValue: widget.configText ?? "") ?? .topSellers
    }

    var body: some View {
        Menu {
            ForEach(SteamSpotlightKind.allCases) { option in
                Button {
                    widget.configText = option.rawValue
                    context.saveLogging()
                } label: {
                    Label(option.displayName, systemImage: kind == option ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "crown.fill").scaledFont(9, weight: .bold, scalesWithText: false)
                Text(kind.displayName).stacklumeFont(.caption2.weight(.semibold))
                Image(systemName: "chevron.down").scaledFont(8, weight: .bold, scalesWithText: false)
            }
            .readableTint(palette.accent, palette: palette, on: [palette.surface], overlay: palette.accent.opacity(0.12))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(palette.accent.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Widget compacto de Steam: destacados.
struct SteamSpotlightWidgetContent: View {
    @Bindable var widget: DashboardWidget
    var size: WidgetSize = .large

    @State private var items: [SteamSpotlightItem] = []
    @State private var loading = true

    private var kind: SteamSpotlightKind {
        SteamSpotlightKind(rawValue: widget.configText ?? "") ?? .topSellers
    }

    private var limit: Int {
        switch size {
        case .extraLarge: 7
        case .large: 5
        case .medium, .wide: 3
        default: 2
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SteamSpotlightControls(widget: widget)
            if items.isEmpty {
                DiscoverPlaceholder(loading: loading)
            } else {
                DiscoverList(items: items, limit: limit, spacing: 8) { SteamSpotlightRow(item: $0) }
            }
        }
        .task(id: kind) { await load() }
    }

    private func load() async {
        loading = true
        let result = await SteamSpotlightService.shared.items(kind: kind, limit: 50)
        await MainActor.run { items = result; loading = false }
    }
}
