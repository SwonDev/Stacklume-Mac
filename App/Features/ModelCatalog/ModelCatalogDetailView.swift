import SwiftUI
import StacklumeDesignSystem

struct ModelCatalogDetailView: View {
    @Bindable var state: ModelCatalogState
    let item: ModelCatalogItem
    let onSave: (ModelCatalogItem, ModelCatalogVersion?) -> Void
    let onBack: () -> Void
    @Environment(\.themePalette) private var palette
    @Environment(\.appTheme) private var theme
    @State private var versionID: String?
    @State private var showsVersions = false
    @State private var versionQuery = ""
    @State private var showReadme = false
    @State private var loadingReadme = false
    @State private var fileQuery = ""
    @State private var showsCommunity = false
    @State private var selectedExample: ModelCatalogPost?
    @State private var metadataSelection: ModelCatalogMetadataSelection?
    @State private var downloadSelection: ModelCatalogDownloadSelection?
    @State private var copied = false
    @State private var fileLimit = 100

    private var model: ModelCatalogItem {
        if state.revisionDetail?.id == versionID, let revision = state.revisionModel { return revision }
        return state.detail ?? item
    }
    private var selectedMetadataVersion: ModelCatalogVersion? { versionID == nil ? nil : shownVersion }
    private var versions: [ModelCatalogVersion] {
        var values = (state.detail ?? item).versions
        if model.provider == .huggingFace {
            values += state.revisions.filter { revision in !values.contains { $0.id == revision.id } }
        }
        return values
    }
    private var version: ModelCatalogVersion? { versions.first { $0.id == versionID } }
    private var shownVersion: ModelCatalogVersion? {
        if let revision = state.revisionDetail, revision.id == versionID { return revision }
        return version ?? versions.first
    }
    private var files: [ModelCatalogFile] { shownVersion?.files ?? [] }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                HStack {
                    Button(action: onBack) { Label("Resultados", systemImage: "chevron.left") }
                        .stacklumeButton(prominent: false).themedHelp("Volver a los resultados")
                    Spacer()
                    if state.isDetailLoading { ProgressView().controlSize(.small).accessibilityLabel("Cargando detalles") }
                }
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text(model.title).stacklumeFont(.title2.weight(.bold)).foregroundStyle(palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Text([model.author, model.kind, model.library].compactMap { $0 }.joined(separator: " · "))
                        .stacklumeFont(.subheadline).foregroundStyle(palette.textSecondary).textSelection(.enabled)
                    if model.isPrivate { Label("Repositorio privado", systemImage: "lock") }
                    if let gated = model.gated { Label("Acceso restringido: \(gated)", systemImage: "hand.raised") }
                    if let availability = model.availability { Text("Disponibilidad: \(availability)") }
                }
                .foregroundStyle(palette.textPrimary)
                actions
                if let error = state.favoritesError { message(error) }
                if let error = state.detailError { message(error) }
                metadata
                previews
                community
                if !model.examples.isEmpty {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        sectionTitle("Ejemplos de la ficha del proveedor")
                        ForEach(model.examples) { example in
                            Button { selectedExample = example } label: { ModelCatalogPostRow(post: example, provider: model.provider, adultFilter: state.filters.adultFilter) }
                                .buttonStyle(.plain).themedHelp("Ver la entrada y la salida publicadas de este ejemplo")
                        }
                    }
                }
                if model.metadataMatches(version: selectedMetadataVersion), !model.description.isEmpty {
                    sectionTitle("Descripción")
                    Text(model.description).foregroundStyle(palette.textPrimary).textSelection(.enabled)
                }
                if !versions.isEmpty { versionDetails }
                if !model.tags(for: selectedMetadataVersion).isEmpty {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        sectionTitle("Etiquetas del proveedor")
                        Text(model.tags(for: selectedMetadataVersion).joined(separator: " · ")).stacklumeFont(.callout)
                            .foregroundStyle(palette.textSecondary).textSelection(.enabled)
                    }
                }
                licenses
                fileSection
                if model.provider == .huggingFace { readmeSection }
            }
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.background)
        .task(id: item.id) {
            versionID = nil; showReadme = false; fileQuery = ""
            await state.loadDetail(item)
        }
        .task(id: versionID) { await state.loadRevision(version, item: item) }
        .sheet(isPresented: $showsCommunity) {
            ModelCatalogCommunityView(item: model, version: version == nil ? nil : shownVersion, includeAdult: state.filters.includeAdult, adultFilter: state.filters.adultFilter)
                .themedSheet(palette, theme)
        }
        .sheet(item: $downloadSelection) { selection in ModelCatalogDownloadSheet(selection: selection).themedSheet(palette, theme) }
        .sheet(item: $metadataSelection) { selection in ModelCatalogMetadataView(selection: selection).themedSheet(palette, theme) }
        .sheet(item: $selectedExample) { example in
            ModelCatalogPostDetailView(item: model, post: example, includeAdult: state.filters.includeAdult, adultFilter: state.filters.adultFilter).themedSheet(palette, theme)
        }
        .sheet(isPresented: $showsVersions) {
            EditorScaffold(title: model.provider == .huggingFace ? "Revisiones del repositorio" : "Versiones del modelo", confirmTitle: "Hecho", cancelTitle: nil, onCancel: { showsVersions = false }, onConfirm: { showsVersions = false }) {
                VStack(spacing: DesignSystem.Spacing.sm) {
                    ModelCatalogField("Buscar versión o revisión", text: $versionQuery)
                        .padding(.horizontal, DesignSystem.Spacing.md)
                    List {
                        Button("Modelo completo") { versionID = nil; showsVersions = false }
                        ForEach(versions.filter { versionQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(versionQuery) || ($0.revision?.localizedCaseInsensitiveContains(versionQuery) ?? false) }) { version in
                            Button {
                                versionID = version.id; showReadme = false; state.clearReadme()
                                showsVersions = false
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(version.name)
                                    if let base = version.baseModel { Text(base).stacklumeFont(.caption).foregroundStyle(palette.textSecondary) }
                                    if let commit = version.revision { Text(commit).stacklumeFont(.caption).foregroundStyle(palette.textSecondary).stacklumeLineLimit(1) }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.plain)
                }
                .padding(.vertical, DesignSystem.Spacing.md)
            }
            .frame(minWidth: 340, idealWidth: 480, maxWidth: 580, minHeight: 380, idealHeight: 520, maxHeight: 660)
            .themedSheet(palette, theme)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignSystem.Spacing.sm) { saveButton; providerLink }
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) { saveButton; providerLink }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignSystem.Spacing.sm) { personalActions }
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) { personalActions }
            }
        }
    }

    @ViewBuilder private var personalActions: some View {
        Button { state.toggleFavorite(model) } label: { Label(state.isFavorite(model.id) ? "Favorito del catálogo" : "Añadir a favoritos", systemImage: state.isFavorite(model.id) ? "star.fill" : "star") }
            .stacklumeButton(prominent: false).themedHelp("Favorito local de este catálogo; no modifica tu cuenta del proveedor")
        Button(copied ? "Copiado" : "Copiar ficha") { ModelCatalogCopy.text(ModelCatalogCopy.model(model, version: selectedMetadataVersion)); copied = true }
            .stacklumeButton(prominent: false).themedHelp("Copiar el contenido y la fuente de esta selección")
        if let data = model.rawMetadata {
            Button("Metadatos del modelo") { metadataSelection = .init(title: "Metadatos · \(model.title)", data: data, sourceURL: model.bookmarkURL()) }
                .stacklumeButton(prominent: false).themedHelp("Examinar y copiar todos los campos recibidos del modelo")
        }
        if let version = shownVersion, let data = version.rawMetadata {
            Button("Metadatos de versión") { metadataSelection = .init(title: "Metadatos · \(version.name)", data: data, sourceURL: model.bookmarkURL(version: version)) }
                .stacklumeButton(prominent: false)
        }
    }

    private var saveButton: some View {
        Button(version == nil ? "Guardar modelo…" : "Guardar versión…") { onSave(model, version == nil ? nil : shownVersion) }
            .stacklumeButton().disabled(state.isDetailLoading || state.isRevisionLoading)
    }

    @ViewBuilder private var providerLink: some View {
        if let url = model.bookmarkURL(version: version == nil ? nil : shownVersion) {
            Link(destination: url) { Label("Abrir en \(model.provider.title)", systemImage: "arrow.up.right.square") }
                .stacklumeButton(prominent: false).themedHelp("Abrir la página del proveedor en el navegador")
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            if let count = model.downloads { Label("\(count.formatted()) descargas", systemImage: "arrow.down.circle") }
            if let count = model.likes { Label("\(count.formatted()) favoritos o me gusta", systemImage: "heart") }
            if let modified = model.lastModified { Text("Actualizado: \(modified)").textSelection(.enabled) }
        }
        .stacklumeFont(.callout).foregroundStyle(palette.textSecondary)
    }

    @ViewBuilder private var previews: some View {
        let previews = shownVersion?.previews ?? model.versions.flatMap(\.previews)
        if previews.isEmpty {
            Label("El proveedor no devuelve una muestra visual apta para esta selección.", systemImage: "photo")
                .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                sectionTitle("Muestras del proveedor")
                ModelCatalogMediaGrid(media: previews, provider: model.provider, title: model.title + (shownVersion.map { " · \($0.name)" } ?? ""), includeAdult: state.filters.includeAdult, limit: 6, sourceURL: model.bookmarkURL(version: version == nil ? nil : shownVersion), adultFilter: state.filters.adultFilter, model: model)
            }
        }
    }

    private var community: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            sectionTitle("Comunidad")
            Button { showsCommunity = true } label: {
                Label(model.provider == .civitai ? "Ver imágenes y vídeos de la comunidad" : "Ver Spaces y conversaciones", systemImage: "person.2")
            }
            .stacklumeButton(prominent: false).themedHelp("Consultar publicaciones reales vinculadas a este modelo")
            Text(model.provider == .civitai ? "Explora muestras del modelo o de la versión elegida, con los parámetros que publiquen sus autores." : "Consulta aplicaciones vinculadas y ejemplos compartidos en las conversaciones del repositorio.")
                .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
        }
    }

    private var versionDetails: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            sectionTitle(model.provider == .huggingFace ? "Revisión" : "Versión")
            Button { versionQuery = ""; showsVersions = true } label: {
                Label(version?.name ?? "Modelo completo · \(versions.count) \(versions.count == 1 ? "versión o revisión" : "versiones o revisiones")", systemImage: "chevron.up.chevron.down")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .stacklumeButton(prominent: false)
            if let error = state.revisionsError { message(error) }
            if state.isRevisionLoading { ProgressView("Consultando la revisión…") }
            if let error = state.revisionError { message(error) }
            if let shownVersion {
                if let revision = shownVersion.revision { Text("Commit: \(revision)").stacklumeFont(.caption).textSelection(.enabled) }
                if let base = shownVersion.baseModel { Text("Modelo base: \(base)") }
                if let date = shownVersion.createdAt { Text("Fecha: \(date)").stacklumeFont(.caption) }
                if !shownVersion.description.isEmpty { Text(shownVersion.description).textSelection(.enabled) }
                if !shownVersion.trainedWords.isEmpty {
                    Text("Palabras de activación: \(shownVersion.trainedWords.joined(separator: ", "))").textSelection(.enabled)
                }
            }
        }
        .foregroundStyle(palette.textPrimary)
    }

    private var licenses: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            sectionTitle("Licencia y permisos")
            if model.provider == .huggingFace {
                let licenses = model.licenses(for: selectedMetadataVersion)
                Text(!model.metadataMatches(version: selectedMetadataVersion) ? "No se ha podido comprobar la licencia de esta revisión. Consulta la ficha del proveedor." : licenses.isEmpty ? "El proveedor no ha especificado una licencia en los metadatos. Consulta la ficha y los archivos del repositorio." : licenses.joined(separator: ", "))
                    .textSelection(.enabled)
            } else {
                permission("Uso sin atribución", value: model.allowsNoCredit)
                permission("Obras derivadas", value: model.allowsDerivatives)
                permission("Licencias diferentes", value: model.allowsDifferentLicenses)
                Text("Uso comercial: \(model.commercialUses.isEmpty ? "No especificado" : model.commercialUses.joined(separator: ", "))")
            }
            Text("Estos datos proceden del proveedor; consulta los términos completos antes de utilizar el modelo.")
                .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
        }
        .foregroundStyle(palette.textPrimary)
    }

    private var fileSection: some View {
        DisclosureGroup("Archivos de la versión (\(files.count))") {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                ModelCatalogField("Buscar archivo", text: $fileQuery)
                if files.isEmpty { Text("El proveedor no ha devuelto archivos para esta selección.") }
                let matches = files.filter { fileQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(fileQuery) }
                ForEach(matches.prefix(fileLimit)) { file in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.name).stacklumeFont(.callout).textSelection(.enabled)
                        Text([file.format, file.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }, file.scan.map { "Análisis: \($0)" }].compactMap { $0 }.joined(separator: " · "))
                            .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                        if let shownVersion, let selection = ModelCatalogDownloadSelection.file(file, model: model, version: shownVersion) {
                            Button("Descargar archivo…") { downloadSelection = selection }.stacklumeButton(prominent: false).themedHelp("Elegir destino y descargar este archivo a disco")
                        } else { Text("El proveedor no ha publicado una dirección de descarga válida para este archivo.").stacklumeFont(.caption).foregroundStyle(palette.textSecondary) }
                        if let data = file.rawMetadata {
                            Button("Metadatos del archivo") { metadataSelection = .init(title: "Metadatos · \(file.name)", data: data, sourceURL: model.bookmarkURL(version: shownVersion)) }.stacklumeButton(prominent: false)
                        }
                    }
                }
                if matches.count > fileLimit { Button("Mostrar los siguientes 100 archivos") { fileLimit += 100 }.stacklumeButton(prominent: false) }
                Text("\(min(fileLimit, matches.count)) archivos de \(matches.count) coincidencias. Las descargas se guardan solo cuando eliges un destino.")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            }
            .padding(.top, DesignSystem.Spacing.sm)
        }
        .foregroundStyle(palette.textPrimary)
        .onChange(of: fileQuery) { _, _ in fileLimit = 100 }
    }

    private var readmeSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Button(showReadme ? "Ocultar ficha README" : "Leer ficha README") {
                if showReadme { showReadme = false }
                else {
                    showReadme = true; loadingReadme = true
                    Task {
                        await state.loadReadme(model, revision: shownVersion?.revision ?? "main")
                        loadingReadme = false
                    }
                }
            }
            .stacklumeButton(prominent: false)
            if showReadme {
                if loadingReadme { ProgressView("Cargando ficha…") }
                if let error = state.readmeError { message(error) }
                if !state.readme.isEmpty {
                    if let source = model.bookmarkURL(version: shownVersion) {
                        let examples = ModelCatalogDecoding.markdownMediaResult(state.readme, source: source, rating: model.contentRating, author: model.author)
                        if !examples.media.isEmpty { ModelCatalogMediaGrid(media: examples.media, provider: model.provider, title: "Ejemplos de la ficha README", includeAdult: state.filters.includeAdult, sourceURL: source, adultFilter: state.filters.adultFilter, model: model) }
                        if examples.unavailableCount > 0 { Text("\(examples.unavailableCount) referencias multimedia no se pueden cargar desde una fuente permitida. Se conservan en el README.").stacklumeFont(.caption).foregroundStyle(palette.textSecondary) }
                    }
                    Text(state.readme).stacklumeFont(.callout).foregroundStyle(palette.textPrimary).textSelection(.enabled)
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).stacklumeFont(.headline).foregroundStyle(palette.textPrimary).accessibilityAddTraits(.isHeader)
    }
    private func message(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle").stacklumeFont(.caption).foregroundStyle(palette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func permission(_ label: String, value: Bool?) -> some View {
        Text("\(label): \(value.map { $0 ? "Permitido" : "No permitido" } ?? "No especificado")")
    }
}
