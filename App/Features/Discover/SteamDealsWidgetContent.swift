import SwiftUI
import SwiftData
import StacklumeCore
import StacklumeDesignSystem
import StacklumeMetadata

/// Configuración del widget de ofertas de Steam (se guarda en `configText`).
struct DealsConfig: Codable {
    var sort: SteamDealSort = .savings
    var onSale: Bool = true

    static func decode(_ raw: String?) -> DealsConfig {
        guard let raw, let data = raw.data(using: .utf8),
              let config = try? JSONDecoder().decode(DealsConfig.self, from: data) else {
            return DealsConfig()
        }
        return config
    }

    var encoded: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Fila de una oferta de Steam. Clic abre la ficha del juego; clic derecho guarda/copia.
struct SteamDealRow: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.openURL) private var openURL
    let deal: SteamDeal
    var expanded = false

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            SecureRemoteImage(candidates: [deal.thumb]) {
                Image(systemName: "gamecontroller")
                    .font(.caption2).foregroundStyle(palette.textSecondary)
            }
            .frame(width: expanded ? 72 : 56, height: expanded ? 34 : 26)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(deal.title)
                    .stacklumeFont(.caption.weight(.medium))
                    .foregroundStyle(palette.textPrimary)
                    .stacklumeLineLimit(expanded ? 2 : 1)
                HStack(spacing: 8) {
                    if let rating = deal.steamRatingPercent {
                        Label("\(rating)%", systemImage: "hand.thumbsup.fill")
                            .foregroundStyle(palette.readableForeground(Color(hex: "#5B8DEF"), on: palette.surface))
                    }
                    if let meta = deal.metacriticScore {
                        Text("MC \(meta)")
                            .foregroundStyle(palette.readableForeground(Color(hex: "#22C55E"), on: palette.surface))
                    }
                }
                .stacklumeFont(.caption2)
                .stacklumeLineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                if deal.savingsPercent > 0 {
                    Text("-\(deal.savingsPercent)%")
                        .stacklumeFont(.caption2.weight(.bold))
                        .foregroundStyle(palette.readableForeground(Color(hex: "#22C55E"), on: palette.surface))
                        .accessibilityHidden(true)
                }
                HStack(spacing: 5) {
                    if deal.savingsPercent > 0 {
                        Text(deal.normalPriceText)
                            .strikethrough()
                            .foregroundStyle(palette.textSecondary)
                            .accessibilityHidden(true)
                    }
                    Text(deal.salePriceText)
                        .fontWeight(.semibold)
                        .foregroundStyle(palette.textPrimary)
                        .accessibilityLabel(deal.savingsPercent > 0
                            ? "Precio: \(deal.salePriceText), antes \(deal.normalPriceText), \(deal.savingsPercent)% de ahorro"
                            : "Precio: \(deal.salePriceText)")
                }
                .stacklumeFont(.caption2)
            }
        }
        .discoverRow(url: deal.storeURL, title: deal.title, imageURL: deal.thumb) {
            if let url = StacklumeAutomationPolicy.openableStoredURL(deal.storeURL) { openURL(url) }
        }
    }
}

/// Menú de orden (descuento/precio/valoración/Metacritic/novedad) + filtro «solo
/// en oferta». Reutilizado en el widget compacto y en la vista ampliada.
struct SteamDealsControls: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.modelContext) private var context
    @Bindable var widget: DashboardWidget

    private var config: DealsConfig { DealsConfig.decode(widget.configText) }

    var body: some View {
        Menu {
            Section("Ordenar por") {
                ForEach(SteamDealSort.allCases) { option in
                    Button {
                        update { $0.sort = option }
                    } label: {
                        Label(option.displayName,
                              systemImage: config.sort == option ? "checkmark" : option.sfSymbol)
                    }
                }
            }
            Section {
                Button {
                    update { $0.onSale.toggle() }
                } label: {
                    Label(config.onSale ? "Solo en oferta ✓" : "Mostrar todas", systemImage: "tag")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: config.sort.sfSymbol).scaledFont(9, weight: .bold, scalesWithText: false)
                Text(config.sort.displayName).stacklumeFont(.caption2.weight(.semibold))
                Image(systemName: "chevron.down").scaledFont(8, weight: .bold, scalesWithText: false)
            }
            .readableTint(palette.accent, palette: palette, on: [palette.surface], overlay: palette.accent.opacity(0.12))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(palette.accent.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func update(_ change: (inout DealsConfig) -> Void) {
        var current = config
        change(&current)
        widget.configText = current.encoded
        context.saveLogging()
    }
}

/// Widget compacto de ofertas de Steam.
struct SteamDealsWidgetContent: View {
    @Bindable var widget: DashboardWidget
    var size: WidgetSize = .large

    @State private var deals: [SteamDeal] = []
    @State private var loading = true

    private var config: DealsConfig { DealsConfig.decode(widget.configText) }

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
            SteamDealsControls(widget: widget)
            if deals.isEmpty {
                DiscoverPlaceholder(loading: loading)
            } else {
                DiscoverList(items: deals, limit: limit, spacing: 8) { SteamDealRow(deal: $0) }
            }
        }
        .task(id: widget.configText) { await load() }
    }

    private func load() async {
        loading = true
        let current = config
        let result = await SteamDealsService.shared.deals(
            sort: current.sort, onSaleOnly: current.onSale, limit: 7)
        await MainActor.run { deals = result; loading = false }
    }
}
