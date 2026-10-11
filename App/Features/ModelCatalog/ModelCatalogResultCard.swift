import SwiftUI
import StacklumeDesignSystem

struct ModelCatalogResultCard: View {
    let item: ModelCatalogItem
    let adultFilter: ModelCatalogAdultFilter
    let size: ModelCatalogPreviewSize
    var isList = false
    let isSelected: Bool
    let isFavorite: Bool
    let onOpen: () -> Void
    let onPreview: ([ModelCatalogPreview]) -> Void
    let onFavorite: () -> Void
    let onSave: () -> Void
    @Environment(\.themePalette) private var palette
    @State private var imageError: String?
    @State private var retryRevision = 0
    private var candidates: ModelCatalogCoverCandidates { .init(item: item, adultFilter: adultFilter) }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Button(action: onOpen) {
                if isList {
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                        cover.frame(width: size.rowPreviewSize, height: size.rowPreviewSize)
                        information()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                } else {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        information(includeDetails: false)
                        cover.frame(height: size.previewHeight)
                        information(includeIdentity: false)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain).accessibilityLabel("Abrir ficha de \(item.title)")
            .accessibilityValue(accessibilitySummary)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            if let imageError {
                Text(imageError).stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DesignSystem.Spacing.sm) {
                Button(action: onFavorite) { Image(systemName: isFavorite ? "star.fill" : "star") }
                    .foregroundStyle(isFavorite ? palette.readableAccent(on: palette.surface, minimumContrast: 3) : palette.textSecondary)
                    .accessibilityLabel(isFavorite ? "Quitar favorito \(item.title)" : "Añadir favorito \(item.title)")
                    .themedHelp(isFavorite ? "Quitar de favoritos del catálogo" : "Añadir a favoritos del catálogo")
                Button(action: onSave) { Image(systemName: "folder.badge.plus") }
                    .accessibilityLabel("Organizar o guardar \(item.title)").themedHelp("Elegir colección, etiquetas y prioridad")
                if !candidates.media.isEmpty {
                    Button { onPreview(candidates.media) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .accessibilityLabel("Ampliar muestras de \(item.title)").themedHelp("Abrir las muestras en el visor")
                }
                if imageError != nil {
                    Button {
                        for url in candidates.urls { SecureImageCache.shared.retry(for: url) }
                        retryRevision &+= 1
                    } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Reintentar imagen de \(item.title)").themedHelp("Reintentar los candidatos publicados")
                }
                Spacer(minLength: 0)
                if !isList { Text(item.contentRating.title).stacklumeFont(.caption2).foregroundStyle(palette.textSecondary).stacklumeLineLimit(2) }
            }
            .buttonStyle(.borderless)
        }
        .padding(isList ? DesignSystem.Spacing.sm : DesignSystem.Spacing.md)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(isSelected ? palette.readableAccent(on: palette.surface, minimumContrast: 3) : palette.border, lineWidth: isSelected ? 2 : 1) }
        .accessibilityElement(children: .contain)
    }

    private var cover: some View {
        ModelCatalogResultCover(item: item, candidates: candidates, retryRevision: retryRevision) { imageError = $0 }
            .frame(maxWidth: .infinity).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Muestra de \(item.title)")
    }

    private func information(includeIdentity: Bool = true, includeDetails: Bool = true) -> some View {
        let info = ModelCatalogResultSummary(item: item)
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            if includeIdentity { Text(item.title).stacklumeFont(.headline).foregroundStyle(palette.textPrimary).stacklumeLineLimit(2) }
            if includeDetails, let author = item.author { Text(author).stacklumeFont(.subheadline).foregroundStyle(palette.textSecondary).stacklumeLineLimit(1) }
            if includeIdentity {
                Text("Tipo: \(info.kind ?? "No incluido")").stacklumeFont(.caption).foregroundStyle(palette.textPrimary)
                if let base = info.baseModel { Text("Base: \(base)").stacklumeFont(.caption.weight(.semibold)).foregroundStyle(palette.readableAccent(on: palette.surface)) }
                else { Text("Base no incluida").stacklumeFont(.caption).foregroundStyle(palette.textSecondary) }
            }
            if includeDetails {
                if let version = info.versionLabel { Text("Primera \(version.prefix(1).lowercased())\(version.dropFirst())").stacklumeFont(.caption).foregroundStyle(palette.textSecondary).stacklumeLineLimit(2) }
                if let others = info.otherBasesLabel { Text(others).stacklumeFont(.caption).foregroundStyle(palette.textSecondary).stacklumeLineLimit(2) }
                if info.otherVersionCount > 0 { Text("\(info.otherVersionCount) \(info.otherVersionCount == 1 ? "versión adicional" : "versiones adicionales") en la ficha").stacklumeFont(.caption2).foregroundStyle(palette.textSecondary) }
                Text([item.downloads.map { "\($0.formatted()) descargas" }, item.likes.map { "\($0.formatted()) me gusta" }, item.isPrivate ? "Privado" : nil, item.gated != nil ? "Restringido" : nil].compactMap { $0 }.joined(separator: " · "))
                    .stacklumeFont(.caption2).foregroundStyle(palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var accessibilitySummary: String {
        let info = ModelCatalogResultSummary(item: item)
        return [item.author, "Tipo: " + (info.kind ?? "No incluido"), info.baseModel.map { "Base: " + $0 }, info.versionLabel, info.otherBasesLabel]
            .compactMap { $0 }.joined(separator: ". ")
    }
}

private struct ModelCatalogResultCover: View {
    let item: ModelCatalogItem
    let candidates: ModelCatalogCoverCandidates
    let retryRevision: Int
    let onError: (String?) -> Void
    @Environment(\.themePalette) private var palette
    @State private var storage = SecureRemoteImageStorage()
    @State private var hasImage = false
    @State private var loading = false
    private var loadID: String { candidates.urls.map(\.absoluteString).joined(separator: "|") + ":\(retryRevision)" }

    var body: some View {
        ZStack {
            palette.background
            if hasImage { SecureRemoteImageRenderer(storage: storage) }
            else if loading { ProgressView().tint(palette.accent) }
            else {
                VStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: candidates.media.contains { $0.kind == .video } ? "play.rectangle" : item.provider.symbol).font(.title)
                    Text(candidates.urls.isEmpty ? (candidates.media.isEmpty ? "Sin muestra en estos resultados" : "Muestra sin miniatura publicada") : "Muestra no disponible")
                        .stacklumeFont(.caption).multilineTextAlignment(.center)
                }
                .foregroundStyle(palette.textSecondary).padding(DesignSystem.Spacing.sm)
            }
        }
        .task(id: loadID) { await load() }
        .onDisappear { storage.setImage(nil); hasImage = false; loading = false }
    }

    private func load() async {
        guard !Task.isCancelled else { return }
        storage.setImage(nil); hasImage = false; onError(nil); loading = !candidates.urls.isEmpty
        defer { if !Task.isCancelled { loading = false } }
        // La caché pública no se consulta para rutas privadas /resolve/ del Hub.
        for url in candidates.urls where !ModelCatalogRequest.mayAuthenticateMediaURL(url) {
            if let cached = await SecureImageCache.shared.storedImage(for: url, maxPixels: 640) {
                guard !Task.isCancelled else { return }; storage.setImage(cached); hasImage = true; return
            }
        }
        var failures: [String] = []
        for url in candidates.urls {
            guard !Task.isCancelled else { return }
            do {
                if let loaded = try await ModelCatalogImageLoader.image(for: url, maximumPixels: 640) {
                    guard !Task.isCancelled else { return }; storage.setImage(loaded); hasImage = true; return
                }
                if let reason = SecureImageCache.shared.failureDescription(for: url), !failures.contains(reason) { failures.append(reason) }
            } catch is CancellationError { return }
            catch { if !Task.isCancelled, !failures.contains(error.localizedDescription) { failures.append(error.localizedDescription) } }
        }
        guard !Task.isCancelled else { return }
        if !candidates.urls.isEmpty { onError(failures.isEmpty ? "No se pudo obtener ninguno de los candidatos publicados." : failures.joined(separator: " ")) }
    }
}
