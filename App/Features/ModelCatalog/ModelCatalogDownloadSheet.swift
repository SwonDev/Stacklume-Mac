import SwiftUI
import AppKit
import StacklumeDesignSystem

struct ModelCatalogDownloadSheet: View {
    let selection: ModelCatalogDownloadSelection
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @State private var task: Task<Void, Never>?
    @State private var received: Int64 = 0
    @State private var expected: Int64?
    @State private var isDownloading = false
    @State private var destination: URL?
    @State private var completed: URL?
    @State private var error: String?

    var body: some View {
        EditorScaffold(title: "Descargar archivo", confirmTitle: completed == nil ? "Descargar…" : "Mostrar en Finder", canConfirm: !isDownloading, onCancel: { task?.cancel(); dismiss() }, onConfirm: { if let completed { NSWorkspace.shared.activateFileViewerSelecting([completed]); dismiss() } else { begin() } }) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                Text(selection.filename).stacklumeFont(.headline).textSelection(.enabled)
                if let bytes = selection.expectedBytes { Text("\(selection.sizeIsApproximate ? "Tamaño orientativo" : "Tamaño publicado"): \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))").stacklumeFont(.callout) }
                if !selection.license.isEmpty { Text("Licencia publicada: \(selection.license)").stacklumeFont(.callout).textSelection(.enabled) }
                Text("El archivo se guarda en el destino que elijas. El proveedor decide el acceso; revisa su licencia y términos antes de utilizarlo.")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                if let source = selection.sourceURL { Link("Fuente y términos del proveedor", destination: source).themedHelp("Consultar la ficha original del archivo") }
                if isDownloading {
                    if let expected, expected > 0 { ProgressView(value: Double(received), total: Double(expected)).tint(palette.accent) }
                    else { ProgressView("Descargando…").tint(palette.accent) }
                    Text("\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file))\(expected.map { " de \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? "")").stacklumeFont(.caption).monospacedDigit()
                    if let destination { Text(destination.path).stacklumeFont(.caption).foregroundStyle(palette.textSecondary).textSelection(.enabled) }
                }
                if let completed { Label("Archivo guardado: \(completed.lastPathComponent)", systemImage: "checkmark.circle").foregroundStyle(palette.textPrimary) }
                if let error { Label(error, systemImage: "exclamationmark.triangle").stacklumeFont(.callout).foregroundStyle(palette.textPrimary).fixedSize(horizontal: false, vertical: true) }
            }
            .foregroundStyle(palette.textPrimary).padding(DesignSystem.Spacing.lg)
        }
        .frame(minWidth: 420, idealWidth: 580, maxWidth: 760, minHeight: 300, idealHeight: 420, maxHeight: 650)
        .onDisappear { task?.cancel() }
        .onExitCommand { task?.cancel(); dismiss() }
    }
    private func begin() {
        let panel = NSSavePanel()
        panel.title = "Guardar archivo de \(selection.provider.title)"
        panel.nameFieldStringValue = selection.filename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination = url; isDownloading = true; received = 0; expected = selection.expectedBytes; error = nil
        task?.cancel()
        task = Task {
            do {
                let saved = try await ModelCatalogClient.shared.download(selection, to: url) { progress in
                    Task { @MainActor in
                        guard isDownloading else { return }
                        received = progress.received; expected = progress.expected
                    }
                }
                try Task.checkCancellation(); completed = saved
            } catch is CancellationError { return }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            isDownloading = false
        }
    }
}
