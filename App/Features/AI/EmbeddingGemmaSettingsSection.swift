import SwiftUI
import StacklumeDesignSystem

struct EmbeddingGemmaSettingsSection: View {
    @Environment(\.themePalette) private var palette
    @State private var service = MultimodalSearchService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Label("Búsqueda inteligente", systemImage: "doc.text.magnifyingglass")
                .stacklumeFont(.title3.weight(.bold)).foregroundStyle(palette.textPrimary)
            Text("EmbeddingGemma 2 · Solo en este Mac")
                .stacklumeFont(.caption).foregroundStyle(palette.readableAccent(on: palette.surface))
            Text("Encuentra enlaces por significado, imágenes por su aspecto o color, páginas de PDF y momentos de audio o vídeo. El asistente consulta el mismo índice para responder con tus fuentes.")
                .stacklumeFont(.callout).foregroundStyle(palette.textSecondary)
            HStack(alignment: .top) {
                if service.busy { ProgressView().controlSize(.small) }
                Text(service.status).stacklumeFont(.caption).foregroundStyle(palette.textPrimary)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            if let error = service.error {
                Text(error).stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                Button("Reintentar") { Task { await service.retry() } }
                    .stacklumeButton().disabled(service.busy)
            }
            if !service.visualStatus.isEmpty {
                Text(service.visualStatus).stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            }
            if service.visualFailures > 0 {
                Text("\(service.visualFailures) portadas o páginas no están disponibles. La búsqueda conserva el resto del contenido.")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                Button("Reintentar contenido visual") { Task { await service.retry() } }
                    .stacklumeButton().disabled(service.busy)
            }
            Text("Se prepara automáticamente. La primera descarga requiere Internet; tus archivos, búsquedas y conversaciones se procesan localmente. No cambia tu modelo de IA. Puedes buscar con un archivo desde el botón junto al buscador.")
                .stacklumeFont(.footnote).foregroundStyle(palette.textSecondary)
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: DesignSystem.cornerRadius))
    }
}
