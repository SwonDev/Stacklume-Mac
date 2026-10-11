import SwiftUI
import AppKit
import StacklumeDesignSystem

struct ModelCatalogView: View {
    let provider: ModelCatalogProvider
    @Environment(\.themePalette) private var palette
    @Environment(\.appTheme) private var theme
    @State private var state: ModelCatalogState
    @AppStorage private var adultPreference: String
    @AppStorage private var viewPreference: String
    @AppStorage private var previewPreference: String
    @State private var paginationTask: Task<Void, Never>?
    @State private var catalogMedia: ModelCatalogGallerySelection?
    @State private var showsFilters = false
    @State private var showsQuickFilters = false
    @State private var showsConnection = false
    @State private var saveSelection: ModelCatalogSaveSelection?
    @State private var showsFavorites = false
    @State private var favoritesQuery = ""
    @State private var favoritesPage = 0
    @State private var favoritesOrder = "recent"
    @State private var favoriteTask: Task<Void, Never>?
    @State private var favoriteMedia: ModelCatalogGallerySelection?
    @State private var favoritePost: ModelCatalogPost?
    @State private var favoritePostModel: ModelCatalogItem?
    private var favoriteMatches: [ModelCatalogFavorite] {
        state.favorites.filter { state.filters.adultFilter.allows($0.contentRating, provider: provider) && (favoritesQuery.isEmpty || [$0.title, $0.author ?? "", $0.modelID].contains { $0.localizedCaseInsensitiveContains(favoritesQuery) }) }.sorted { left, right in
            if favoritesOrder == "name" { return left.title.localizedStandardCompare(right.title) == .orderedAscending }
            if favoritesOrder == "author" { return (left.author ?? left.modelID).localizedStandardCompare(right.author ?? right.modelID) == .orderedAscending }
            return left.createdAt > right.createdAt
        }
    }
    private var searchText: Binding<String> { Binding(get: { showsFavorites ? favoritesQuery : state.filters.query }, set: { if showsFavorites { favoritesQuery = $0; favoritesPage = 0 } else { state.filters.query = $0 } }) }
    private var viewMode: LibraryViewMode { LibraryViewMode(rawValue: viewPreference) == .grid ? .grid : .list }
    private var previewSize: ModelCatalogPreviewSize { ModelCatalogPreviewSize(rawValue: previewPreference) ?? .comfortable }
    private func search() {
        paginationTask?.cancel()
        if showsFavorites { state.refreshFavorites(); favoritesPage = 0 } else { state.search() }
    }
    private func changeFilters(_ change: (inout ModelCatalogFilters) -> Void) {
        change(&state.filters); paginationTask?.cancel(); state.search()
    }
    private func paginate(_ action: @escaping @MainActor () async -> Void) {
        paginationTask?.cancel(); paginationTask = Task { await action() }
    }
    private func openFavorite(_ favorite: ModelCatalogFavorite, organize: Bool = false) {
        if !favorite.isModel {
            if organize { saveSelection = .favorite(favorite); return }
            if let sample = favorite.media {
                favoriteMedia = .init(provider: favorite.provider, title: favorite.title, media: [sample], selectedID: sample.id, includeAdult: state.filters.includeAdult, sourceURL: favorite.url, adultFilter: state.filters.adultFilter, model: favorite.modelSnapshot)
            } else if let post = favorite.post { favoritePostModel = favorite.modelSnapshot; favoritePost = post }
            return
        }
        favoriteTask?.cancel()
        favoriteTask = Task {
            await state.openFavorite(favorite)
            guard !Task.isCancelled, let item = state.selected, item.id == favorite.modelID else { return }
            if organize { saveSelection = .init(item: item, version: nil) }
        }
    }

    init(provider: ModelCatalogProvider) {
        self.provider = provider
        _state = State(initialValue: ModelCatalogState(provider: provider))
        _adultPreference = AppStorage(wrappedValue: ModelCatalogAdultFilter.exclude.rawValue, "stacklume.modelCatalog.adult.\(provider.rawValue)")
        _viewPreference = AppStorage(wrappedValue: provider == .civitai ? LibraryViewMode.grid.rawValue : LibraryViewMode.list.rawValue, "stacklume.modelCatalog.view.\(provider.rawValue)")
        _previewPreference = AppStorage(wrappedValue: ModelCatalogPreviewSize.comfortable.rawValue, "stacklume.modelCatalog.preview.\(provider.rawValue)")
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                adaptiveToolbar(availableSize: geometry.size)
                if let item = state.selected {
                    if geometry.size.width >= 820 {
                        HStack(spacing: 0) {
                            Group { if showsFavorites { favorites } else { results } }.frame(maxWidth: .infinity)
                            Divider().overlay(palette.border)
                            detail(item).frame(maxWidth: .infinity)
                        }
                    } else {
                        detail(item)
                    }
                } else if showsFavorites {
                    favorites
                } else {
                    results
                }
            }
        }
        .background(WindowBackground())
        .task(id: provider) {
            if state.provider != provider { state = ModelCatalogState(provider: provider) }
            await state.reload()
        }
        .sheet(isPresented: $showsFilters) {
            ModelCatalogFilterSheet(provider: provider, filters: state.filters, connected: state.connected, taxonomy: state.taxonomy, taxonomyError: state.taxonomyError, isTaxonomyLoading: state.isTaxonomyLoading) { filters in
                state.filters = filters; showsFilters = false; paginationTask?.cancel(); state.search()
            }
            .themedSheet(palette, theme)
            .task { if provider == .huggingFace { await state.loadTaxonomy() } }
        }
        .sheet(isPresented: $showsConnection) {
            ModelCatalogConnectionSheet(provider: provider, connectionStatus: state.connectionStatus) {
                await state.reload()
            }
            .themedSheet(palette, theme)
        }
        .sheet(item: $saveSelection) { selection in
            ModelCatalogSaveSheet(selection: selection)
                .themedSheet(palette, theme)
        }
        .sheet(item: $catalogMedia) { selection in ModelCatalogGalleryView(selection: selection).themedSheet(palette, theme) }
        .sheet(item: $favoriteMedia) { selection in ModelCatalogGalleryView(selection: selection).themedSheet(palette, theme) }
        .sheet(item: $favoritePost) { post in
            if let model = favoritePostModel { ModelCatalogPostDetailView(item: model, post: post, includeAdult: state.filters.includeAdult, adultFilter: state.filters.adultFilter).themedSheet(palette, theme) }
        }
        .onChange(of: adultPreference) { _, value in if let policy = ModelCatalogAdultFilter(rawValue: value) { state.filters.adultFilter = policy; favoritesPage = 0 } }
        .onChange(of: favoriteMedia?.id) { _, value in if value == nil { state.refreshFavorites() } }
        .onChange(of: favoritePost?.id) { _, value in if value == nil { state.refreshFavorites() } }
        .onChange(of: showsFavorites) { _, value in if value { state.refreshFavorites() } }
        .onDisappear { favoriteTask?.cancel(); paginationTask?.cancel(); state.cancelSearch(); state.stopConnectionUpdates() }
    }

    @ViewBuilder private func adaptiveToolbar(availableSize: CGSize) -> some View {
        let expandedNarrow = availableSize.width < 640 && showsQuickFilters
        let shortViewport = availableSize.width < 820 && availableSize.height < 720
        if !showsFavorites && (expandedNarrow || shortViewport) {
            ScrollView(.vertical) {
                toolbar(availableWidth: availableSize.width)
            }
            .frame(height: max(0, availableSize.height * 0.4))
            .accessibilityLabel("Filtros rápidos del catálogo")
        } else {
            toolbar(availableWidth: availableSize.width)
        }
    }

    private func toolbar(availableWidth: CGFloat) -> some View {
        let wide = availableWidth >= 820
        let searchLayout = wide
            ? AnyLayout(HStackLayout(alignment: .bottom, spacing: DesignSystem.Spacing.md))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: DesignSystem.Spacing.xs))
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignSystem.Spacing.sm) { title; Spacer(minLength: 8); toolbarActions }
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) { title; toolbarActions }
            }
            searchLayout {
                searchControl
                if !showsFavorites { presentationControls.fixedSize(horizontal: wide, vertical: false) }
                else { adultControl }
            }
            if !showsFavorites {
                if availableWidth < 640 {
                    DisclosureGroup(isExpanded: $showsQuickFilters) { quickFilters(compact: false) } label: {
                        Text("Filtros rápidos").stacklumeFont(.caption.weight(.semibold))
                    }
                    Text(quickFilterSummary).stacklumeFont(.caption).foregroundStyle(palette.textSecondary).stacklumeLineLimit(2)
                } else { quickFilters(compact: wide) }
            }
            Text(state.connectionStatus.message)
                .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            if state.hasPendingContentFilter { Text("El contenido permitido ha cambiado en el visor. Pulsa Buscar para actualizar las páginas del proveedor.").stacklumeFont(.caption).foregroundStyle(palette.textSecondary) }
            if let connectionError = state.connectionError {
                Label(connectionError, systemImage: "exclamationmark.triangle").stacklumeFont(.caption).foregroundStyle(palette.textPrimary)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background { StacklumeGlassBackdrop(shape: Rectangle(), tint: palette.accent, tintOpacity: 0.025) }
    }

    private var searchControl: some View {
        HStack(alignment: .bottom, spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.textSecondary)
                .padding(.bottom, DesignSystem.Spacing.sm)
            ModelCatalogField(showsFavorites ? "Buscar en mis favoritos" : "Buscar modelos en \(provider.title)", text: searchText).onSubmit { search() }
                .accessibilityLabel(showsFavorites ? "Buscar en mis favoritos" : "Buscar modelos en \(provider.title)")
            if !searchText.wrappedValue.isEmpty {
                Button { searchText.wrappedValue = ""; search() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).accessibilityLabel("Limpiar búsqueda")
                    .themedHelp("Limpiar búsqueda y consultar el catálogo")
                    .padding(.bottom, DesignSystem.Spacing.sm)
            }
            Button("Buscar") { search() }
                .stacklumeButton().disabled(state.isLoading)
                .padding(.bottom, DesignSystem.Spacing.xs)
        }
        .frame(maxWidth: .infinity)
    }

    private var title: some View {
        Label(provider.title, systemImage: provider.symbol)
            .stacklumeFont(.title2.weight(.bold)).foregroundStyle(palette.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }

    private var toolbarActions: some View {
        ViewThatFits(in: .horizontal) { toolbarActions(compact: false).fixedSize(); toolbarActions(compact: true) }
    }

    private func toolbarActions(compact: Bool) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Button { showsFavorites.toggle(); state.selected = nil; state.refreshFavorites() } label: { actionLabel(showsFavorites ? "Catálogo" : "Favoritos", symbol: showsFavorites ? "rectangle.grid.1x2" : "star", compact: compact) }
                .stacklumeButton(prominent: false, compact: compact).themedHelp("Consultar favoritos locales de esta sección")
            Button { showsFilters = true } label: { actionLabel("Filtros", symbol: "line.3.horizontal.decrease", compact: compact) }
                .stacklumeButton(prominent: false, compact: compact).themedHelp("Filtrar y ordenar los modelos")
            Button { showsConnection = true } label: { actionLabel(state.connectionStatus == .authorizationRequired ? "Autorizar acceso" : (state.connectionStatus != .absent ? "Cuenta" : "Conectar"), symbol: "key", compact: compact) }
                .stacklumeButton(prominent: false, compact: compact).themedHelp("Gestionar el acceso de cuenta a \(provider.title)")
            Button { search() } label: { Image(systemName: "arrow.clockwise") }
                .stacklumeButton(prominent: false, compact: compact).accessibilityLabel("Actualizar catálogo")
                .themedHelp("Actualizar el catálogo").disabled(state.isLoading)
        }
    }

    @ViewBuilder private func actionLabel(_ title: String, symbol: String, compact: Bool) -> some View {
        if compact { Image(systemName: symbol).accessibilityLabel(title) }
        else { Label(title, systemImage: symbol) }
    }

    private var presentationControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignSystem.Spacing.md) { viewControl; Spacer(minLength: 4); sizeControl }
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) { viewControl; sizeControl }
        }
    }

    private var viewControl: some View {
        Picker("Vista", selection: $viewPreference) {
            ForEach([LibraryViewMode.list, .grid]) { mode in Label(mode.label, systemImage: mode.icon).tag(mode.rawValue) }
        }
        .pickerStyle(.segmented).fixedSize()
        .accessibilityLabel("Vista del catálogo")
    }

    private var sizeControl: some View {
        ModelCatalogPicker("Muestras", selection: $previewPreference) {
            ForEach(ModelCatalogPreviewSize.allCases) { size in Text(size.title).tag(size.rawValue) }
        }
        .fixedSize().accessibilityLabel("Tamaño de las previsualizaciones")
    }

    private var quickFilterSummary: String {
        let sort = ModelCatalogFilterOptions.sorts(for: provider).first { $0.value == state.filters.sort }?.title
        return [provider == .civitai ? state.filters.civitaiSite.title : nil, sort, state.filters.adultFilter.title,
                provider == .civitai ? (state.filters.types.isEmpty ? nil : "Tipo: " + state.filters.types) : (state.filters.task.isEmpty ? nil : state.filters.task),
                state.filters.baseModels.isEmpty ? nil : "Base: " + state.filters.baseModels].compactMap { $0 }.joined(separator: " · ")
    }

    private func quickFilters(compact: Bool) -> some View {
        let layout = compact
            ? AnyLayout(HStackLayout(alignment: .bottom, spacing: DesignSystem.Spacing.sm))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: DesignSystem.Spacing.xs))
        return layout {
            if provider == .civitai {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    quickField("Tipo", prompt: "Checkpoint, LORA…", text: Binding(get: { state.filters.types }, set: { state.filters.types = $0 }), suggestions: ["Checkpoint", "LORA", "TextualInversion", "VAE", "Controlnet", "Upscaler"])
                    quickField("Familia", prompt: "Base publicada", text: Binding(get: { state.filters.baseModels }, set: { state.filters.baseModels = $0 }), suggestions: Array(Set(state.items.flatMap { $0.versions.compactMap(\.baseModel) })).sorted())
                }
            } else {
                quickField("Tarea", prompt: "Tarea publicada", text: Binding(get: { state.filters.task }, set: { state.filters.task = $0 }), suggestions: Array(Set(state.items.compactMap(\.kind))).sorted())
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignSystem.Spacing.sm) { sortControl; adultControl; if provider == .civitai { originControl } }
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) { sortControl; adultControl; if provider == .civitai { originControl } }
            }
            .fixedSize(horizontal: compact, vertical: false)
        }
    }

    private func quickField(_ title: String, prompt: String, text: Binding<String>, suggestions: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            HStack(spacing: DesignSystem.Spacing.xs) {
                ModelCatalogField(title, text: text, prompt: prompt, showsLabel: false).onSubmit { search() }.accessibilityLabel("Filtrar por \(title.lowercased())")
                Menu {
                    Button("Cualquiera") { text.wrappedValue = ""; search() }
                    ForEach(Array(suggestions.prefix(18)), id: \.self) { value in Button(value) { text.wrappedValue = value; search() } }
                    Divider()
                    Button("Todos los filtros…") { showsFilters = true }
                } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Valores de \(title.lowercased())")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sortControl: some View {
        ModelCatalogPicker("Orden", selection: Binding(get: { state.filters.sort }, set: { value in changeFilters { $0.sort = value } })) {
            ForEach(ModelCatalogFilterOptions.sorts(for: provider), id: \.value) { value in Text(value.title).tag(value.value) }
        }.fixedSize()
    }
    private var adultControl: some View {
        ModelCatalogPicker("Contenido", selection: Binding(get: { state.filters.adultFilter }, set: { value in
            adultPreference = value.rawValue; state.filters.adultFilter = value; favoritesPage = 0
            if !showsFavorites { search() }
        })) { ForEach(ModelCatalogAdultFilter.allCases, id: \.self) { Text($0.title).tag($0) } }.fixedSize()
    }
    private var originControl: some View {
        ModelCatalogPicker("Origen", selection: Binding(get: { state.filters.civitaiSite }, set: { value in changeFilters { $0.civitaiSite = value } })) {
            ForEach(ModelCatalogCivitaiSite.allCases, id: \.self) { Text($0.title).tag($0) }
        }.fixedSize()
    }

    private var results: some View {
        VStack(spacing: 0) {
            if state.isLoading && !state.isLoadingMore {
                ProgressView("Consultando \(provider.title)…")
                    .tint(palette.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = state.error, state.items.isEmpty {
                ContentUnavailableView {
                    Label("No se pudo consultar el catálogo", systemImage: "network.slash")
                } description: { Text(error) } actions: {
                    Button("Reintentar") { search() }.stacklumeButton()
                    Button("Revisar conexión") { showsConnection = true }.stacklumeButton(prominent: false)
                }
            } else if state.visibleItems.isEmpty {
                ContentUnavailableView {
                    Label("Sin modelos para estos filtros", systemImage: "magnifyingglass")
                } description: {
                    Text(state.items.isEmpty ? "Prueba otro nombre, autor o combinación de filtros. Los modelos privados y restringidos dependen de tu cuenta." : "Ningún modelo recibido cumple los filtros locales. Puedes cargar más o consultar la siguiente página.")
                } actions: { Button("Cambiar filtros") { showsFilters = true }.stacklumeButton() }
            } else if viewMode == .grid {
                GeometryReader { geometry in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: previewSize.cardWidth(in: geometry.size.width - 2 * DesignSystem.Spacing.md - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)), maximum: previewSize.maximumCardWidth), spacing: DesignSystem.Spacing.md, alignment: .top)], alignment: .leading, spacing: DesignSystem.Spacing.md) {
                            ForEach(state.visibleItems) { item in resultCard(item, isList: false) }
                        }
                        .padding(DesignSystem.Spacing.md)
                    }
                }
                .accessibilityLabel("Cuadrícula de modelos de \(provider.title)")
            } else {
                List(selection: Binding<String?>(get: { state.selected?.id }, set: { id in state.selected = state.items.first { $0.id == id } })) {
                    ForEach(state.visibleItems) { item in resultCard(item, isList: true).tag(item.id).listRowBackground(palette.background) }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .accessibilityLabel("Lista de modelos de \(provider.title)")
            }
            if let error = state.error, !state.items.isEmpty {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle").stacklumeFont(.caption).foregroundStyle(palette.textPrimary)
                    Button("Reintentar") { paginate { await state.loadMore() } }.stacklumeButton(prominent: false).disabled(state.isLoading)
                }.padding(DesignSystem.Spacing.sm).background(palette.surface)
            }
            pagination
        }
    }

    private func resultCard(_ item: ModelCatalogItem, isList: Bool) -> some View {
        ModelCatalogResultCard(item: item, adultFilter: state.filters.adultFilter, size: previewSize, isList: isList, isSelected: state.selected?.id == item.id, isFavorite: state.isFavorite(item.id), onOpen: { state.selected = item }, onPreview: { samples in
            guard let first = samples.first else { return }
            catalogMedia = .init(provider: provider, title: item.title, media: samples, selectedID: first.id, includeAdult: state.filters.includeAdult, sourceURL: item.bookmarkURL(), adultFilter: state.filters.adultFilter, model: item)
        }, onFavorite: { state.toggleFavorite(item) }, onSave: { saveSelection = .init(item: item, version: nil) })
        .contextMenu {
            Button("Ver detalles") { state.selected = item }
            Button("Organizar/Guardar…") { saveSelection = .init(item: item, version: nil) }
            Button(state.isFavorite(item.id) ? "Quitar favorito del catálogo" : "Añadir favorito del catálogo") { state.toggleFavorite(item) }
            Button("Copiar ficha") { ModelCatalogCopy.text(ModelCatalogCopy.model(item, version: nil)) }
            if let url = item.bookmarkURL() { Link("Abrir en \(provider.title)", destination: url) }
        }
    }

    private var favorites: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            ModelCatalogPicker("Ordenar favoritos", selection: $favoritesOrder) {
                Text("Guardados recientes").tag("recent"); Text("Nombre").tag("name"); Text("Autor").tag("author")
            }.padding(DesignSystem.Spacing.md).onChange(of: favoritesOrder) { _, _ in favoritesPage = 0 }
            Text("Favoritos locales de modelos, muestras y publicaciones. Usa «Organizar/Guardar…» para elegir colección, etiquetas y prioridad. Los modelos consultan su ficha actual; los ejemplos conservan los datos guardados y su fuente original.")
                .stacklumeFont(.caption).foregroundStyle(palette.textSecondary).padding(.horizontal, DesignSystem.Spacing.md)
            if let error = state.favoritesError ?? state.error { Text(error).foregroundStyle(palette.textPrimary).padding() }
            if state.isLoading { ProgressView("Abriendo modelo…").tint(palette.accent) }
            if favoriteMatches.isEmpty { ContentUnavailableView("Sin favoritos para esta selección", systemImage: "star", description: Text("Añade modelos, ejemplos o publicaciones desde su ficha; comprueba también el filtro de contenido.")) }
            else {
                List {
                    ForEach(favoriteMatches.dropFirst(favoritesPage * 30).prefix(30)) { favorite in
                        HStack(spacing: 0) {
                            Button {
                                openFavorite(favorite)
                            } label: {
                                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                                    Text(favorite.title).stacklumeFont(.headline).foregroundStyle(palette.textPrimary)
                                    Text([favorite.author, favorite.modelID, favorite.kind?.title, favorite.provider == .civitai ? favorite.site.title : favorite.provider.title, favorite.contentRating.title].compactMap { $0 }.joined(separator: " · ")).stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).contextMenu {
                                Button("Abrir ficha") { openFavorite(favorite) }
                                Button("Organizar/Guardar…") { openFavorite(favorite, organize: true) }
                                Button("Quitar de favoritos") { state.removeFavorite(favorite) }
                                if let url = favorite.url { Button("Copiar enlace") { ModelCatalogCopy.text(url.absoluteString) }; Link("Fuente original", destination: url) }
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .listRowBackground(palette.surface)
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
            }
            HStack {
                Text("\(favoriteMatches.count) \(favoriteMatches.count == 1 ? "favorito" : "favoritos") · página \(favoritesPage + 1)").stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                Spacer()
                Button("Anterior") { favoritesPage -= 1 }.stacklumeButton(prominent: false).disabled(favoritesPage == 0)
                Button("Siguiente") { favoritesPage += 1 }.stacklumeButton(prominent: false).disabled((favoritesPage + 1) * 30 >= favoriteMatches.count)
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    private var pagination: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignSystem.Spacing.sm) { resultCount; Spacer(minLength: 4); pageSizeControl }
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) { resultCount; pageSizeControl }
            }
            if state.nextURL != nil && !state.canLoadMore {
                Text("Esta vista conserva hasta 300 modelos. «Continuar por páginas» libera los anteriores y consulta el resto; tus favoritos y marcadores permanecen guardados.")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            }
            pageActions
        }
        .padding(DesignSystem.Spacing.sm).background(palette.surface)
    }

    private var pageSizeControl: some View {
        ModelCatalogPicker("Por petición", selection: Binding(get: { state.filters.pageSize }, set: { value in changeFilters { $0.pageSize = value } })) {
            ForEach(ModelCatalogResultWindow.pageSizes, id: \.self) { Text(String($0)).tag($0) }
        }.fixedSize().disabled(state.isLoading)
    }

    private var resultCount: some View {
        let pages = state.firstLoadedPage == state.pageNumber ? "Página \(state.pageNumber)" : "Páginas \(state.firstLoadedPage)–\(state.pageNumber)"
        return Text("\(pages) · \(state.visibleItems.count) visibles · \(state.items.count) recibidos\(state.total.map { " de \($0.formatted())" } ?? "")")
            .stacklumeFont(.caption).foregroundStyle(palette.textSecondary).fixedSize(horizontal: false, vertical: true)
    }

    private var pageActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignSystem.Spacing.xs) { primaryPageAction; Spacer(minLength: 0); otherPageActions }
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) { primaryPageAction; otherPageActions }
        }
    }

    @ViewBuilder private var primaryPageAction: some View {
        if state.isLoadingMore {
            HStack { ProgressView().controlSize(.small).tint(palette.accent); Text("Cargando más…").stacklumeFont(.caption); Button("Cancelar") { paginationTask?.cancel(); state.cancelSearch() }.stacklumeButton(prominent: false) }
        } else if state.canLoadMore {
            Button("Cargar más") { paginate { await state.loadMore() } }.stacklumeButton().disabled(state.isLoading)
        } else if state.nextURL != nil {
            Button("Continuar por páginas") { paginate { await state.nextPage() } }.stacklumeButton().disabled(state.isLoading)
        } else { Text("Sin más páginas publicadas").stacklumeFont(.caption).foregroundStyle(palette.textSecondary) }
    }

    private var otherPageActions: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Button("Anterior") { paginate { await state.previousPage() } }.stacklumeButton(prominent: false).disabled(!state.canGoBack || state.isLoading)
            Button("Siguiente") { paginate { await state.nextPage() } }.stacklumeButton(prominent: false).disabled(state.nextURL == nil || state.isLoading)
            Button("Inicio") { search() }.stacklumeButton(prominent: false).disabled(state.isLoading || state.pageNumber == 1)
        }
    }

    private func detail(_ item: ModelCatalogItem) -> some View {
        ModelCatalogDetailView(state: state, item: item) { model, version in
            saveSelection = .init(item: model, version: version)
        } onBack: { state.selected = nil }
    }
}

struct ModelCatalogSaveSelection: Identifiable {
    let item: ModelCatalogItem
    let version: ModelCatalogVersion?
    var artifact: ModelCatalogFavorite?
    var id: String { artifact?.id ?? item.provider.rawValue + ":" + item.id + ":" + (version?.id ?? "model") }
    var url: URL? { artifact?.url ?? item.bookmarkURL(version: version) }
    var title: String { artifact?.title ?? item.title + (version.map { " · \($0.name)" } ?? "") }
    var details: String? {
        guard let artifact else { return nil }
        let sample = artifact.media
        return [artifact.kind == .widget ? "Ejemplo publicado en la ficha del modelo; comparte su marcador y organización." : "Procedencia: publicación del proveedor", artifact.url?.absoluteString, "Modelo: " + item.id, sample?.url.absoluteString, artifact.post?.body, sample.map { $0.parameters.map { "\($0.name): \($0.value)" }.joined(separator: "\n\n") }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    static func favorite(_ favorite: ModelCatalogFavorite) -> Self { .init(item: favorite.modelSnapshot, version: nil, artifact: favorite.isModel ? nil : favorite) }
}
