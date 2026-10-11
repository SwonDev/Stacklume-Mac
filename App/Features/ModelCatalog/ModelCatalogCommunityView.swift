import SwiftUI
import StacklumeDesignSystem

struct ModelCatalogCommunityView: View {
    let item: ModelCatalogItem
    let version: ModelCatalogVersion?
    let includeAdult: Bool
    var adultFilter: ModelCatalogAdultFilter?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @Environment(\.appTheme) private var theme
    @State private var state: ModelCatalogCommunityState
    @State private var selectedPost: ModelCatalogPost?
    @AppStorage private var adultPreference: String

    init(item: ModelCatalogItem, version: ModelCatalogVersion?, includeAdult: Bool, adultFilter: ModelCatalogAdultFilter? = nil) {
        self.item = item; self.version = version; self.includeAdult = includeAdult
        self.adultFilter = adultFilter
        _state = State(initialValue: ModelCatalogCommunityState(item: item, versionID: version?.id, includeAdult: includeAdult, adultFilter: adultFilter))
        _adultPreference = AppStorage(wrappedValue: (adultFilter ?? (includeAdult ? .all : .exclude)).rawValue, "stacklume.modelCatalog.adult.\(item.provider.rawValue)")
    }
    var body: some View {
        EditorScaffold(title: "Comunidad · \(item.title)", confirmTitle: "Cerrar", cancelTitle: nil, onCancel: { dismiss() }, onConfirm: { dismiss() }) {
            VStack(spacing: 0) {
                controls.padding(DesignSystem.Spacing.md)
                Divider().overlay(palette.border)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                        if state.isLoading {
                            ProgressView("Consultando \(state.kind.title.lowercased())…").tint(palette.accent).padding(DesignSystem.Spacing.lg)
                        } else if let error = state.error {
                            ContentUnavailableView {
                                Label("No se pudo consultar la comunidad", systemImage: "network.slash")
                            } description: { Text(error) } actions: { Button("Reintentar") { state.search() }.stacklumeButton() }
                        } else {
                            if item.provider == .civitai {
                                if state.visibleMedia.isEmpty { emptyState }
                                else { ModelCatalogMediaGrid(media: state.visibleMedia, provider: item.provider, title: item.title + (version.map { " · \($0.name)" } ?? ""), includeAdult: state.adultFilter != .exclude, adultFilter: state.adultFilter, model: item) }
                                if state.page.unavailableMediaCount > 0 {
                                    Text("\(state.page.unavailableMediaCount) muestras no se pueden cargar desde una fuente multimedia permitida.").stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                                }
                            } else {
                                if state.page.posts.isEmpty { emptyState }
                                ForEach(state.page.posts) { post in
                                    Button { selectedPost = post } label: { ModelCatalogPostRow(post: post, provider: item.provider, adultFilter: state.adultFilter) }
                                        .buttonStyle(.plain).themedHelp("Leer la ficha y sus ejemplos dentro de Stacklume")
                                }
                            }
                        }
                    }
                    .padding(DesignSystem.Spacing.lg)
                }
                pagination.padding(DesignSystem.Spacing.md).background(palette.surface)
            }
        }
        .frame(minWidth: 480, idealWidth: 1_000, maxWidth: 1_280, minHeight: 480, idealHeight: 760, maxHeight: 1_000)
        .task { state.adultFilter = ModelCatalogAdultFilter(rawValue: adultPreference) ?? .exclude; await state.reload() }
        .onChange(of: adultPreference) { _, value in state.adultFilter = ModelCatalogAdultFilter(rawValue: value) ?? .exclude }
        .onDisappear { state.cancel() }
        .onExitCommand { dismiss() }
        .sheet(item: $selectedPost) { post in
            ModelCatalogPostDetailView(item: item, post: post, includeAdult: includeAdult, adultFilter: adultFilter).themedSheet(palette, theme)
        }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            if item.provider == .huggingFace {
                Picker("Fuente de comunidad", selection: $state.kind) {
                    Text("Spaces vinculados").tag(ModelCatalogCommunityKind.spaces)
                    Text("Conversaciones").tag(ModelCatalogCommunityKind.discussions)
                }
                .pickerStyle(.segmented)
                .onChange(of: state.kind) { _, _ in state.filters.sort = ""; state.search() }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignSystem.Spacing.sm) { sort; periodOrStatus; mediaOrType }
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) { sort; periodOrStatus; mediaOrType }
            }
            HStack(spacing: DesignSystem.Spacing.sm) {
                ModelCatalogField("Autor de la comunidad", text: $state.filters.author).onSubmit { state.search() }
                if item.provider == .huggingFace { ModelCatalogField("Buscar en esta fuente", text: $state.filters.query).onSubmit { state.search() } }
                Button("Aplicar") { state.search() }.stacklumeButton().disabled(state.isLoading)
            }
            ModelCatalogPicker("Contenido", selection: $adultPreference) { ForEach(ModelCatalogAdultFilter.allCases, id: \.self) { Text($0.title).tag($0.rawValue) } }
            if state.hasPendingContentFilter { Text("El filtro ya se aplica a las muestras recibidas. Pulsa Aplicar para consultar nuevas páginas con esta clasificación.").stacklumeFont(.caption).foregroundStyle(palette.textSecondary) }
            if item.provider == .civitai {
                Toggle("Solo muestras con parámetros publicados", isOn: $state.filters.requiringMetadata)
                if version == nil { Text("Selecciona una versión del modelo para ordenar por reacciones, comentarios o guardados; Civitai ordena los ejemplos del modelo completo por fecha.").stacklumeFont(.caption).foregroundStyle(palette.textSecondary) }
                Text("La visibilidad y la clasificación dependen de los ajustes y permisos de tu cuenta de Civitai. El visor conserva el filtro elegido.")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            } else {
                Text(state.kind == .spaces ? "Aplicaciones que declaran este modelo en Hugging Face. Puedes leer su ficha y ver sus muestras aquí." : "Conversaciones reales del repositorio; sus autores pueden compartir ejemplos y adjuntos.")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            }
        }
    }
    private var sort: some View {
        ModelCatalogPicker("Orden", selection: $state.filters.sort) {
            if item.provider == .civitai {
                if version != nil {
                    Text("Más reacciones").tag(""); Text("Más comentarios").tag("Most Comments"); Text("Más guardadas").tag("Most Collected")
                }
                Text("Más recientes").tag(version == nil ? "" : "Newest")
            } else if state.kind == .spaces {
                Text("Más me gusta").tag(""); Text("Tendencias").tag("trendingScore"); Text("Actualización").tag("lastModified"); Text("Creación").tag("createdAt")
            } else {
                Text("Más recientes").tag(""); Text("Tendencias").tag("trending"); Text("Reacciones").tag("reactions")
            }
        }
    }
    @ViewBuilder private var periodOrStatus: some View {
        if item.provider == .civitai {
            ModelCatalogPicker("Periodo", selection: $state.filters.period) {
                Text("Todo").tag("AllTime"); Text("Año").tag("Year"); Text("Mes").tag("Month"); Text("Semana").tag("Week"); Text("Día").tag("Day")
            }
        } else if state.kind == .discussions {
            ModelCatalogPicker("Estado", selection: $state.filters.status) {
                Text("Todos").tag("all"); Text("Abiertas").tag("open"); Text("Cerradas").tag("closed")
            }
        }
    }
    @ViewBuilder private var mediaOrType: some View {
        if item.provider == .civitai {
            ModelCatalogPicker("Muestras", selection: $state.filters.mediaType) {
                Text("Imágenes y vídeos").tag(""); Text("Imágenes").tag("image"); Text("Vídeos").tag("video")
            }
        } else if state.kind == .discussions {
            ModelCatalogPicker("Tipo", selection: $state.filters.discussionType) {
                Text("Todos").tag("all"); Text("Conversaciones").tag("discussion"); Text("Pull requests").tag("pull_request")
            }
        }
    }
    private var emptyState: some View {
        ContentUnavailableView("Sin publicaciones para estos filtros", systemImage: "person.2", description: Text("Prueba otra versión, autor o combinación de filtros. El proveedor puede limitar la visibilidad según tu cuenta."))
    }
    private var pagination: some View {
        ViewThatFits(in: .horizontal) {
            HStack { count; Spacer(); pageButtons }
            VStack(spacing: DesignSystem.Spacing.xs) { count; pageButtons }
        }
    }
    private var count: some View {
        Text("Página \(state.pageNumber) · \(item.provider == .civitai ? state.visibleMedia.count : state.page.posts.count) publicaciones\(state.page.total.map { " de \($0.formatted())" } ?? "")")
            .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
    }
    private var pageButtons: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Button("Anterior") { Task { await state.previousPage() } }.stacklumeButton(prominent: false).disabled(!state.canGoBack || state.isLoading)
            Button("Siguiente") { Task { await state.nextPage() } }.stacklumeButton(prominent: false).disabled(state.page.nextURL == nil || state.isLoading)
        }
    }
}

struct ModelCatalogPostRow: View {
    let post: ModelCatalogPost
    let provider: ModelCatalogProvider
    @Environment(\.themePalette) private var palette
    @AppStorage private var adultPreference: String

    init(post: ModelCatalogPost, provider: ModelCatalogProvider, adultFilter: ModelCatalogAdultFilter? = nil) {
        self.post = post; self.provider = provider
        _adultPreference = AppStorage(wrappedValue: (adultFilter ?? .exclude).rawValue, "stacklume.modelCatalog.adult.\(provider.rawValue)")
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            if let media = post.representativePreview(provider: provider, adultFilter: ModelCatalogAdultFilter(rawValue: adultPreference) ?? .exclude) {
                ModelCatalogMediaThumbnail(media: media).frame(width: 112, height: 84).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(post.title).stacklumeFont(.headline).foregroundStyle(palette.textPrimary).fixedSize(horizontal: false, vertical: true)
                Text([post.author, post.sdk, post.status, post.comments.map { "\($0) comentarios" }, post.likes.map { "\($0.formatted()) me gusta" }, post.createdAt].compactMap { $0 }.joined(separator: " · "))
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                if !post.body.isEmpty { Text(post.body).stacklumeFont(.callout).foregroundStyle(palette.textSecondary).stacklumeLineLimit(4) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DesignSystem.Spacing.md).background(palette.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ModelCatalogPostDetailView: View {
    let item: ModelCatalogItem
    let post: ModelCatalogPost
    let includeAdult: Bool
    var adultFilter: ModelCatalogAdultFilter?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @State private var comments: [ModelCatalogPost] = []
    @State private var readme = ""
    @State private var readmeRevision = "main"
    @State private var fullMetadata: Data?
    @State private var sourceContentRating: ModelCatalogContentRating?
    @State private var isLoading = false
    @State private var error: String?
    @State private var reloadID = UUID()
    @State private var commentPage = 0
    @State private var metadataSelection: ModelCatalogMetadataSelection?
    @Environment(\.appTheme) private var theme
    private let commentsPerPage = 30
    private var visibleComments: [ModelCatalogPost] { Array(comments.dropFirst(commentPage * commentsPerPage).prefix(commentsPerPage)) }
    private var savedPost: ModelCatalogPost {
        var snapshot = sourceContentRating.map { post.applyingContentRating($0) } ?? post
        snapshot.rawMetadata = fullMetadata ?? post.rawMetadata
        if !readme.isEmpty { snapshot.body = readme }
        return snapshot
    }
    var body: some View {
        EditorScaffold(title: post.title, confirmTitle: "Cerrar", cancelTitle: nil, onCancel: { dismiss() }, onConfirm: { dismiss() }) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    ModelCatalogPostRow(post: savedPost, provider: item.provider, adultFilter: adultFilter)
                    ModelCatalogArtifactActions(favorite: .publication(savedPost, model: item))
                    Link("Abrir fuente original", destination: post.url).themedHelp("Abrir esta publicación en Hugging Face")
                    Button("Copiar publicación") { ModelCatalogCopy.text([post.title, post.url.absoluteString, post.body, readme].filter { !$0.isEmpty }.joined(separator: "\n\n")) }.stacklumeButton(prominent: false)
                    if let data = fullMetadata ?? post.rawMetadata {
                        Button("Metadatos de publicación") { metadataSelection = .init(title: "Metadatos · \(post.title)", data: data, sourceURL: post.url) }.stacklumeButton(prominent: false)
                    }
                    if !post.body.isEmpty { Text(post.body).textSelection(.enabled) }
                    if post.unavailableMediaCount > 0 {
                        Text("Algunos adjuntos no proceden de una fuente multimedia permitida. Puedes consultar la publicación original.").stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                    }
                    if !savedPost.media.isEmpty { ModelCatalogMediaGrid(media: savedPost.media, provider: item.provider, title: post.title, includeAdult: includeAdult, adultFilter: adultFilter, model: item) }
                    if isLoading { ProgressView("Cargando publicación…").tint(palette.accent) }
                    if let error {
                        Text(error).foregroundStyle(palette.textPrimary)
                        Button("Reintentar") { reloadID = UUID() }.stacklumeButton(prominent: false)
                    }
                    if !readme.isEmpty {
                        Text("Ficha README").stacklumeFont(.headline)
                        let examples = ModelCatalogDecoding.markdownMediaResult(readme, source: post.url, revision: readmeRevision, rating: savedPost.contentRating ?? .unknown, author: post.author, rawMetadata: fullMetadata ?? post.rawMetadata)
                        if !examples.media.isEmpty { ModelCatalogMediaGrid(media: examples.media, provider: item.provider, title: post.title, includeAdult: includeAdult, sourceURL: post.url, adultFilter: adultFilter, model: item) }
                        if examples.unavailableCount > 0 { Text("\(examples.unavailableCount) referencias multimedia no se pueden cargar desde una fuente permitida. Se conservan en el README.").stacklumeFont(.caption).foregroundStyle(palette.textSecondary) }
                        Text(readme).stacklumeFont(.callout).textSelection(.enabled)
                    }
                    if !comments.isEmpty {
                        HStack {
                            Text("\(comments.count) comentarios visibles · \(comments.reduce(0) { $0 + $1.media.count }) adjuntos multimedia").stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                            Spacer()
                            Button("Anterior") { commentPage -= 1 }.stacklumeButton(prominent: false).disabled(commentPage == 0)
                            Text("Página \(commentPage + 1)").stacklumeFont(.caption).monospacedDigit()
                            Button("Siguiente") { commentPage += 1 }.stacklumeButton(prominent: false).disabled((commentPage + 1) * commentsPerPage >= comments.count)
                        }
                    }
                    ForEach(visibleComments) { comment in
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                            Text([comment.author, comment.createdAt].compactMap { $0 }.joined(separator: " · ")).stacklumeFont(.caption.weight(.semibold)).foregroundStyle(palette.textSecondary)
                            Text(comment.body).textSelection(.enabled)
                            ModelCatalogArtifactActions(favorite: .publication(comment, model: item))
                            HStack {
                                Button("Copiar comentario") { ModelCatalogCopy.text(comment.body) }.stacklumeButton(prominent: false)
                                if let data = comment.rawMetadata { Button("Metadatos") { metadataSelection = .init(title: "Metadatos del comentario", data: data, sourceURL: comment.url) }.stacklumeButton(prominent: false) }
                            }
                            if !comment.media.isEmpty { ModelCatalogMediaGrid(media: comment.media, provider: item.provider, title: post.title, includeAdult: includeAdult, adultFilter: adultFilter, model: item) }
                            if comment.unavailableMediaCount > 0 { Text("\(comment.unavailableMediaCount) adjuntos no tienen una fuente multimedia permitida.").stacklumeFont(.caption).foregroundStyle(palette.textSecondary) }
                            Divider().overlay(palette.border)
                        }
                    }
                    if !isLoading, error == nil, post.number != nil, comments.isEmpty { Text("Esta conversación no tiene comentarios visibles para tu cuenta.").foregroundStyle(palette.textSecondary) }
                }
                .foregroundStyle(palette.textPrimary).padding(DesignSystem.Spacing.lg)
            }
        }
        .frame(minWidth: 480, idealWidth: 920, maxWidth: 1_200, minHeight: 440, idealHeight: 740, maxHeight: 1_000)
        .onExitCommand { dismiss() }
        .sheet(item: $metadataSelection) { selection in ModelCatalogMetadataView(selection: selection).themedSheet(palette, theme) }
        .task(id: reloadID) {
            isLoading = true; error = nil
            do {
                if post.number != nil {
                    let data = try await ModelCatalogClient.shared.discussionDetails(item, post: post)
                    let result = try ModelCatalogDecoding.discussionComments(data: data, source: post.url)
                    guard !Task.isCancelled else { return }; comments = result; commentPage = 0; fullMetadata = data
                } else if post.url.path.hasPrefix("/spaces/") {
                    let metadata = try await ModelCatalogClient.shared.spaceMetadata(post)
                    let source = try await Task.detached { try ModelCatalogDecoding.huggingFaceRepositoryMetadata(data: metadata) }.value
                    try Task.checkCancellation()
                    fullMetadata = metadata; readmeRevision = source.revision; sourceContentRating = source.contentRating
                    let result = try await ModelCatalogClient.shared.spaceReadme(post, revision: source.revision)
                    guard !Task.isCancelled else { return }; readme = result
                }
            } catch is CancellationError { return }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            isLoading = false
        }
    }
}
