import SwiftUI
import SwiftData
import StacklumeCore
import StacklumeDesignSystem
import StacklumeMetadata

// MARK: - Configuración (orden / filtro), guardada en widget.configText

struct AppDealsConfig: Codable {
    enum Filter: String, Codable, CaseIterable { case all, games, apps }
    enum Sort: String, Codable, CaseIterable { case discount, price, recent }

    var filter: Filter = .all
    var sort: Sort = .discount
    /// Por defecto se muestran TODAS las apps/juegos de pago (con las ofertas
    /// destacadas y arriba); el usuario puede activar «solo ofertas».
    var onlyDeals: Bool = false

    static func decode(_ raw: String?) -> AppDealsConfig {
        guard let raw, let data = raw.data(using: .utf8),
              let c = try? JSONDecoder().decode(AppDealsConfig.self, from: data) else { return AppDealsConfig() }
        return c
    }
    var encoded: String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Aplica filtro y orden a las apps vigiladas.
    func apply(to apps: [TrackedApp]) -> [TrackedApp] {
        var r = apps.filter { $0.currentPrice > 0 }   // solo de pago (pago único)
        switch filter {
        case .games: r = r.filter(\.isGame)
        case .apps: r = r.filter { !$0.isGame }
        case .all: break
        }
        if onlyDeals { r = r.filter(\.isOnSale) }
        // Las ofertas van siempre primero (para destacarlas); dentro de cada grupo
        // se aplica el orden elegido.
        r.sort { a, b in
            if a.isOnSale != b.isOnSale { return a.isOnSale }
            switch sort {
            case .discount:
                if a.discountPercent != b.discountPercent { return a.discountPercent > b.discountPercent }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .price:
                return a.currentPrice < b.currentPrice
            case .recent:
                return (a.priceDropAt ?? a.firstSeenAt) > (b.priceDropAt ?? b.firstSeenAt)
            }
        }
        return r
    }
}

extension AppDealsConfig.Filter {
    var displayName: String {
        switch self { case .all: "Todos"; case .games: "Juegos"; case .apps: "Apps" }
    }
}
extension AppDealsConfig.Sort {
    var displayName: String {
        switch self { case .discount: "Mayor descuento"; case .price: "Precio más bajo"; case .recent: "Más recientes" }
    }
    var sfSymbol: String {
        switch self { case .discount: "tag.fill"; case .price: "eurosign.circle.fill"; case .recent: "clock.fill" }
    }
}

// MARK: - Fila reutilizable (compacto y ampliado)

/// Fila de una app/juego de pago vigilada. Clic abre su ficha en la App Store
/// (vía `openURL`, que la abre en la Mac App Store o web); clic derecho (o el
/// botón +) la guarda en la biblioteca.
struct AppDealRow: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.openURL) private var openURL
    let app: TrackedApp
    var expanded = false

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            SecureRemoteImage(candidates: [app.artworkURL]) {
                Image(systemName: app.isGame ? "gamecontroller" : "app.fill")
                    .font(.caption2).foregroundStyle(palette.textSecondary)
            }
            .frame(width: expanded ? 44 : 34, height: expanded ? 44 : 34)
            .clipShape(RoundedRectangle(cornerRadius: expanded ? 10 : 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .stacklumeFont(.caption.weight(.semibold))
                    .foregroundStyle(palette.textPrimary)
                    .stacklumeLineLimit(1)
                HStack(spacing: 5) {
                    if app.isOnSale {
                        Text("OFERTA")
                            .scaledFont(8, weight: .heavy)
                            .foregroundStyle(Color(hex: "#22C55E").contrastingForeground)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color(hex: "#22C55E"), in: Capsule())
                            .accessibilityHidden(true)
                    }
                    Text(app.genre.isEmpty ? app.artist : app.genre)
                        .stacklumeFont(.caption2)
                        .foregroundStyle(palette.textSecondary)
                        .stacklumeLineLimit(1)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                if app.isOnSale {
                    Text("-\(app.discountPercent)%")
                        .stacklumeFont(.caption2.weight(.bold))
                        .foregroundStyle(palette.readableForeground(Color(hex: "#22C55E"), on: palette.surface))
                        .accessibilityHidden(true)
                }
                HStack(spacing: 5) {
                    if app.isOnSale {
                        Text(app.highestPriceText)
                            .strikethrough()
                            .foregroundStyle(palette.textSecondary)
                            .accessibilityHidden(true)
                    }
                    Text(app.currentPriceText)
                        .fontWeight(.semibold)
                        .foregroundStyle(palette.textPrimary)
                        .accessibilityLabel(app.isOnSale
                            ? "Precio en oferta: \(app.currentPriceText), antes \(app.highestPriceText), \(app.discountPercent)% de descuento"
                            : "Precio: \(app.currentPriceText)")
                }
                .stacklumeFont(.caption2)
            }
        }
        .discoverRow(url: app.appStoreURL, title: app.name, imageURL: app.artworkURL) {
            if let url = StacklumeAutomationPolicy.openableStoredURL(app.appStoreURL) { openURL(url) }
        }
    }
}

// MARK: - Widget compacto

struct AppStoreDealsWidgetContent: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.modelContext) private var context
    @Bindable var widget: DashboardWidget
    var size: WidgetSize = .large

    @Query private var all: [TrackedApp]
    @State private var loading = true

    private var config: AppDealsConfig { AppDealsConfig.decode(widget.configText) }

    private var limit: Int {
        switch size {
        case .extraLarge: 7
        case .large: 5
        case .medium, .wide: 3
        default: 2
        }
    }

    var body: some View {
        let deals = config.apply(to: all)
        Group {
            if deals.isEmpty {
                emptyState
            } else {
                DiscoverList(items: deals, limit: limit, spacing: 8) { app in
                    AppDealRow(app: app)
                }
            }
        }
        .task { await sync() }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 6) {
            if loading && all.isEmpty {
                ProgressView()
            } else {
                Image(systemName: "checkmark.seal").foregroundStyle(palette.textSecondary)
                Text(all.isEmpty ? "Preparando seguimiento…" : "Vigilando \(all.count) apps de pago")
                    .stacklumeFont(.caption2).foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
                if !all.isEmpty {
                    Text("Te avisaré cuando bajen de precio")
                        .stacklumeFont(.caption2).foregroundStyle(palette.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sync() async {
        await AppDealsStore.sync(context: context)
        loading = false
    }
}

// MARK: - Vista ampliada (hoja)

/// Vista ampliada del widget «Ofertas App Store»: lista completa de apps/juegos
/// de pago vigilados, con filtro (todos/juegos/apps), orden, conmutador «solo
/// ofertas», botón de actualizar precios ahora y de añadir apps al seguimiento.
struct AppDealsDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @Environment(\.modelContext) private var context
    @Bindable var widget: DashboardWidget

    @Query private var all: [TrackedApp]
    @State private var refreshing = false
    @State private var showAdd = false

    private var config: AppDealsConfig { AppDealsConfig.decode(widget.configText) }

    var body: some View {
        let apps = config.apply(to: all)
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.border.opacity(0.4))
            controls
            Divider().overlay(palette.border.opacity(0.4))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(apps) { app in
                        HStack(alignment: .center, spacing: 12) {
                            AppDealRow(app: app, expanded: true)
                            DiscoverSaveButton(url: app.appStoreURL, title: app.name, imageURL: app.artworkURL)
                        }
                        Divider().overlay(palette.border.opacity(0.4))
                    }
                    if apps.isEmpty { emptyState }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
        .frame(minWidth: 480, minHeight: 540)
        .background(palette.background)
        .environment(\.discoverExpandAction, nil)
        .sheet(isPresented: $showAdd) { AddTrackedAppView() }
        .task { await AppDealsStore.sync(context: context) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: widget.type.sfSymbol).foregroundStyle(palette.accent)
            Text(widget.title.isEmpty ? widget.type.displayName : widget.title)
                .stacklumeFont(.headline)
                .foregroundStyle(palette.textPrimary)
            Spacer(minLength: 0)
            Button("Cerrar") { dismiss() }.tint(palette.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Menu {
                Section("Mostrar") {
                    ForEach(AppDealsConfig.Filter.allCases, id: \.self) { f in
                        Button { update { $0.filter = f } } label: {
                            Label(f.displayName, systemImage: config.filter == f ? "checkmark" : "")
                        }
                    }
                }
                Section("Ordenar por") {
                    ForEach(AppDealsConfig.Sort.allCases, id: \.self) { s in
                        Button { update { $0.sort = s } } label: {
                            Label(s.displayName, systemImage: config.sort == s ? "checkmark" : s.sfSymbol)
                        }
                    }
                }
                Section {
                    Button { update { $0.onlyDeals.toggle() } } label: {
                        Label(config.onlyDeals ? "Solo ofertas ✓" : "Mostrar vigiladas", systemImage: "tag")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: config.sort.sfSymbol).scaledFont(9, weight: .bold, scalesWithText: false)
                    Text("\(config.filter.displayName) · \(config.onlyDeals ? "Ofertas" : "Todas")")
                        .stacklumeFont(.caption2.weight(.semibold))
                    Image(systemName: "chevron.down").scaledFont(8, weight: .bold, scalesWithText: false)
                }
                .readableTint(palette.accent, palette: palette, on: [palette.surface], overlay: palette.accent.opacity(0.12))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(palette.accent.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .themedHelp("Filtrar y ordenar apps vigiladas")

            Spacer(minLength: 0)

            Button { showAdd = true } label: {
                Image(systemName: "plus.magnifyingglass").font(.subheadline)
            }
            .buttonStyle(.plain)
            .tint(palette.accent)
            .accessibilityLabel("Buscar apps para vigilar")
            .themedHelp("Buscar apps para añadir al seguimiento de precios")

            Button { Task { await refresh() } } label: {
                if refreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise").font(.subheadline)
                }
            }
            .buttonStyle(.plain)
            .tint(palette.accent)
            .disabled(refreshing)
            .accessibilityLabel("Actualizar precios")
            .themedHelp("Actualizar precios ahora")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal").font(.title2).foregroundStyle(palette.textSecondary)
            Text(config.onlyDeals ? "Sin bajadas de precio todavía" : "Sin apps vigiladas")
                .stacklumeFont(.subheadline).foregroundStyle(palette.textPrimary)
            Text(config.onlyDeals
                 ? "Vigilando \(all.count) apps de pago. Las ofertas aparecerán aquí cuando Apple baje precios. Pulsa actualizar o añade tus apps."
                 : "Añade apps con el buscador para vigilar su precio.")
                .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func update(_ change: (inout AppDealsConfig) -> Void) {
        var c = config
        change(&c)
        widget.configText = c.encoded
        context.saveLogging()
    }

    private func refresh() async {
        refreshing = true
        await AppDealsStore.sync(context: context, force: true)
        refreshing = false
    }
}

/// Buscador para añadir manualmente una app/juego de pago al seguimiento.
struct AddTrackedAppView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @Environment(\.modelContext) private var context

    @State private var query = ""
    @State private var results: [AppStoreApp] = []
    @State private var searching = false

    private var country: String { Locale.current.region?.identifier.lowercased() ?? "us" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "plus.magnifyingglass").foregroundStyle(palette.accent)
                Text("Añadir app a vigilar")
                    .stacklumeFont(.headline)
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 0)
                Button("Cerrar") { dismiss() }.tint(palette.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider().overlay(palette.border.opacity(0.4))

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(palette.textSecondary)
                TextField("Buscar en la App Store", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await runSearch() } }
                if searching { ProgressView().controlSize(.small) }
            }
            .padding(8)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(16)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(results) { app in
                        Button { add(app) } label: { row(app) }
                            .buttonStyle(.plain)
                            .disabled(app.price <= 0)
                    }
                    if results.isEmpty, !searching, !query.isEmpty {
                        Text("Sin resultados de pago para «\(query)»")
                            .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .frame(minWidth: 420, minHeight: 480)
        .background(palette.background)
    }

    private func row(_ app: AppStoreApp) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            SecureRemoteImage(candidates: [app.artworkURL]) {
                Image(systemName: app.isGame ? "gamecontroller" : "app.fill")
                    .foregroundStyle(palette.textSecondary)
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).stacklumeFont(.body.weight(.medium)).foregroundStyle(palette.textPrimary).stacklumeLineLimit(1)
                Text(app.genre).stacklumeFont(.caption).foregroundStyle(palette.textSecondary).stacklumeLineLimit(1)
            }
            Spacer(minLength: 0)
            Text(app.price > 0 ? String(format: "%.2f %@", app.price, app.currency) : "Gratis")
                .stacklumeFont(.caption.weight(.semibold))
                .foregroundStyle(app.price > 0 ? palette.textPrimary : palette.textSecondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    private func runSearch() async {
        searching = true
        results = await iTunesPriceService.shared.search(term: query, country: country, limit: 25)
        searching = false
    }

    private func add(_ app: AppStoreApp) {
        if AppDealsStore.track(app, context: context) {
            dismiss()
        }
    }
}
