import SwiftUI
import AppKit
import AVKit
import ImageIO
import StacklumeDesignSystem

struct ModelCatalogGallerySelection: Identifiable {
    let id = UUID()
    let provider: ModelCatalogProvider
    let title: String
    var media: [ModelCatalogPreview]
    let selectedID: String
    let includeAdult: Bool
    var sourceURL: URL?
    var adultFilter: ModelCatalogAdultFilter?
    var model: ModelCatalogItem?
}

struct ModelCatalogMediaGrid: View {
    let media: [ModelCatalogPreview]
    let provider: ModelCatalogProvider
    let title: String
    let includeAdult: Bool
    var limit = 30
    var sourceURL: URL?
    var adultFilter: ModelCatalogAdultFilter?
    var model: ModelCatalogItem?
    @Environment(\.themePalette) private var palette
    @Environment(\.appTheme) private var theme
    @State private var selection: ModelCatalogGallerySelection?
    @AppStorage private var adultPreference: String
    private var policy: ModelCatalogAdultFilter { ModelCatalogAdultFilter(rawValue: adultPreference) ?? .exclude }
    private var visible: [ModelCatalogPreview] { media.filter { policy.allows($0.contentRating, provider: provider) } }

    init(media: [ModelCatalogPreview], provider: ModelCatalogProvider, title: String, includeAdult: Bool, limit: Int = 30, sourceURL: URL? = nil, adultFilter: ModelCatalogAdultFilter? = nil, model: ModelCatalogItem? = nil) {
        self.media = media; self.provider = provider; self.title = title; self.includeAdult = includeAdult
        self.limit = limit; self.sourceURL = sourceURL; self.adultFilter = adultFilter; self.model = model
        _adultPreference = AppStorage(wrappedValue: (adultFilter ?? (includeAdult ? .all : .exclude)).rawValue, "stacklume.modelCatalog.adult.\(provider.rawValue)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            if visible.isEmpty { Text("Ninguna muestra recibida cumple el filtro de contenido actual.").stacklumeFont(.caption).foregroundStyle(palette.textSecondary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: DesignSystem.Spacing.sm)], spacing: DesignSystem.Spacing.sm) {
                ForEach(visible.prefix(limit)) { sample in
                    ModelCatalogMediaCell(media: sample, provider: provider) { open(sample) }
                }
            }
            if visible.count > limit, let first = visible.first {
                Button("Ver las \(visible.count) muestras en grande") { open(first) }.stacklumeButton(prominent: false)
            }
        }
        .sheet(item: $selection) { selection in
            ModelCatalogGalleryView(selection: selection).themedSheet(palette, theme)
        }
        .onChange(of: media) { _, updated in
            guard var active = selection else { return }
            active.media = updated
            selection = active
        }
    }
    private func open(_ sample: ModelCatalogPreview) {
        selection = .init(provider: provider, title: title, media: media, selectedID: sample.id, includeAdult: policy != .exclude, sourceURL: sourceURL, adultFilter: policy, model: model)
    }
}

private struct ModelCatalogMediaCell: View {
    let media: ModelCatalogPreview
    let provider: ModelCatalogProvider
    let onOpen: () -> Void
    @Environment(\.themePalette) private var palette
    @State private var imageError: String?
    @State private var retryRevision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 6) {
                    ModelCatalogMediaThumbnail(media: media, provider: provider, retryRevision: retryRevision) { imageError = $0 }
                        .frame(height: 156).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
                    Text(media.author ?? (media.title.isEmpty ? "Muestra del proveedor" : media.title))
                        .stacklumeFont(.caption).foregroundStyle(palette.textPrimary).stacklumeLineLimit(2)
                    if media.kind != .image {
                        Label(media.kind == .video ? "Vídeo" : "Audio", systemImage: media.kind == .video ? "play.circle" : "waveform")
                            .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                    }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ampliar \(media.title.isEmpty ? "muestra" : media.title)\(media.author.map { " de \($0)" } ?? "")")
            .themedHelp("Abrir la muestra en el visor grande")
            if imageError != nil {
                Button("Reintentar miniatura") {
                    for url in ModelCatalogPreviewCandidates(media: media, provider: provider).urls { SecureImageCache.shared.retry(for: url) }
                    retryRevision &+= 1
                }
                .buttonStyle(.borderless).themedHelp("Reintentar la miniatura sin abrir el visor")
            }
        }
    }
}

struct ModelCatalogMediaThumbnail: View {
    let media: ModelCatalogPreview
    var provider: ModelCatalogProvider?
    var retryRevision = 0
    var onError: (String?) -> Void = { _ in }
    @Environment(\.themePalette) private var palette
    @State private var storage = SecureRemoteImageStorage()
    @State private var hasImage = false
    @State private var isLoading = false
    @State private var error: String?
    private var candidates: [URL] { ModelCatalogPreviewCandidates(media: media, provider: provider).urls }
    private struct LoadID: Hashable { let candidates: [URL]; let revision: Int }
    var body: some View {
        ZStack {
            palette.surface
            if hasImage { SecureRemoteImageRenderer(storage: storage) }
            else if isLoading { ProgressView().tint(palette.accent) }
            else {
                VStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: media.kind == .video ? "play.rectangle" : media.kind == .audio ? "waveform" : "photo")
                        .font(.title).foregroundStyle(palette.textSecondary)
                    if let error {
                        Text(error).stacklumeFont(.caption2).foregroundStyle(palette.textSecondary).stacklumeLineLimit(3)
                    } else {
                        Text(media.kind == .image ? "Sin imagen disponible" : "Sin miniatura publicada")
                            .stacklumeFont(.caption2).foregroundStyle(palette.textSecondary)
                    }
                }.padding(DesignSystem.Spacing.sm)
            }
        }
        .task(id: LoadID(candidates: candidates, revision: retryRevision)) { await load() }
        .onDisappear { storage.setImage(nil); hasImage = false; isLoading = false }
    }

    private func load() async {
        guard !Task.isCancelled else { return }
        storage.setImage(nil); hasImage = false
        isLoading = !candidates.isEmpty; error = nil; onError(nil)
        defer { if !Task.isCancelled { isLoading = false } }
        for url in candidates where !ModelCatalogRequest.mayAuthenticateMediaURL(url) {
            if let cached = await SecureImageCache.shared.storedImage(for: url, maxPixels: 640) {
                guard !Task.isCancelled else { return }; storage.setImage(cached); hasImage = true; return
            }
        }
        for url in candidates {
            do {
                if let loaded = try await ModelCatalogImageLoader.image(for: url, maximumPixels: 640) {
                    try Task.checkCancellation(); storage.setImage(loaded); hasImage = true; return
                }
                error = SecureImageCache.shared.failureDescription(for: url) ?? "La muestra recibida no ha cargado."
            } catch is CancellationError { return }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        if !Task.isCancelled { onError(error) }
    }
}

struct ModelCatalogGalleryView: View {
    let selection: ModelCatalogGallerySelection
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @State private var selectedID: String
    @AppStorage private var adultPreference: String
    @State private var zoom = 1.0
    @State private var zoomRequest = 0
    @State private var fitRequest = 0
    @State private var showsInformation = true
    @State private var metadataSelection: ModelCatalogMetadataSelection?
    @State private var downloadSelection: ModelCatalogDownloadSelection?
    @Environment(\.appTheme) private var theme
    private var policy: ModelCatalogAdultFilter { ModelCatalogAdultFilter(rawValue: adultPreference) ?? .exclude }
    private var media: [ModelCatalogPreview] { selection.media.filter { policy.allows($0.contentRating, provider: selection.provider) } }
    private var index: Int { media.firstIndex { $0.id == selectedID } ?? -1 }
    private var sample: ModelCatalogPreview? { media.first { $0.id == selectedID } }

    init(selection: ModelCatalogGallerySelection) {
        self.selection = selection
        _selectedID = State(initialValue: selection.selectedID)
        _adultPreference = AppStorage(wrappedValue: (selection.adultFilter ?? (selection.includeAdult ? .all : .exclude)).rawValue, "stacklume.modelCatalog.adult.\(selection.provider.rawValue)")
    }

    var body: some View {
        EditorScaffold(title: selection.title, confirmTitle: "Cerrar", cancelTitle: nil, onCancel: { dismiss() }, onConfirm: { dismiss() }) {
            VStack(spacing: DesignSystem.Spacing.sm) {
                controls.padding(.horizontal, DesignSystem.Spacing.md)
                ModelCatalogPicker("Contenido en este visor", selection: $adultPreference) {
                    ForEach(ModelCatalogAdultFilter.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }.padding(.horizontal, DesignSystem.Spacing.md)
                Text("Filtra las muestras recibidas en esta selección. Para consultar otras páginas o clasificaciones, vuelve al catálogo o a la comunidad.")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary).padding(.horizontal, DesignSystem.Spacing.md)
                if let sample {
                    if sample.kind == .image {
                        ModelCatalogLargeImage(media: sample, provider: selection.provider, zoom: $zoom, zoomRequest: $zoomRequest, fitRequest: fitRequest)
                            .id(sample.id).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ModelCatalogSamplePlayer(media: sample, provider: selection.provider)
                            .id(sample.id).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if showsInformation {
                        ScrollView {
                            information(sample).padding(.horizontal, DesignSystem.Spacing.lg).padding(.vertical, DesignSystem.Spacing.sm)
                        }
                        .frame(maxHeight: 190)
                    }
                } else {
                    ContentUnavailableView("La muestra está oculta por este filtro", systemImage: "photo", description: Text("Cambia el contenido permitido o pasa a otra muestra. La selección se conserva para volver a verla cuando el filtro lo permita."))
                }
            }
            .padding(.top, DesignSystem.Spacing.sm)
        }
        .presentationSizing(.fitted)
        .frame(minWidth: 480, idealWidth: 1_060, maxWidth: 1_400, minHeight: 480, idealHeight: 780, maxHeight: 1_100)

        .onExitCommand { dismiss() }
        .sheet(item: $downloadSelection) { selection in ModelCatalogDownloadSheet(selection: selection).themedSheet(palette, theme) }
        .sheet(item: $metadataSelection) { selection in ModelCatalogMetadataView(selection: selection).themedSheet(palette, theme) }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignSystem.Spacing.sm) { navigation; Spacer(); sizeControls }
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) { navigation; sizeControls }
        }
    }
    private var navigation: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Button { change(-1) } label: { Label("Anterior", systemImage: "chevron.left") }
                .stacklumeButton(prominent: false).disabled(index <= 0).keyboardShortcut(.leftArrow, modifiers: [])
                .themedHelp("Muestra anterior · flecha izquierda")
            Text("\(index + 1) de \(media.count)").stacklumeFont(.caption).monospacedDigit().foregroundStyle(palette.textSecondary)
            Button { change(1) } label: { Label("Siguiente", systemImage: "chevron.right") }
                .stacklumeButton(prominent: false).disabled(index + 1 >= media.count).keyboardShortcut(.rightArrow, modifiers: [])
                .themedHelp("Muestra siguiente · flecha derecha")
        }
    }
    private var sizeControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignSystem.Spacing.xs) { zoomControls; sampleActions }
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) { zoomControls; sampleActions }
        }
    }
    private var zoomControls: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            if sample?.kind == .image {
                Button { zoom = max(0.05, zoom / 1.25); zoomRequest &+= 1 } label: { Image(systemName: "minus.magnifyingglass") }
                    .stacklumeButton(prominent: false).accessibilityLabel("Reducir tamaño").themedHelp("Reducir la imagen")
                Button("Ajustar") { zoomRequest &+= 1; fitRequest = zoomRequest }
                    .stacklumeButton(prominent: false).themedHelp("Ajustar la imagen a la ventana")
                Button("100 %") { zoom = 1; zoomRequest &+= 1 }
                    .stacklumeButton(prominent: false).themedHelp("Un píxel de la imagen decodificada por píxel de pantalla")
                Text("\(Int((zoom * 100).rounded())) %").stacklumeFont(.caption).monospacedDigit()
                    .foregroundStyle(palette.textSecondary).accessibilityLabel("Zoom actual").accessibilityValue("\(Int((zoom * 100).rounded())) %")
                Button { zoom = min(8, zoom * 1.25); zoomRequest &+= 1 } label: { Image(systemName: "plus.magnifyingglass") }
                    .stacklumeButton(prominent: false).accessibilityLabel("Ampliar tamaño").themedHelp("Ampliar la imagen")
            }
            Button { showsInformation.toggle() } label: { Label("Información", systemImage: "info.circle") }
                .stacklumeButton(prominent: false).themedHelp("Mostrar autor, fuente y parámetros publicados")
        }
    }
    @ViewBuilder private var sampleActions: some View {
        if let sample {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Button("Copiar parámetros") { ModelCatalogCopy.text(sample.parameters.map { "\($0.name): \($0.value)" }.joined(separator: "\n\n")) }
                    .stacklumeButton(prominent: false).disabled(sample.parameters.isEmpty)
                if let data = sample.rawMetadata {
                    Button("Metadatos") { metadataSelection = .init(title: "Metadatos de la muestra", data: data, sourceURL: sample.sourceURL ?? selection.sourceURL) }
                        .stacklumeButton(prominent: false)
                }
                if let download = ModelCatalogDownloadSelection.sample(sample, provider: selection.provider) {
                    Button("Descargar…") { downloadSelection = download }.stacklumeButton(prominent: false).themedHelp("Guardar esta muestra en el destino elegido")
                }
            }
            if let model = selection.model { ModelCatalogArtifactActions(favorite: .sample(sample, model: model)) }
            }
        }
    }
    private func change(_ direction: Int) { guard !media.isEmpty else { return }; selectedID = media[min(max(0, index + direction), media.count - 1)].id; zoom = 1; zoomRequest &+= 1; fitRequest = zoomRequest }
    private func information(_ sample: ModelCatalogPreview) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if !sample.title.isEmpty { Text(sample.title).stacklumeFont(.headline).textSelection(.enabled) }
                    Text([sample.author.map { "Autor: \($0)" }, sample.width.flatMap { w in sample.height.map { "\(w) × \($0) px" } }, sample.createdAt].compactMap { $0 }.joined(separator: " · "))
                        .stacklumeFont(.caption).foregroundStyle(palette.textSecondary).textSelection(.enabled)
                    if !sample.versionIDs.isEmpty { Text("Versiones: \(sample.versionIDs.joined(separator: ", "))").stacklumeFont(.caption).textSelection(.enabled) }
                    Text("Clasificación publicada: \(sample.contentRating.title)").stacklumeFont(.caption)
                }
                Spacer(minLength: 4)
                if let source = sample.sourceURL ?? selection.sourceURL {
                    Link("Fuente original", destination: source).themedHelp("Abrir la publicación original en el proveedor")
                }
            }
            if sample.parameters.isEmpty {
                Text("No se han recibido parámetros de generación para esta muestra.").stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            } else {
                ForEach(sample.parameters) { parameter in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(parameter.name).stacklumeFont(.caption.weight(.semibold)).foregroundStyle(palette.textSecondary)
                        Text(parameter.value).stacklumeFont(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .foregroundStyle(palette.textPrimary)
    }
}

private struct ModelCatalogLargeImage: View {
    let media: ModelCatalogPreview
    let provider: ModelCatalogProvider
    @Binding var zoom: Double
    @Binding var zoomRequest: Int
    let fitRequest: Int
    @Environment(\.themePalette) private var palette
    @State private var image: PlatformImage?
    @State private var isLoading = true
    @State private var error: String?
    @State private var usedFallback = false
    @State private var retryRevision = 0
    private var candidates: [URL] {
        var seen = Set<URL>()
        return [media.fullSizeURL, media.originalURL, media.url, media.thumbnailURL].compactMap { $0 }.filter {
            ModelCatalogRequest.mediaURL($0.absoluteString, provider: provider, kind: .image) != nil && seen.insert($0).inserted
        }
    }
    private struct LoadID: Hashable { let candidates: [URL]; let revision: Int }

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            if let image {
                ModelCatalogImageCanvas(image: image, zoom: $zoom, zoomRequest: $zoomRequest, fitRequest: fitRequest,
                                        background: NSColor(palette.surface))
                if usedFallback {
                    HStack {
                        Text("Se muestra otra previsualización recibida; la imagen original no ha cargado.")
                            .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                        Button("Reintentar original", action: retry).stacklumeButton(prominent: false).disabled(isLoading)
                    }.padding(.horizontal, DesignSystem.Spacing.sm)
                }
            } else if isLoading { ProgressView("Cargando muestra grande…").tint(palette.accent).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                ContentUnavailableView {
                    Label("No se pudo cargar la imagen", systemImage: "photo")
                } description: {
                    Text(error ?? "La fuente puede requerir acceso adicional o no estar disponible.")
                } actions: {
                    Button("Reintentar", action: retry).stacklumeButton(prominent: false)
                }
            }
        }
        .background(palette.surface)
        .task(id: LoadID(candidates: candidates, revision: retryRevision)) {
            isLoading = true; error = nil
            for (index, url) in candidates.enumerated() {
                do {
                    guard let value = try await ModelCatalogImageLoader.image(for: url) else {
                        error = SecureImageCache.shared.failureDescription(for: url) ?? "La imagen recibida no está disponible."
                        continue
                    }
                    try Task.checkCancellation()
                    image = value; usedFallback = index > 0; isLoading = false
                    return
                } catch is CancellationError { return }
                catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
            guard !Task.isCancelled else { return }
            isLoading = false
        }
    }

    private func retry() {
        for url in candidates { SecureImageCache.shared.retry(for: url) }
        retryRevision &+= 1
    }
}

@MainActor enum ModelCatalogImageLoader {
    static func image(for url: URL, maximumPixels: Int = 4_096) async throws -> PlatformImage? {
        guard ModelCatalogRequest.mayAuthenticateMediaURL(url) else { return await SecureImageCache.shared.image(for: url, maxPixels: maximumPixels) }
        let data = try await ModelCatalogClient.shared.sampleImageData(url)
        try Task.checkCancellation()
        guard let image = await ModelCatalogImageDecoder.shared.decode(data, maximumPixels: maximumPixels)
        else { throw ModelCatalogError.invalidResponse }
        try Task.checkCancellation()
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

private actor ModelCatalogImageDecoder {
    static let shared = ModelCatalogImageDecoder()

    func decode(_ data: Data, maximumPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(4_096, max(1, maximumPixels)),
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}

private struct ModelCatalogSamplePlayer: View {
    let media: ModelCatalogPreview
    let provider: ModelCatalogProvider
    @Environment(\.themePalette) private var palette
    @State private var player: AVPlayer?
    @State private var sampleURL: URL?
    @State private var task: Task<Void, Never>?
    @State private var isLoading = false
    @State private var error: String?
    var body: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            if let player { VideoPlayer(player: player).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                Image(systemName: media.kind == .video ? "play.rectangle" : "waveform").font(.largeTitle).foregroundStyle(palette.textSecondary)
                if isLoading { ProgressView("Preparando la muestra…").tint(palette.accent) }
                else { Button(media.kind == .video ? "Ver vídeo" : "Escuchar audio", action: prepare).stacklumeButton() }
                Text("Reproducción nativa bajo demanda. Las muestras se limitan a 64 MiB y los vídeos a 4096 px.").stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                if let error { Text(error).stacklumeFont(.callout).foregroundStyle(palette.textPrimary) }
            }
        }
        .padding(DesignSystem.Spacing.md).background(palette.surface)
        .onDisappear { task?.cancel(); cleanup() }
    }
    private func prepare() {
        task?.cancel(); isLoading = true; error = nil
        task = Task {
            do {
                let file = try await ModelCatalogClient.shared.sampleFile(media, provider: provider)
                if Task.isCancelled { ModelCatalogTemporaryMedia.remove(file); throw CancellationError() }
                sampleURL = file
                let asset = AVURLAsset(url: file)
                guard try await asset.load(.isPlayable) else { throw ModelCatalogError.unsupportedMedia }
                if media.kind == .video, let track = try await asset.loadTracks(withMediaType: .video).first {
                    let size = try await track.load(.naturalSize)
                    guard size.width <= 4_096, size.height <= 4_096 else { throw ModelCatalogError.mediaTooLarge }
                }
                try Task.checkCancellation()
                let next = AVPlayer(playerItem: AVPlayerItem(asset: asset)); next.allowsExternalPlayback = false
                next.pause(); player = next
            } catch { cleanup(); if !Task.isCancelled, !(error is CancellationError) { self.error = error.localizedDescription } }
            isLoading = false
        }
    }
    private func cleanup() {
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        if let sampleURL { ModelCatalogTemporaryMedia.remove(sampleURL) }; sampleURL = nil
    }
}
