import SwiftUI
import AppKit
import SwiftData
import StacklumeCore
import StacklumeDesignSystem

/// Galería para ELEGIR la portada de un enlace entre varias candidatas REALES de la página
/// (supera a Raindrop, que no deja elegir). Reúne con `PageImageFinder` las imágenes de la
/// web (og:image + `<img>` hero, ya validadas) y ofrece además CAPTURAR el hero renderizado
/// (`PageSnapshotService`) para las SPAs sin imágenes en el HTML. Tocar una la fija como
/// portada (las URL como `imageURL`; la captura como portada personalizada). 100 % local.
struct CoverPickerSheet: View {
    let link: Bookmark
    /// Se llama tras fijar una portada para que la ficha refresque héroe/cuadrícula/widget.
    let onApplied: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.themePalette) private var palette

    @State private var candidates: [String] = []
    @State private var loading = true
    @State private var snapshotting = false

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 14)]
    private var host: String {
        URL(string: link.url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? link.url
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                Text("Elegir portada").stacklumeFont(.headline)
                Text(host).stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            }
            .padding(.top, DesignSystem.Spacing.md)
            .padding(.bottom, DesignSystem.Spacing.sm)

            if loading {
                Spacer()
                ProgressView("Buscando imágenes en la página…").controlSize(.small)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(candidates, id: \.self) { url in
                            tile({
                                SecureRemoteImage(candidates: [url], skeleton: { SkeletonView() }) { palette.surface }
                                    .scaledToFill()
                            }, action: { pickURL(url) })
                        }
                        // Capturar la página renderizada (para SPAs sin imágenes en el HTML).
                        tile({
                            ZStack {
                                palette.surface
                                if snapshotting {
                                    ProgressView().controlSize(.small)
                                } else {
                                    VStack(spacing: 6) {
                                        Image(systemName: "camera.viewfinder").font(.title2)
                                        Text("Capturar la página").stacklumeFont(.caption)
                                    }
                                    .foregroundStyle(palette.textSecondary)
                                }
                            }
                        }, action: { captureSnapshot() })
                    }
                    .padding(DesignSystem.Spacing.md)
                }
                if candidates.isEmpty {
                    Text("La página no expone imágenes en su HTML. Captúrala (arriba) para usar su hero.")
                        .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .padding(.bottom, DesignSystem.Spacing.sm)
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(DesignSystem.Spacing.md)
        }
        .frame(width: 620, height: 480)
        .task {
            candidates = await PageImageFinder.validatedCandidates(for: link.url, limit: 12)
            loading = false
        }
    }

    /// Tile 16:9 UNIFORME: una caja de proporción fija con la imagen de overlay a sangre
    /// (`scaledToFill` + `clipped`), igual que `LinkCoverCard`. Así todas las baldosas —
    /// incluida la de capturar— miden lo mismo (antes el `ZStack` «greedy» se comía la celda).
    @ViewBuilder
    private func tile<Content: View>(@ViewBuilder _ content: () -> Content,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay { content() }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(palette.border.opacity(0.5), lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(snapshotting)
    }

    /// Fija una imagen de la web como portada: quita cualquier portada personalizada (para
    /// que esta gane) y guarda la `imageURL`.
    private func pickURL(_ url: String) {
        CustomCoverStore.shared.remove(for: link.id)
        link.imageURL = url
        link.updatedAt = Date()
        context.saveLogging()
        onApplied()
        dismiss()
    }

    /// Renderiza y captura la página, y la fija como portada personalizada (HD).
    private func captureSnapshot() {
        guard !snapshotting else { return }
        snapshotting = true
        Task { @MainActor in
            defer { snapshotting = false }
            guard let shot = await PageSnapshotService.snapshot(of: link.url),
                  CustomCoverStore.shared.set(shot, for: link.id) else { return }
            link.updatedAt = Date()
            context.saveLogging()
            onApplied()
            dismiss()
        }
    }
}
