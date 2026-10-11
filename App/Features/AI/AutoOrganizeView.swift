import SwiftUI
import SwiftData
import StacklumeCore
import StacklumeDesignSystem

/// Acción inteligente: enriquecer en lote con el modelo Liquid los enlaces a los
/// que les falta título, descripción, categoría o etiquetas.
struct AutoOrganizeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.themePalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Query private var allLinks: [Bookmark]
    @Query private var settingsList: [AppSettings]
    @State private var runner = LocalAIRunner.shared

    @State private var isWorking = false
    @State private var progress = 0
    @State private var total = 0
    @State private var result: Int?
    /// `true` si el modelo Liquid no pudo cargarse al pulsar «Enriquecer con IA».
    @State private var loadFailed = false

    private var lang: String { (settingsList.first?.language ?? .es).rawValue }
    private var pending: Int {
        allLinks.filter { $0.deletedAt == nil && AIBatchEnricher.needsAIEnrichment($0) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "wand.and.stars")
                    .scaledFont(28, scalesWithText: false).foregroundStyle(palette.accent)
                    .frame(width: 56, height: 56)
                    .background(
                        palette.background.opacity(0.30),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .stacklumeGlass(
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(palette.accent.opacity(0.34), lineWidth: 0.75)
                    }
                Text("El asistente Liquid completa título, descripción, categoría y etiquetas.")
                    .stacklumeFont(.callout).foregroundStyle(palette.textSecondary)
            }

            if loadFailed {
                Label("No se pudo cargar el modelo Liquid. Inténtalo de nuevo o cárgalo en Ajustes › IA.",
                      systemImage: "exclamationmark.triangle.fill")
                    .stacklumeFont(.callout)
                    .foregroundStyle(palette.textSecondary)
            } else if let result {
                Label("\(result) enlaces mejorados", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if isWorking {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: total > 0 ? Double(progress) / Double(total) : 0).tint(palette.accent)
                    Text("Procesando \(progress) de \(total)…").stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                }
            } else {
                Text("\(pending) enlaces se pueden mejorar.").foregroundStyle(palette.textPrimary)
            }

            Button {
                Task { await run() }
            } label: {
                Label(isWorking ? "Procesando…" : "Enriquecer con IA", systemImage: "sparkles")
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .stacklumeButton()
            .disabled(isWorking || pending == 0)

            Spacer()
        }
        .padding(DesignSystem.Spacing.lg)
    }

    private func run() async {
        guard !isWorking else { return }
        isWorking = true; result = nil; loadFailed = false; progress = 0
        // Si el modelo no carga, aborta y avisa en vez de recorrer 200 fetches de red
        // para devolver 0 mejorados sin explicación.
        guard await runner.ensureReady(userInitiated: true) != nil else {
            loadFailed = true; isWorking = false; return
        }
        let n = await AIBatchEnricher.enrich(in: context, provider: "liquid", language: lang,
                                             ignoreLedger: true) { done, tot in
            progress = done; total = tot
        }
        result = n; isWorking = false
    }
}
