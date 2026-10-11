import SwiftUI
import SwiftData
import StacklumeCore
import StacklumeDesignSystem
import StacklumeMetadata

/// Sección «Descubrir»: reúne los feeds externos (apps open source, GitHub trending,
/// Hacker News, Lobsters, dev.to, MAGI//ARCHIVE, Product Hunt, ofertas y destacados
/// de Steam, juegos gratis, ofertas de la App Store) y los feeds que el usuario añade
/// a mano, agrupados por categorías en una rejilla adaptativa.
///
/// Vistas distintas del feed organizado: conmutador de densidad (Cómodo/Compacto) y
/// foco por categoría, ambos persistentes. Reutiliza los componentes de contenido
/// (`*WidgetContent`) y la vista ampliada paginada `DiscoverDetailView`.
struct DiscoverView: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.modelContext) private var context

    /// Configuración persistente (sort/modo) de los feeds que la necesitan (Steam
    /// ofertas, Steam destacados, ofertas App Store). Se crea una vez y se conserva
    /// entre lanzamientos para recordar las preferencias del usuario.
    @State private var steamDealsWidget: DashboardWidget?
    @State private var steamSpotlightWidget: DashboardWidget?
    @State private var appStoreWidget: DashboardWidget?

    /// Hoja abierta (feed integrado, feed del usuario o gestor de feeds), si la hay.
    @State private var sheet: DiscoverSheet?

    // MARK: Vistas distintas + feeds del usuario (persistente)

    /// Densidad de la rejilla: false = Cómodo, true = Compacto (más por fila).
    @AppStorage("stacklume.discover.compact") private var compact = false
    /// Foco por categoría (vacío = todas). Guarda el `rawValue` de `DiscoverCategoryKey`.
    @AppStorage("stacklume.discover.focus") private var focusRaw = ""
    /// Feeds añadidos por el usuario (JSON en `@AppStorage`, ver [[CustomFeed]]).
    @AppStorage(CustomFeedStore.storageKey) private var customFeedsJSON = ""

    private var customFeeds: [CustomFeed] { CustomFeedStore.decode(customFeedsJSON) }
    private var focus: DiscoverCategoryKey? { DiscoverCategoryKey(rawValue: focusRaw) }

    /// Columnas adaptativas: más estrechas (más por fila) en modo compacto.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: compact ? 260 : 320, maximum: compact ? 420 : 520),
                  spacing: DesignSystem.Spacing.md, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                header
                controlBar
                grid
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .scrollIndicators(.visible)
        .background(WindowBackground())
        .navigationTitle("Descubrir")
        .task { ensureConfigWidgets() }
        .sheet(item: $sheet) { sheetContent(for: $0) }
    }

    // MARK: - Cabecera

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
            Text("Descubrir")
                .stacklumeFont(.title2.weight(.bold))
                .foregroundStyle(palette.textPrimary)
            Text("Explora lo último de la comunidad: apps open source, lanzamientos, repos en tendencia, noticias, artículos, juegos y ofertas. Añade tus propios feeds RSS y guarda lo que te interese con un clic.")
                .stacklumeFont(.callout)
                .foregroundStyle(palette.textSecondary)
                .frame(maxWidth: 620, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Barra de control (densidad · foco · añadir feed)

    private var controlBar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Picker("Densidad", selection: $compact) {
                Text("Cómodo").tag(false)
                Text("Compacto").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Picker("Categoría", selection: $focusRaw) {
                Text("Todas las categorías").tag("")
                ForEach(DiscoverCategoryKey.allCases) { key in
                    Text(key.title).tag(key.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .tint(palette.accent)

            Spacer(minLength: 0)

            Button {
                sheet = .manageFeeds
            } label: {
                Label("Añadir feed", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .tint(palette.accent)
            .themedHelp("Añadir o gestionar tus feeds RSS")
        }
    }

    // MARK: - Rejilla de tarjetas-sección

    private var grid: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            // 1 · Apps y software: apps open source (de pago y gratis), lanzamientos de
            // Product Hunt y ofertas de la App Store.
            if showCategory(.apps) {
                categorySection("Apps y software", icon: "square.grid.2x2.fill",
                                subtitle: "Apps open source, lanzamientos y ofertas de la App Store") {
                    sectionCard(.premiumApps) {
                        DesktopAppsWidgetContent(catalog: DesktopApps.premium, size: .extraLarge)
                    }
                    sectionCard(.freeApps) {
                        DesktopAppsWidgetContent(catalog: DesktopApps.free, size: .extraLarge)
                    }
                    sectionCard(.productHunt) {
                        RSSFeedWidgetContent(url: DiscoverFeed.productHuntFeedURL,
                                             tint: Color(hex: "#DA552F"), size: .extraLarge)
                    }
                    if let appStoreWidget {
                        sectionCard(.appStoreDeals) {
                            AppStoreDealsWidgetContent(widget: appStoreWidget, size: .extraLarge)
                        }
                    }
                }
            }
            // 2 · Código y desarrollo: tendencias de GitHub y repos curados.
            if showCategory(.code) {
                categorySection("Código y desarrollo", icon: "chevron.left.forwardslash.chevron.right",
                                subtitle: "Repos en tendencia y proyectos curados") {
                    sectionCard(.githubTrending) {
                        GitHubTrendingWidgetContent(size: .extraLarge)
                    }
                    sectionCard(.repoPosts) {
                        RepoPostsWidgetContent(size: .extraLarge)
                    }
                }
            }
            // 3 · Noticias y artículos: Hacker News, Lobsters y dev.to.
            if showCategory(.news) {
                categorySection("Noticias y artículos", icon: "newspaper.fill",
                                subtitle: "Lo que se cuece en la comunidad técnica") {
                    sectionCard(.hackerNews) {
                        HackerNewsWidgetContent(size: .extraLarge)
                    }
                    sectionCard(.lobsters) {
                        LobstersWidgetContent(size: .extraLarge)
                    }
                    sectionCard(.devArticles) {
                        DevArticlesWidgetContent(size: .extraLarge)
                    }
                }
            }
            // 4 · Juegos y ofertas: Steam (ofertas/destacados) y juegos gratis.
            if showCategory(.games) {
                categorySection("Juegos y ofertas", icon: "gamecontroller.fill",
                                subtitle: "Descuentos, destacados y juegos gratis") {
                    if let steamDealsWidget {
                        sectionCard(.steamDeals) {
                            SteamDealsWidgetContent(widget: steamDealsWidget, size: .extraLarge)
                        }
                    }
                    sectionCard(.freeGames) {
                        FreeGamesWidgetContent(size: .extraLarge)
                    }
                    if let steamSpotlightWidget {
                        sectionCard(.steamSpotlight) {
                            SteamSpotlightWidgetContent(widget: steamSpotlightWidget, size: .extraLarge)
                        }
                    }
                }
            }
            // 5 · Tus feeds: los que el usuario ha añadido a mano.
            if showCategory(.mine), !customFeeds.isEmpty {
                categorySection("Tus feeds", icon: "dot.radiowaves.up.forward",
                                subtitle: "Feeds RSS que has añadido") {
                    ForEach(customFeeds) { feed in
                        sectionCard(title: feed.title, subtitle: feed.host,
                                    icon: "dot.radiowaves.left.and.right",
                                    source: feed.title, onExpand: { sheet = .custom(feed) }) {
                            RSSFeedWidgetContent(url: feed.url, size: .extraLarge)
                        }
                    }
                }
            }
        }
    }

    /// ¿Debe mostrarse esta categoría con el foco actual?
    private func showCategory(_ key: DiscoverCategoryKey) -> Bool {
        focus == nil || focus == key
    }

    /// Agrupa varias tarjetas-sección bajo una cabecera de categoría, en la rejilla
    /// adaptativa. Cabeceras claras con rasgo `.isHeader` para VoiceOver.
    @ViewBuilder
    private func categorySection<Content: View>(
        _ title: String, icon: String, subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.xs) {
                Image(systemName: icon)
                    .scaledFont(15, weight: .bold, scalesWithText: false)
                    .foregroundStyle(palette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .stacklumeFont(.title3.weight(.bold))
                        .foregroundStyle(palette.textPrimary)
                    Text(subtitle)
                        .stacklumeFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, spacing: DesignSystem.Spacing.md) {
                content()
            }
        }
    }

    // MARK: - Tarjeta-sección

    /// Tarjeta-sección genérica: cabecera (icono + título + «Ampliar») y el contenido
    /// del feed, sobre `palette.surface` con borde y sombra sutiles. El alto se adapta
    /// a la densidad elegida.
    private func sectionCard<Content: View>(
        title: String, subtitle: String, icon: String,
        source: String? = nil, onExpand: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            sectionHeader(title: title, subtitle: subtitle, icon: icon, onExpand: onExpand)
            content()
                .frame(maxWidth: .infinity,
                       minHeight: compact ? 200 : 260, maxHeight: compact ? 250 : 320,
                       alignment: .top)
                // Recorta a la caja: si la lista interna mide de más una fila, NO debe
                // derramarse fuera de la tarjeta.
                .clipped()
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(palette.surface,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.border.opacity(0.6), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        // Fuente del feed → las filas la usan para construir el `DiscoverItem` (clic =
        // mostrar en el panel de detalle).
        .environment(\.discoverSource, DiscoverSource(name: source ?? title, icon: icon))
    }

    /// Conveniencia para los feeds integrados (`DiscoverFeed`): rellena título,
    /// subtítulo, icono y la acción de ampliar a partir del caso.
    private func sectionCard<Content: View>(
        _ feed: DiscoverFeed,
        @ViewBuilder content: () -> Content
    ) -> some View {
        sectionCard(title: feed.title, subtitle: feed.subtitle, icon: feed.icon,
                    source: feed.title, onExpand: { sheet = .feed(feed) }, content: content)
    }

    /// Cabecera de una tarjeta-sección: icono con tinte, título y botón de ampliar.
    private func sectionHeader(title: String, subtitle: String, icon: String,
                               onExpand: @escaping () -> Void) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: icon)
                .scaledFont(14, weight: .semibold, scalesWithText: false)
                .foregroundStyle(palette.accent)
                .frame(width: 30, height: 30)
                .background(palette.accent.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .stacklumeFont(.headline)
                    .foregroundStyle(palette.textPrimary)
                    .stacklumeLineLimit(1)
                Text(subtitle)
                    .stacklumeFont(.caption2)
                    .foregroundStyle(palette.textSecondary)
                    .stacklumeLineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                onExpand()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
            .buttonStyle(.plain)
            .themedHelp("Ampliar")
            .accessibilityLabel("Ampliar \(title)")
        }
    }

    // MARK: - Hojas (vista ampliada y gestor de feeds)

    @ViewBuilder
    private func sheetContent(for sheet: DiscoverSheet) -> some View {
        switch sheet {
        case .feed(let feed):
            detailSheet(for: feed)
        case .custom(let feed):
            DiscoverDetailView(
                title: feed.title, icon: "dot.radiowaves.left.and.right", resetKey: feed.url,
                loadPage: { await RSSService.shared.page($0, url: feed.url) },
                saveInfo: { DiscoverSaveInfo(url: $0.link, title: $0.title, imageURL: $0.imageURL) },
                row: { RSSItemRow(item: $0, expanded: true) }
            )
        case .manageFeeds:
            CustomFeedsManagerView()
        }
    }

    @ViewBuilder
    private func detailSheet(for feed: DiscoverFeed) -> some View {
        switch feed {
        case .premiumApps:
            DesktopAppsDetailView(catalog: DesktopApps.premium, title: feed.title, icon: feed.icon)
        case .freeApps:
            DesktopAppsDetailView(catalog: DesktopApps.free, title: feed.title, icon: feed.icon)
        case .productHunt:
            DiscoverDetailView(
                title: feed.title, icon: feed.icon, resetKey: "productHunt",
                loadPage: { await RSSService.shared.page($0, url: DiscoverFeed.productHuntFeedURL) },
                saveInfo: { DiscoverSaveInfo(url: $0.link, title: $0.title, imageURL: $0.imageURL) },
                row: { RSSItemRow(item: $0, tint: Color(hex: "#DA552F"), expanded: true) }
            )
        case .lobsters:
            DiscoverDetailView(
                title: feed.title, icon: feed.icon, resetKey: "lobsters",
                loadPage: { await LobstersService.shared.page($0) },
                saveInfo: { DiscoverSaveInfo(url: $0.openURL, title: $0.title) },
                row: { LobsterRow(story: $0, expanded: true) }
            )
        case .githubTrending:
            DiscoverDetailView(
                title: feed.title, icon: feed.icon, resetKey: "github",
                loadPage: { page in
                    await GitHubTrendingService.shared.page(page, since: GitHubTrendingDates.sinceLastWeek)
                },
                saveInfo: { DiscoverSaveInfo(url: $0.url, title: $0.fullName, imageURL: $0.avatarURL) },
                row: { TrendingRepoRow(repo: $0, expanded: true) }
            )
        case .repoPosts:
            DiscoverDetailView(
                title: feed.title, icon: feed.icon, resetKey: "repoPosts",
                loadPage: { await RepoPostsService.shared.page($0) },
                saveInfo: { DiscoverSaveInfo(url: $0.repoURL, title: $0.name, imageURL: $0.thumbnail) },
                row: { RepoPostRow(post: $0, expanded: true) }
            )
        case .hackerNews:
            DiscoverDetailView(
                title: feed.title, icon: feed.icon, resetKey: "hn",
                loadPage: { await HackerNewsService.shared.page($0) },
                saveInfo: { DiscoverSaveInfo(url: $0.openURL, title: $0.title) },
                row: { HNStoryRow(story: $0, expanded: true) }
            )
        case .devArticles:
            DiscoverDetailView(
                title: feed.title, icon: feed.icon, resetKey: "devto",
                loadPage: { await DevArticlesService.shared.page($0) },
                saveInfo: { DiscoverSaveInfo(url: $0.url, title: $0.title, imageURL: $0.coverImage) },
                row: { DevArticleRow(article: $0, expanded: true) }
            )
        case .steamDeals:
            if let steamDealsWidget {
                DiscoverDetailView(
                    title: feed.title, icon: feed.icon,
                    controls: AnyView(SteamDealsControls(widget: steamDealsWidget)),
                    resetKey: steamDealsWidget.configText ?? "default",
                    loadPage: { page in
                        let cfg = DealsConfig.decode(steamDealsWidget.configText)
                        return await SteamDealsService.shared.page(page, sort: cfg.sort, onSaleOnly: cfg.onSale)
                    },
                    saveInfo: { DiscoverSaveInfo(url: $0.storeURL, title: $0.title, imageURL: $0.thumb) },
                    row: { SteamDealRow(deal: $0, expanded: true) }
                )
                .id(steamDealsWidget.configText ?? "default")
            }
        case .freeGames:
            DiscoverDetailView(
                title: feed.title, icon: feed.icon, resetKey: "freeGames",
                loadPage: { await FreeGamesService.shared.page($0) },
                saveInfo: { DiscoverSaveInfo(url: $0.url, title: $0.title, imageURL: $0.thumbnail) },
                row: { FreeGameRow(game: $0, expanded: true) }
            )
        case .steamSpotlight:
            if let steamSpotlightWidget {
                DiscoverDetailView(
                    title: feed.title, icon: feed.icon,
                    controls: AnyView(SteamSpotlightControls(widget: steamSpotlightWidget)),
                    resetKey: steamSpotlightWidget.configText ?? "default",
                    loadPage: { page in
                        let kind = SteamSpotlightKind(rawValue: steamSpotlightWidget.configText ?? "") ?? .topSellers
                        return await SteamSpotlightService.shared.page(page, kind: kind)
                    },
                    saveInfo: { DiscoverSaveInfo(url: $0.url, title: $0.name, imageURL: $0.image) },
                    row: { SteamSpotlightRow(item: $0, expanded: true) }
                )
                .id(steamSpotlightWidget.configText ?? "default")
            }
        case .appStoreDeals:
            if let appStoreWidget {
                AppDealsDetailView(widget: appStoreWidget)
            }
        }
    }

    // MARK: - Widgets de configuración persistentes

    /// Crea (una sola vez) los `DashboardWidget` de configuración que necesitan los
    /// feeds con orden/filtro/modo persistente. Reutiliza los ya guardados.
    private func ensureConfigWidgets() {
        guard steamDealsWidget == nil else { return }
        steamDealsWidget = fetchOrCreate(.steamDeals)
        steamSpotlightWidget = fetchOrCreate(.steamSpotlight)
        appStoreWidget = fetchOrCreate(.appStoreDeals)
    }

    /// Busca el widget de configuración de un tipo (el primero activo) o lo crea.
    private func fetchOrCreate(_ type: WidgetType) -> DashboardWidget {
        let descriptor = FetchDescriptor<DashboardWidget>(
            predicate: #Predicate { $0.deletedAt == nil })
        if let existing = (try? context.fetch(descriptor))?.first(where: { $0.type == type }) {
            return existing
        }
        let widget = DashboardWidget(type: type)
        context.insert(widget)
        context.saveLogging()
        return widget
    }
}

// MARK: - Categorías de la sección (para el foco)

/// Categorías visibles en «Descubrir», usadas por el filtro de foco de la barra de
/// control. El orden coincide con el de la rejilla.
enum DiscoverCategoryKey: String, CaseIterable, Identifiable {
    case apps, code, news, games, mine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apps: "Apps y software"
        case .code: "Código y desarrollo"
        case .news: "Noticias y artículos"
        case .games: "Juegos y ofertas"
        case .mine: "Tus feeds"
        }
    }
}

// MARK: - Hoja abierta

/// Hoja que puede estar abierta en «Descubrir»: un feed integrado, un feed del
/// usuario o el gestor de feeds.
enum DiscoverSheet: Identifiable {
    case feed(DiscoverFeed)
    case custom(CustomFeed)
    case manageFeeds

    var id: String {
        switch self {
        case .feed(let feed): "feed-\(feed.rawValue)"
        case .custom(let feed): "custom-\(feed.id.uuidString)"
        case .manageFeeds: "manage"
        }
    }
}

// MARK: - Catálogo de feeds integrados

/// Feeds externos presentados en la sección «Descubrir». Cada caso conoce su título,
/// subtítulo e icono; el contenido y la vista ampliada los resuelve `DiscoverView`
/// reutilizando los componentes existentes.
enum DiscoverFeed: String, Identifiable, CaseIterable {
    case premiumApps
    case freeApps
    case productHunt
    case githubTrending
    case repoPosts
    case hackerNews
    case lobsters
    case devArticles
    case steamDeals
    case freeGames
    case steamSpotlight
    case appStoreDeals

    var id: String { rawValue }

    /// Feed RSS público de Product Hunt (lanzamientos), sin necesidad de token.
    static let productHuntFeedURL = "https://www.producthunt.com/feed"

    var title: String {
        switch self {
        case .premiumApps: "Apps open source premium"
        case .freeApps: "Apps open source gratis"
        case .productHunt: "Product Hunt"
        case .githubTrending: "GitHub Trending"
        case .repoPosts: "MAGI//ARCHIVE"
        case .hackerNews: "Hacker News"
        case .lobsters: "Lobsters"
        case .devArticles: "Artículos dev"
        case .steamDeals: "Ofertas de Steam"
        case .freeGames: "Juegos gratis"
        case .steamSpotlight: "Steam: destacados"
        case .appStoreDeals: "Ofertas App Store"
        }
    }

    var subtitle: String {
        switch self {
        case .premiumApps: "Grandes proyectos OSS con opción de pago (Mac/Windows)"
        case .freeApps: "Utilidades open source gratis (Mac/Windows)"
        case .productHunt: "Los lanzamientos destacados del día"
        case .githubTrending: "Repos en tendencia esta semana"
        case .repoPosts: "Repos curados de tom-doerr"
        case .hackerNews: "Las historias top de HN"
        case .lobsters: "Comunidad técnica enfocada"
        case .devArticles: "Artículos técnicos de dev.to"
        case .steamDeals: "Descuentos en juegos de Steam"
        case .freeGames: "Gratis por tiempo limitado"
        case .steamSpotlight: "Top ventas, novedades y ofertas"
        case .appStoreDeals: "Bajadas de precio de apps de pago"
        }
    }

    var icon: String {
        switch self {
        case .premiumApps: "macwindow"
        case .freeApps: "shippingbox.fill"
        case .productHunt: "sparkles"
        case .githubTrending: "flame.fill"
        case .repoPosts: "binoculars.fill"
        case .hackerNews: "newspaper.fill"
        case .lobsters: "tortoise.fill"
        case .devArticles: "doc.richtext.fill"
        case .steamDeals: "gamecontroller.fill"
        case .freeGames: "gift.fill"
        case .steamSpotlight: "crown.fill"
        case .appStoreDeals: "arrow.down.circle.fill"
        }
    }
}
