import SwiftUI
import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import AVKit
import StacklumeDesignSystem

enum LocalDocumentFileType {
    static func contentType(for data: Data, kind: String) -> UTType {
        if kind == "epub" { return .epub }
        if kind == "audio" || kind == "video" {
            return LocalMediaFileFormat.fileExtension(for: data, kind: kind).flatMap { UTType(filenameExtension: $0) }
                ?? (kind == "audio" ? .audio : .movie)
        }
        guard kind == "image",
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier) else { return kind == "pdf" ? .pdf : .image }
        return type
    }
}

/// Visor nativo de un adjunto local. PDFKit conserva selección, zoom, búsqueda y
/// navegación; las imágenes se decodifican como miniatura; EPUB usa un lector por
/// capítulos que nunca ejecuta el HTML del libro.
struct LocalDocumentPreview: View {
    let id: UUID
    let data: Data
    let kind: String

    @Environment(\.themePalette) private var palette

    var body: some View {
        Group {
            if data.count > DocumentTextExtractor.maximumInputBytes {
                unavailable(
                    title: "Archivo demasiado grande para previsualizar",
                    message: "Puedes exportar el original desde la barra de acciones."
                )
            } else if kind == "audio" || kind == "video" {
                LocalMediaPreview(data: data, kind: kind)
                    .frame(height: kind == "video" ? 300 : 160)
            } else if kind == "epub" {
                EPUBDocumentPreview(id: id, data: data)
                    .frame(minHeight: 280)
            } else if kind == "pdf" {
                PDFDocumentView(id: id, data: data)
                    .frame(height: 380)
                    .accessibilityLabel("Vista previa del documento PDF")
            } else if let image = DocumentPreviewImage.make(from: data) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 420)
                    .accessibilityLabel("Vista previa de la imagen adjunta")
            } else {
                unavailable(
                    title: "No se puede mostrar la imagen",
                    message: "El original sigue guardado y se puede exportar."
                )
            }
        }
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(palette.border.opacity(0.5), lineWidth: 0.5)
        )
        .id(id)
    }

    private func unavailable(title: String, message: String) -> some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "doc.badge.ellipsis")
                .font(.largeTitle)
                .foregroundStyle(palette.accent)
                .accessibilityHidden(true)
            Text(title)
                .stacklumeFont(.headline)
                .foregroundStyle(palette.textPrimary)
            Text(message)
                .stacklumeFont(.callout)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 220)
        .accessibilityElement(children: .combine)
    }
}

private struct LocalMediaPreview: View {
    let data: Data
    let kind: String
    @State private var player: AVPlayer?
    @State private var temporaryURL: URL?
    @State private var failed = false

    var body: some View {
        Group {
            if let player { VideoPlayer(player: player) }
            else if failed { Text("No se puede reproducir este archivo. Puedes exportar el original.") }
            else { ProgressView("Preparando reproducción…") }
        }
        .task {
            do {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StacklumeMedia", isDirectory: true)
                let url = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(LocalMediaFileFormat.fileExtension(for: data, kind: kind) ?? kind)
                try await Task.detached(priority: .utility) { try PrivateFileIO.write(data, to: url) }.value
                if Task.isCancelled { try? FileManager.default.removeItem(at: url); return }
                temporaryURL = url
                player = AVPlayer(url: url)
            } catch { failed = true }
        }
        .onDisappear {
            player?.pause()
            player = nil
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        }
    }
}

private struct EPUBDocumentPreview: View {
    let id: UUID
    let data: Data

    @Environment(\.themePalette) private var palette
    @State private var publication: EPUBPublication?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var showReader = false

    var body: some View {
        Group {
            if let publication {
                HStack(alignment: .center, spacing: DesignSystem.Spacing.lg) {
                    cover(for: publication)

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Label("EPUB · SOLO EN ESTE MAC", systemImage: "lock.fill")
                            .stacklumeFont(.caption2.weight(.bold))
                            .readableTint(palette.accent, palette: palette, on: [palette.background, palette.surface])

                        Text(publication.title ?? "Libro EPUB")
                            .stacklumeFont(.title2.weight(.bold))
                            .foregroundStyle(palette.textPrimary)
                            .stacklumeLineLimit(3)
                            .themedHelp(publication.title ?? "Libro EPUB")

                        if let author = publication.author {
                            Text(author)
                                .stacklumeFont(.callout)
                                .foregroundStyle(palette.textSecondary)
                                .stacklumeLineLimit(2)
                        }

                        Label(
                            "\(publication.chapters.count) capítulo\(publication.chapters.count == 1 ? "" : "s") disponible\(publication.chapters.count == 1 ? "" : "s")",
                            systemImage: "list.bullet.indent"
                        )
                        .stacklumeFont(.caption)
                        .foregroundStyle(palette.textSecondary)

                        Spacer(minLength: 0)

                        Button {
                            showReader = true
                        } label: {
                            Label("Leer libro", systemImage: "book.pages")
                                .stacklumeFont(.callout.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .stacklumeButton()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(DesignSystem.Spacing.lg)
                .accessibilityElement(children: .contain)
            } else if isLoading {
                VStack(spacing: DesignSystem.Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparando el libro en tu Mac…")
                        .stacklumeFont(.callout)
                        .foregroundStyle(palette.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 280)
                .accessibilityElement(children: .combine)
            } else {
                VStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "book.closed.fill")
                        .font(.largeTitle)
                        .foregroundStyle(palette.accent)
                        .accessibilityHidden(true)
                    Text("No se puede abrir este EPUB")
                        .stacklumeFont(.headline)
                        .foregroundStyle(palette.textPrimary)
                    Text(errorMessage ?? "El original sigue guardado y se puede exportar.")
                        .stacklumeFont(.callout)
                        .foregroundStyle(palette.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(DesignSystem.Spacing.lg)
                .frame(maxWidth: .infinity, minHeight: 280)
                .accessibilityElement(children: .combine)
            }
        }
        .task(id: id) { await loadPublication() }
        .sheet(isPresented: $showReader) {
            if let publication {
                EPUBReaderSheet(
                    bookmarkID: id,
                    publication: publication,
                    onClose: { showReader = false }
                )
                .themedSheet(palette)
            }
        }
    }

    @ViewBuilder
    private func cover(for publication: EPUBPublication) -> some View {
        if let coverData = publication.coverData,
           let image = DocumentPreviewImage.make(from: coverData) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: 132, height: 196)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(palette.border.opacity(0.6), lineWidth: 0.5)
                )
                .accessibilityLabel("Portada de \(publication.title ?? "Libro EPUB")")
        } else {
            VStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .accessibilityHidden(true)
                Text("EPUB")
                    .stacklumeFont(.caption.weight(.bold))
                    .foregroundStyle(palette.textPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .foregroundStyle(palette.background)
            .frame(width: 132, height: 196)
            .background(
                LinearGradient(
                    colors: [palette.accent, palette.accent.opacity(0.72)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .accessibilityLabel("Libro EPUB sin portada")
        }
    }

    @MainActor
    private func loadPublication() async {
        isLoading = true
        errorMessage = nil
        let payload = data
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try EPUBDocumentReader.extract(data: payload)
            }.value
            try Task.checkCancellation()
            publication = result
        } catch is CancellationError {
            return
        } catch {
            publication = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct EPUBReaderSheet: View {
    let bookmarkID: UUID
    let publication: EPUBPublication
    let onClose: () -> Void

    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedIndex = 0
    @State private var textSize: ReaderTextSize = .standard

    private enum ReaderTextSize: Int, CaseIterable {
        case compact
        case standard
        case large

        var font: Font {
            switch self {
            case .compact: .callout
            case .standard: .body
            case .large: .title3
            }
        }

        var lineSpacing: CGFloat {
            switch self {
            case .compact: 3
            case .standard: 5
            case .large: 7
            }
        }
    }

    private var progressKey: String { "stacklume-local-epub:\(bookmarkID.uuidString)" }
    private var selectedChapter: EPUBChapter { publication.chapters[selectedIndex] }

    var body: some View {
        EditorScaffold(
            title: publication.title ?? "Lector EPUB",
            confirmTitle: "Cerrar",
            cancelTitle: nil,
            onCancel: onClose,
            onConfirm: onClose
        ) {
            VStack(spacing: 0) {
                readerToolbar
                Divider().overlay(palette.border.opacity(0.5))

                HStack(spacing: 0) {
                    chapterSidebar
                    Divider().overlay(palette.border.opacity(0.5))
                    chapterContent
                }
            }
        }
        .frame(minWidth: 820, idealWidth: 980, minHeight: 620, idealHeight: 720)
        .onAppear { restoreProgress() }
        .onChange(of: selectedIndex) { _, newValue in saveProgress(newValue) }
    }

    private var readerToolbar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Label("Solo en este Mac", systemImage: "lock.fill")
                .stacklumeFont(.caption.weight(.semibold))
                .readableTint(palette.accent, palette: palette, on: [palette.background, palette.surface])

            Spacer()

            Text("Capítulo \(selectedIndex + 1) de \(publication.chapters.count)")
                .stacklumeFont(.caption)
                .foregroundStyle(palette.textSecondary)

            Button {
                textSize = ReaderTextSize(rawValue: max(0, textSize.rawValue - 1)) ?? .compact
            } label: {
                Image(systemName: "textformat.size.smaller")
            }
            .disabled(textSize == .compact)
            .accessibilityLabel("Reducir tamaño del texto")
            .themedHelp("Reducir tamaño del texto")

            Button {
                textSize = ReaderTextSize(rawValue: min(2, textSize.rawValue + 1)) ?? .large
            } label: {
                Image(systemName: "textformat.size.larger")
            }
            .disabled(textSize == .large)
            .accessibilityLabel("Aumentar tamaño del texto")
            .themedHelp("Aumentar tamaño del texto")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(palette.surface.opacity(0.72))
    }

    private var chapterSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("CONTENIDO")
                .stacklumeFont(.caption2.weight(.bold))
                .foregroundStyle(palette.textSecondary)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.top, DesignSystem.Spacing.md)
                .padding(.bottom, DesignSystem.Spacing.xs)

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(Array(publication.chapters.enumerated()), id: \.element.id) { index, chapter in
                        Button {
                            selectedIndex = index
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                                Text("\(index + 1)")
                                    .stacklumeFont(.caption2.monospacedDigit())
                                    .readableTint(index == selectedIndex ? palette.accent : palette.textSecondary,
                                                  palette: palette, on: [palette.background, palette.surface],
                                                  overlay: index == selectedIndex ? palette.accent.opacity(0.14) : nil)
                                    .frame(width: 24, alignment: .trailing)
                                Text(chapter.title)
                                    .stacklumeFont(.callout.weight(index == selectedIndex ? .semibold : .regular))
                                    .readableTint(palette.textPrimary, palette: palette, on: [palette.background, palette.surface],
                                                  overlay: index == selectedIndex ? palette.accent.opacity(0.14) : nil)
                                    .stacklumeLineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, DesignSystem.Spacing.sm)
                            .padding(.vertical, 8)
                            .background(
                                index == selectedIndex ? palette.accent.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Capítulo \(index + 1): \(chapter.title)")
                        .themedHelp(chapter.title)
                    }
                }
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.bottom, DesignSystem.Spacing.md)
            }
        }
        .frame(width: 230)
        .background(palette.surface.opacity(0.38))
    }

    private var chapterContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    Color.clear.frame(height: 1).id("epub-chapter-top")

                    Text(selectedChapter.title)
                        .stacklumeFont(.title.weight(.bold))
                        .foregroundStyle(palette.textPrimary)
                        .textSelection(.enabled)

                    Text(selectedChapter.text)
                        .stacklumeFont(textSize.font)
                        .foregroundStyle(palette.textPrimary)
                        .lineSpacing(textSize.lineSpacing)
                        .textSelection(.enabled)
                        .frame(maxWidth: 720, alignment: .leading)

                    if publication.wasTruncated {
                        Label(
                            "Este libro supera los límites de indexación; el original permanece intacto.",
                            systemImage: "info.circle"
                        )
                        .stacklumeFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                    }

                    chapterNavigation
                }
                .padding(DesignSystem.Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(palette.background)
            .onChange(of: selectedIndex) { _, _ in
                if reduceMotion {
                    proxy.scrollTo("epub-chapter-top", anchor: .top)
                } else {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo("epub-chapter-top", anchor: .top)
                    }
                }
            }
        }
    }

    private var chapterNavigation: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Button("Anterior", systemImage: "chevron.left") {
                selectedIndex = max(0, selectedIndex - 1)
            }
            .disabled(selectedIndex == 0)
            .keyboardShortcut("[", modifiers: .command)

            Spacer()

            Button("Siguiente", systemImage: "chevron.right") {
                selectedIndex = min(publication.chapters.count - 1, selectedIndex + 1)
            }
            .disabled(selectedIndex == publication.chapters.count - 1)
            .keyboardShortcut("]", modifiers: .command)
        }
        .buttonStyle(.bordered)
        .padding(.top, DesignSystem.Spacing.md)
    }

    private func restoreProgress() {
        guard publication.chapters.count > 1 else { return }
        let progress = ReadingProgressStore.progress(forKey: progressKey)
        selectedIndex = min(
            publication.chapters.count - 1,
            max(0, Int((progress * Double(publication.chapters.count - 1)).rounded()))
        )
    }

    private func saveProgress(_ index: Int) {
        guard publication.chapters.count > 1 else { return }
        ReadingProgressStore.setProgress(
            Double(index) / Double(publication.chapters.count - 1),
            forKey: progressKey
        )
    }
}

private struct PDFDocumentView: NSViewRepresentable {
    let id: UUID
    let data: Data

    final class Coordinator {
        var representedID: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.backgroundColor = .clear
        update(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        update(nsView, coordinator: context.coordinator)
    }

    private func update(_ view: PDFView, coordinator: Coordinator) {
        guard coordinator.representedID != id else { return }
        coordinator.representedID = id
        view.document = PDFDocument(data: data)
        view.autoScales = true
    }
}

enum DocumentPreviewImage {
    static func make(from data: Data) -> NSImage? {
        guard data.count <= DocumentTextExtractor.maximumInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              width <= DocumentTextExtractor.maximumImagePixels / max(1, height) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2_400,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}

/// Hoja temática y acotada para leer/copiar el texto completo reconocido sin insertar
/// millones de caracteres en el árbol principal de la ficha.
struct DocumentTextSheet: View {
    let title: String
    let text: String
    let onClose: () -> Void

    @Environment(\.themePalette) private var palette

    var body: some View {
        EditorScaffold(
            title: title,
            confirmTitle: "Cerrar",
            cancelTitle: nil,
            onCancel: onClose,
            onConfirm: onClose
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack {
                    Text("\(text.count.formatted()) caracteres")
                        .stacklumeFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                    Spacer()
                    Button("Copiar texto", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .buttonStyle(.bordered)
                    .themedHelp("Copiar todo el texto reconocido")
                }

                ScrollView {
                    Text(text)
                        .stacklumeFont(.body)
                        .foregroundStyle(palette.textPrimary)
                        .textSelection(.enabled)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DesignSystem.Spacing.md)
                }
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(palette.border.opacity(0.5), lineWidth: 0.5)
                )
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .frame(width: 700, height: 620)
    }
}
