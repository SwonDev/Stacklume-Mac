import SwiftUI
import SwiftData
import StacklumeCore
import StacklumeDesignSystem
import StacklumePersistence

/// «Organizar por temas con IA»: agrupa AUTOMÁTICAMENTE los enlaces SIN COLECCIÓN por
/// significado (embeddings on-device, `SemanticSearch.topicClusters`), nombra cada grupo
/// con el modelo local y propone crear colecciones. El usuario revisa (renombra/descarta)
/// antes de aplicar. 100 % local. Algo que Raindrop NO puede: agrupación temática real.
struct TopicOrganizeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.themePalette) private var palette
    @Query(filter: #Predicate<Bookmark> { $0.deletedAt == nil }) private var allLinks: [Bookmark]
    @State private var runner = LocalAIRunner.shared

    @State private var groups: [ProposedGroup] = []
    @State private var phase: Phase = .idle
    @State private var progressText = ""

    enum Phase { case idle, working, done, empty }

    struct ProposedGroup: Identifiable {
        let id = UUID()
        var name: String
        var accepted: Bool = true
        let links: [Bookmark]
    }

    private var language: String { AppSettingsStore.current(in: context).language.rawValue }
    private var uncategorized: [Bookmark] { allLinks.filter { $0.category == nil } }
    private var acceptedCount: Int {
        groups.filter { $0.accepted && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                Text("Organizar por temas con IA").stacklumeFont(.headline)
                Text("\(uncategorized.count) enlaces sin clasificar")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            }
            .padding(.top, DesignSystem.Spacing.md)
            .padding(.bottom, DesignSystem.Spacing.sm)

            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 640, height: 580)
        .background(WindowBackground())
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            VStack(spacing: DesignSystem.Spacing.md) {
                Spacer()
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 40))
                    .foregroundStyle(palette.accent)
                Text("Agruparé tus enlaces sin clasificar por TEMA (por significado, en tu Mac)\ny te propondré colecciones. Tú decides cuáles crear.")
                    .stacklumeFont(.callout).foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
                Button { analyze() } label: {
                    Label("Analizar mis enlaces", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent).tint(palette.accent)
                .disabled(uncategorized.count < 3)
                if uncategorized.count < 3 {
                    Text("Necesitas al menos 3 enlaces sin clasificar.")
                        .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                }
                Spacer()
            }
            .padding(DesignSystem.Spacing.lg)

        case .working:
            VStack(spacing: DesignSystem.Spacing.sm) {
                Spacer()
                ProgressView()
                Text(progressText).stacklumeFont(.callout).foregroundStyle(palette.textSecondary)
                Spacer()
            }

        case .empty:
            VStack(spacing: DesignSystem.Spacing.sm) {
                Spacer()
                Image(systemName: "tray").font(.system(size: 34)).foregroundStyle(palette.textSecondary)
                Text("No encontré grupos temáticos claros.\nTus enlaces sin clasificar son demasiado variados o pocos.")
                    .stacklumeFont(.callout).foregroundStyle(palette.textSecondary).multilineTextAlignment(.center)
                Spacer()
            }
            .padding(DesignSystem.Spacing.lg)

        case .done:
            List {
                ForEach($groups) { $group in
                    groupRow($group)
                }
            }
            .listStyle(.inset)
        }
    }

    private func groupRow(_ group: Binding<ProposedGroup>) -> some View {
        let g = group.wrappedValue
        return HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Toggle("", isOn: group.accepted).labelsHidden()
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("Nombre de la colección", text: group.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    Text("\(g.links.count) enlaces")
                        .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                }
                Text(g.links.prefix(3).map { $0.title.isEmpty ? host($0.url) : $0.title }.joined(separator: " · "))
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                    .stacklumeLineLimit(2)
            }
        }
        .opacity(g.accepted ? 1 : 0.5)
        .padding(.vertical, 2)
    }

    private var footer: some View {
        HStack {
            if phase == .done {
                Text("\(acceptedCount) colección(es) · \(groups.filter { $0.accepted }.reduce(0) { $0 + $1.links.count }) enlaces")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            }
            Spacer()
            Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
            if phase == .done {
                Button("Crear colecciones") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(palette.accent)
                    .disabled(acceptedCount == 0)
            }
        }
        .padding(DesignSystem.Spacing.md)
    }

    // MARK: - Lógica

    private func analyze() {
        phase = .working
        progressText = "Calculando significado de tus enlaces…"
        let links = uncategorized
        let lang = language
        Task { @MainActor in
            await SemanticSearch.warm(links, language: lang, task: "clustering")
            let clusters = SemanticSearch.topicClusters(in: links, language: lang)
            guard !clusters.isEmpty else { phase = .empty; return }
            var result: [ProposedGroup] = []
            for (index, cluster) in clusters.enumerated() {
                progressText = "Nombrando grupos con IA… \(index + 1)/\(clusters.count)"
                let name = await nameCluster(cluster, language: lang)
                result.append(ProposedGroup(name: name, links: cluster))
            }
            groups = result
            phase = .done
        }
    }

    /// Nombra un grupo: 1-3 palabras con el modelo local; si no está disponible, cae a la
    /// etiqueta/keyword/dominio más común del grupo.
    private func nameCluster(_ links: [Bookmark], language lang: String) async -> String {
        let fallback = fallbackName(links)
        guard runner.isAvailable, await runner.ensureReady() != nil else { return fallback }
        let titles = links.prefix(8)
            .map { $0.title.isEmpty ? host($0.url) : $0.title }
            .joined(separator: "\n")
        let langName = lang == "en" ? "inglés" : "español"
        let system = "Eres un bibliotecario. Devuelve SOLO un nombre de colección de 1 a 3 palabras en \(langName) que resuma el tema común de estos enlaces. Sin comillas, sin punto final, sin explicación."
        guard let raw = await runner.complete(system: system, prompt: titles, maxTokens: 80, enableThinking: true) else {
            return fallback
        }
        return Self.cleanName(raw, fallback: fallback)
    }

    /// Limpia la salida del modelo a un nombre de colección. Algunos modelos (LFM2.5) emiten
    /// un bloque de razonamiento `<think>…</think>` aunque se pida desactivarlo: si SOLO razonó
    /// (abrió `<think>` sin cerrarlo) usa el respaldo; si cerró, toma la primera línea útil
    /// posterior. `internal static` para poder testearlo sin el modelo.
    static func cleanName(_ raw: String, fallback: String) -> String {
        let hasOpen = raw.contains("<think>")
        let hasClose = raw.contains("</think>")
        if hasOpen && !hasClose { return fallback }   // solo razonó, sin respuesta útil
        var text = raw
        if let closing = text.range(of: "</think>") { text = String(text[closing.upperBound...]) }
        text = text.replacingOccurrences(of: "<think>", with: "")
            .replacingOccurrences(of: "</think>", with: "")
        let cleaned = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "") }
            .first { !$0.isEmpty && !$0.lowercased().contains("think") } ?? ""
        let final = String(cleaned.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
        return final.count < 2 ? fallback : final
    }

    private func fallbackName(_ links: [Bookmark]) -> String {
        var counts: [String: Int] = [:]
        for link in links {
            for tag in link.tags { counts[tag.name, default: 0] += 1 }
            for keyword in link.semanticTags where keyword.count > 1 {
                counts[keyword.prefix(1).uppercased() + keyword.dropFirst(), default: 0] += 1
            }
        }
        if let best = counts.max(by: { $0.value < $1.value })?.key, !best.isEmpty { return best }
        var domains: [String: Int] = [:]
        for link in links { domains[host(link.url), default: 0] += 1 }
        return domains.max(by: { $0.value < $1.value })?.key ?? "Grupo"
    }

    private func apply() {
        var moved = 0
        for group in groups where group.accepted {
            let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let category = EntityResolver.category(name, in: context) else { continue }
            for link in group.links where link.modelContext != nil && link.category == nil {
                link.category = category
                LinkIngest.userChangedOrganization(link.id)
                link.updatedAt = Date()
                SpotlightIndexer.index(link)
                moved += 1
            }
        }
        if moved > 0 { context.saveLogging(); WidgetReloader.reload() }
        dismiss()
    }

    private func host(_ url: String) -> String {
        URL(string: url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? url
    }
}
