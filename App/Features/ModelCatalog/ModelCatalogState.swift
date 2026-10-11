import Foundation
import Observation

@MainActor
@Observable
final class ModelCatalogState {
    let provider: ModelCatalogProvider
    var filters = ModelCatalogFilters()
    var items: [ModelCatalogItem] = []
    var selected: ModelCatalogItem?
    var detail: ModelCatalogItem?
    var revisions: [ModelCatalogVersion] = []
    var readme = ""
    var detailError: String?
    var revisionsError: String?
    var readmeError: String?
    var error: String?
    var isLoading = false
    var isLoadingMore = false
    var firstLoadedPage = 1
    var isDetailLoading = false
    var isRevisionLoading = false
    var revisionDetail: ModelCatalogVersion?
    var revisionModel: ModelCatalogItem?
    var revisionError: String?
    var connectionStatus: ModelCatalogConnectionStatus = .absent
    var connected: Bool { connectionStatus.canUseAccount }
    var connectionError: String?
    var nextURL: URL?
    var pageNumber = 1
    var total: Int?
    var taxonomy: [ModelCatalogTaxonomy] = []
    var taxonomyError: String?
    var isTaxonomyLoading = false
    var favorites: [ModelCatalogFavorite] = []
    var favoritesError: String?

    @ObservationIgnored private var history: [URL] = []
    @ObservationIgnored private var currentURL: URL?
    @ObservationIgnored private var activeFilters = ModelCatalogFilters()
    @ObservationIgnored private var searchID = UUID()
    @ObservationIgnored private var detailID = UUID()
    @ObservationIgnored private var revisionID = UUID()
    @ObservationIgnored private var readmeID = UUID()
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private let client: ModelCatalogClient

    init(provider: ModelCatalogProvider, client: ModelCatalogClient = .shared) {
        self.provider = provider; self.client = client
        filters.adultFilter = ModelCatalogAdultFilter(rawValue: UserDefaults.standard.string(forKey: "stacklume.modelCatalog.adult.\(provider.rawValue)") ?? "") ?? .exclude
        filters.civitaiSite = ModelCatalogCivitaiSite(rawValue: UserDefaults.standard.string(forKey: "stacklume.modelCatalog.site.\(provider.rawValue)") ?? "") ?? .standard
        filters.pageSize = ModelCatalogResultWindow.validatedPageSize(UserDefaults.standard.integer(forKey: "stacklume.modelCatalog.pageSize.\(provider.rawValue)"))
        refreshFavorites()
    }
    var canGoBack: Bool { !history.isEmpty }
    var canLoadMore: Bool { nextURL != nil && ModelCatalogResultWindow.canAppend(count: items.count, pageSize: activeFilters.pageSize) }
    var hasPendingContentFilter: Bool { filters.adultFilter != activeFilters.adultFilter }
    var visibleItems: [ModelCatalogItem] {
        items.filter { filters.adultFilter.allows($0.contentRating, provider: provider) && ModelCatalogDecoding.matchesLocalPermissions($0, filters: activeFilters) }
    }

    func refreshFavorites() {
        do { favorites = try ModelCatalogFavorites.load().filter { $0.provider == provider }; favoritesError = nil }
        catch { favoritesError = error.localizedDescription }
    }

    func isFavorite(_ id: String) -> Bool { favorites.contains { $0.isModel && $0.modelID == id } }

    func toggleFavorite(_ item: ModelCatalogItem) {
        do {
            var entries = try ModelCatalogFavorites.load()
            if let index = entries.firstIndex(where: { $0.isModel && $0.provider == provider && $0.modelID == item.id }) { entries.remove(at: index) }
            else { entries.insert(.init(provider: provider, modelID: item.id, title: item.title, author: item.author, site: item.civitaiSite, createdAt: .now, contentRating: item.contentRating), at: 0) }
            try ModelCatalogFavorites.set(entries); refreshFavorites()
        } catch { favoritesError = error.localizedDescription }
    }

    func removeFavorite(_ favorite: ModelCatalogFavorite) {
        do { try ModelCatalogFavorites.set(try ModelCatalogFavorites.load().filter { $0.id != favorite.id }); refreshFavorites() }
        catch { favoritesError = error.localizedDescription }
    }

    func openFavorite(_ favorite: ModelCatalogFavorite) async {
        let id = UUID(); detailID = id; isLoading = true; error = nil
        do {
            let model = try await client.favoriteDetail(favorite)
            guard detailID == id, !Task.isCancelled else { return }
            selected = model; detail = model
        } catch { if detailID == id, !Task.isCancelled { self.error = error.localizedDescription } }
        if detailID == id { isLoading = false }
    }

    func refreshConnection() async {
        let value = await client.connectionStatus(provider)
        guard !Task.isCancelled else { return }
        applyConnectionStatus(value)
        guard connectionTask == nil else { return }
        let client = client, provider = provider
        connectionTask = Task { [weak self] in
            let changes = await client.connectionChanges(provider)
            for await status in changes {
                guard !Task.isCancelled, let self else { break }
                let newlyAvailable = !self.connected && status.canUseAccount
                self.applyConnectionStatus(status)
                if newlyAvailable { self.search() }
            }
        }
    }

    private func applyConnectionStatus(_ value: ModelCatalogConnectionStatus) {
        connectionStatus = value
        connectionError = value == .unavailable ? ModelCatalogError.keychain.localizedDescription : nil
        if !connected { for flag in ["favorites", "hidden", "followed"] { filters.flags[flag] = nil } }
    }

    func stopConnectionUpdates() {
        connectionTask?.cancel(); connectionTask = nil
    }

    deinit { connectionTask?.cancel() }

    func reload() async {
        let request = beginReload()
        await performReload(requestID: request.id, snapshot: request.filters)
    }

    private func beginReload() -> (id: UUID, filters: ModelCatalogFilters) {
        searchTask?.cancel()
        let requestID = UUID(); searchID = requestID
        isLoading = true; isLoadingMore = false; error = nil
        return (requestID, filters)
    }

    private func performReload(requestID: UUID, snapshot: ModelCatalogFilters) async {
        guard searchID == requestID, !Task.isCancelled else { return }
        await refreshConnection()
        guard searchID == requestID, !Task.isCancelled else { return }
        activeFilters = snapshot
        UserDefaults.standard.set(snapshot.adultFilter.rawValue, forKey: "stacklume.modelCatalog.adult.\(provider.rawValue)")
        UserDefaults.standard.set(snapshot.civitaiSite.rawValue, forKey: "stacklume.modelCatalog.site.\(provider.rawValue)")
        UserDefaults.standard.set(snapshot.pageSize, forKey: "stacklume.modelCatalog.pageSize.\(provider.rawValue)")
        if !connected { for flag in ["favorites", "hidden", "followed"] { activeFilters.flags[flag] = nil } }
        history = []; pageNumber = 1; firstLoadedPage = 1
        selected = nil; detail = nil
        do { currentURL = try ModelCatalogRequest.searchURL(provider: provider, filters: activeFilters) }
        catch { self.error = error.localizedDescription; isLoading = false; return }
        await loadPage(requestID: requestID)
    }

    @discardableResult
    func search() -> Task<Void, Never> {
        let request = beginReload()
        let task = Task { await performReload(requestID: request.id, snapshot: request.filters) }
        searchTask = task
        return task
    }

    func nextPage() async {
        if hasPendingContentFilter { await reload(); return }
        guard !isLoading, let nextURL, let currentURL else { return }
        if history.count >= 100 { history.removeFirst() }
        history.append(currentURL); self.currentURL = nextURL; pageNumber += 1
        selected = nil; detail = nil; firstLoadedPage = pageNumber
        let requestID = UUID(); searchID = requestID
        await loadPage(requestID: requestID)
    }

    func previousPage() async {
        if hasPendingContentFilter { await reload(); return }
        guard !isLoading, let previous = history.popLast() else { return }
        currentURL = previous; pageNumber = max(1, pageNumber - 1)
        selected = nil; detail = nil; firstLoadedPage = pageNumber
        let requestID = UUID(); searchID = requestID
        await loadPage(requestID: requestID)
    }

    private func loadPage(requestID: UUID) async {
        guard searchID == requestID, !Task.isCancelled else { return }
        isLoading = true; error = nil; nextURL = nil
        let snapshot = activeFilters
        let url = currentURL
        do {
            let page = try await client.search(provider: provider, filters: snapshot, pageURL: url)
            guard searchID == requestID, !Task.isCancelled else { return }
            guard page.items.count <= ModelCatalogResultWindow.validatedPageSize(snapshot.pageSize) else { throw ModelCatalogError.tooLarge }
            items = page.items; nextURL = page.nextURL; total = page.total
        } catch is CancellationError { }
        catch { if searchID == requestID { self.error = error.localizedDescription; items = [] } }
        if searchID == requestID { isLoading = false }
    }

    func loadMore() async {
        if hasPendingContentFilter { await reload(); return }
        guard !isLoading, canLoadMore, let target = nextURL, let current = currentURL else { return }
        let id = UUID(); searchID = id
        isLoading = true; isLoadingMore = true; error = nil
        let snapshot = activeFilters
        do {
            let page = try await client.search(provider: provider, filters: snapshot, pageURL: target)
            guard searchID == id, !Task.isCancelled else { return }
            guard page.items.count <= ModelCatalogResultWindow.validatedPageSize(snapshot.pageSize) else { throw ModelCatalogError.tooLarge }
            let merged = try ModelCatalogResultWindow.appending(page.items, to: items)
            if history.count >= 100 { history.removeFirst() }
            history.append(current); currentURL = target; pageNumber += 1
            items = merged; nextURL = page.nextURL; total = page.total ?? total
        } catch is CancellationError { }
        catch { if searchID == id, !Task.isCancelled { self.error = error.localizedDescription } }
        if searchID == id { isLoading = false; isLoadingMore = false }
    }

    func cancelSearch() {
        searchTask?.cancel(); searchID = UUID()
        isLoading = false; isLoadingMore = false
    }

    func loadDetail(_ item: ModelCatalogItem) async {
        let requestID = UUID(); detailID = requestID
        detail = item; isDetailLoading = true; detailError = nil
        revisions = []; readme = ""; revisionsError = nil; readmeError = nil
        revisionDetail = nil; revisionModel = nil; revisionError = nil; isRevisionLoading = false
        revisionID = UUID(); clearReadme()
        do {
            let result = try await client.detail(item)
            guard detailID == requestID, !Task.isCancelled else { return }
            detail = result
        } catch is CancellationError { return }
        catch { if detailID == requestID { detailError = error.localizedDescription } }
        guard detailID == requestID, !Task.isCancelled else { return }
        isDetailLoading = false
        if provider == .huggingFace {
            do {
                let result = try await client.revisions(item)
                guard detailID == requestID, !Task.isCancelled else { return }
                revisions = result
            } catch is CancellationError { return }
            catch { if detailID == requestID { revisionsError = error.localizedDescription } }
        }
    }

    func loadReadme(_ item: ModelCatalogItem, revision: String) async {
        let requestID = UUID(); readmeID = requestID
        readmeError = nil
        do {
            let value = try await client.readme(item, revision: revision)
            guard readmeID == requestID, !Task.isCancelled else { return }
            readme = value
        } catch is CancellationError { }
        catch { if readmeID == requestID { readmeError = error.localizedDescription } }
    }

    func clearReadme() { readmeID = UUID(); readme = ""; readmeError = nil }

    func loadRevision(_ version: ModelCatalogVersion?, item: ModelCatalogItem) async {
        let requestID = UUID(); revisionID = requestID
        revisionDetail = nil; revisionModel = nil; revisionError = nil; isRevisionLoading = false
        clearReadme()
        guard let version else { return }
        isRevisionLoading = true
        do {
            if item.provider == .civitai {
                let result = try await client.civitaiVersion(item, version: version)
                guard revisionID == requestID, !Task.isCancelled else { return }
                revisionDetail = result
            } else {
            let detail = try await client.revision(item, version: version)
            guard revisionID == requestID, !Task.isCancelled else { return }
            guard let metadata = detail.versions.first else { throw ModelCatalogError.invalidResponse }
            revisionModel = detail
            revisionDetail = ModelCatalogVersion(id: version.id, name: version.name, revision: metadata.revision, baseModel: metadata.baseModel, createdAt: metadata.createdAt, description: metadata.description, trainedWords: metadata.trainedWords, files: metadata.files, previews: metadata.previews, rawMetadata: metadata.rawMetadata ?? detail.rawMetadata)
            }
        } catch is CancellationError { return }
        catch { if revisionID == requestID { revisionError = error.localizedDescription } }
        if revisionID == requestID { isRevisionLoading = false }
    }

    func loadTaxonomy() async {
        guard taxonomy.isEmpty, !isTaxonomyLoading else { return }
        isTaxonomyLoading = true; taxonomyError = nil
        do { taxonomy = try await client.taxonomy() }
        catch { taxonomyError = error.localizedDescription }
        isTaxonomyLoading = false
    }
}

@MainActor
@Observable
final class ModelCatalogCommunityState {
    let item: ModelCatalogItem
    let versionID: String?
    let includeAdult: Bool
    var adultFilter: ModelCatalogAdultFilter
    var kind: ModelCatalogCommunityKind
    var filters = ModelCatalogCommunityFilters()
    var page = ModelCatalogCommunityPage()
    var isLoading = false
    var error: String?
    var pageNumber = 1
    @ObservationIgnored private var history: [URL] = []
    @ObservationIgnored private var currentURL: URL?
    @ObservationIgnored private var activeFilters = ModelCatalogCommunityFilters()
    @ObservationIgnored private var activeKind: ModelCatalogCommunityKind
    @ObservationIgnored private var activeAdultFilter: ModelCatalogAdultFilter
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let client: ModelCatalogClient

    init(item: ModelCatalogItem, versionID: String?, includeAdult: Bool, client: ModelCatalogClient = .shared, adultFilter: ModelCatalogAdultFilter? = nil) {
        self.item = item; self.versionID = versionID; self.includeAdult = includeAdult; self.client = client
        self.adultFilter = adultFilter ?? (includeAdult ? .all : .exclude)
        activeAdultFilter = adultFilter ?? (includeAdult ? .all : .exclude)
        let initialKind: ModelCatalogCommunityKind = item.provider == .civitai ? .images : .spaces
        kind = initialKind; activeKind = initialKind
    }
    var canGoBack: Bool { !history.isEmpty }
    var hasPendingContentFilter: Bool { adultFilter != activeAdultFilter }
    var visibleMedia: [ModelCatalogPreview] {
        page.media.filter {
            adultFilter.allows($0.contentRating, provider: item.provider)
                && (item.provider != .civitai || !filters.requiringMetadata || !$0.parameters.isEmpty)
        }
    }

    func reload() async {
        task?.cancel(); let id = UUID(); requestID = id; isLoading = true
        await performReload(id: id, kind: kind, filters: filters, adultFilter: adultFilter)
    }
    @discardableResult func search() -> Task<Void, Never> {
        task?.cancel(); let id = UUID(); requestID = id; isLoading = true
        let kind = kind, filters = filters, policy = adultFilter
        let next = Task { await performReload(id: id, kind: kind, filters: filters, adultFilter: policy) }; task = next; return next
    }
    private func performReload(id: UUID, kind: ModelCatalogCommunityKind, filters: ModelCatalogCommunityFilters, adultFilter: ModelCatalogAdultFilter) async {
        guard requestID == id, !Task.isCancelled else { return }
        activeKind = kind; activeFilters = filters; activeAdultFilter = adultFilter; history = []; pageNumber = 1; page = .init(); error = nil
        do { currentURL = try ModelCatalogRequest.communityURL(provider: item.provider, modelID: item.id, versionID: versionID, kind: kind, filters: filters, includeAdult: includeAdult, adultFilter: adultFilter, site: item.civitaiSite) }
        catch { self.error = error.localizedDescription; isLoading = false; return }
        await load(id: id)
    }
    func nextPage() async {
        if hasPendingContentFilter { await reload(); return }
        guard !isLoading, let next = page.nextURL, let currentURL else { return }
        if history.count >= 100 { history.removeFirst() }
        history.append(currentURL); self.currentURL = next; pageNumber += 1
        let id = UUID(); requestID = id; await load(id: id)
    }
    func previousPage() async {
        if hasPendingContentFilter { await reload(); return }
        guard !isLoading, let previous = history.popLast() else { return }
        currentURL = previous; pageNumber = max(1, pageNumber - 1)
        let id = UUID(); requestID = id; await load(id: id)
    }
    func cancel() { task?.cancel(); requestID = UUID() }
    private func load(id: UUID) async {
        guard requestID == id, !Task.isCancelled else { return }
        isLoading = true; error = nil
        do {
            let result = try await client.community(item, versionID: versionID, kind: activeKind, filters: activeFilters, includeAdult: includeAdult, pageURL: currentURL, adultFilter: activeAdultFilter)
            guard requestID == id, !Task.isCancelled else { return }
            page = result
        } catch is CancellationError { }
        catch { if requestID == id { self.error = error.localizedDescription; page = .init() } }
        if requestID == id { isLoading = false }
    }
}
