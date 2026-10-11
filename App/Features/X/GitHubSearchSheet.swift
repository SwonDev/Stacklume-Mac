import SwiftUI
import AppKit
import SwiftData
import StacklumeCore
import StacklumeDesignSystem

/// Hoja de búsqueda en GitHub que se abre al elegir «Buscar en GitHub» sobre un texto
/// seleccionado en la sección X (un tweet que menciona un repo pero no enlaza a él).
///
/// Muestra un buscador editable (precargado con la selección) y un listado RICO de
/// repositorios (avatar, nombre, descripción, ⭐, lenguaje con color, topics, fecha) ordenado
/// por estrellas. Cada repo se puede **Añadir** a la biblioteca como un enlace normal —reutiliza
/// `LinkIngest.ingestLink` (dedup + enriquecido completo)— o previsualizar en el navegador interno.
struct GitHubSearchSheet: View {
    /// Texto de partida (la selección del tweet). Se limpia y se precarga en el buscador.
    let initialQuery: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @Environment(\.modelContext) private var context

    @State private var query = ""
    @State private var results: [GitHubRepo] = []
    @State private var phase: Phase = .idle
    /// Repos ya añadidos en esta sesión de búsqueda (para mostrar «Añadido ✓»).
    @State private var added: Set<Int> = []
    /// Repo abierto en vista previa (navegador interno).
    @State private var preview: IdentifiableURL?
    @FocusState private var fieldFocused: Bool

    private enum Phase: Equatable { case idle, loading, loaded, empty, error(String) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.border.opacity(0.5))
            content
        }
        .frame(width: 760, height: 640)
        .background(WindowBackground())
        .onAppear {
            query = GitHubRepoSearcher.cleanQuery(initialQuery)
            runSearch()
        }
        // Vista previa del repo en el navegador interno (con AdBlock), sin salir de la app.
        .sheet(item: $preview) { item in
            InAppBrowserSheet(url: item.url).themedSheet(palette)
        }
    }

    // MARK: - Cabecera + buscador

    private var header: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.title3)
                    .foregroundStyle(palette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Buscar en GitHub")
                        .stacklumeFont(.headline.weight(.bold))
                        .foregroundStyle(palette.textPrimary)
                    Text("Encuentra el repositorio y añádelo a tu biblioteca")
                        .stacklumeFont(.caption2)
                        .foregroundStyle(palette.textSecondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(palette.textSecondary)
                }
                .buttonStyle(.plain)
                .themedHelp("Cerrar")
                .accessibilityLabel("Cerrar")
            }

            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(palette.textSecondary)
                TextField("Repositorio, tema, autor…", text: $query)
                    .textFieldStyle(.plain)
                    .stacklumeFont(.body)
                    .foregroundStyle(palette.textPrimary)
                    .focused($fieldFocused)
                    .onSubmit { runSearch() }
                if !query.isEmpty {
                    Button { query = ""; fieldFocused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Borrar")
                }
                Button { runSearch() } label: {
                    Text("Buscar").stacklumeFont(.callout.weight(.semibold))
                        .foregroundStyle(palette.accent.contrastingForeground)
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(DesignSystem.Spacing.sm)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(palette.border.opacity(0.5)))
        }
        .padding(DesignSystem.Spacing.md)
    }

    // MARK: - Contenido por estado

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle, .loading:
            stateView(text: "Buscando en GitHub…") {
                ProgressView().controlSize(.large).tint(palette.accent)
            }
        case .empty:
            stateView(text: "Sin resultados. Prueba con otras palabras.") {
                Image(systemName: "magnifyingglass").scaledFont(40, scalesWithText: false).foregroundStyle(palette.textSecondary)
            }
        case .error(let message):
            VStack(spacing: DesignSystem.Spacing.md) {
                Image(systemName: "exclamationmark.triangle").scaledFont(40, scalesWithText: false).foregroundStyle(.orange)
                Text(message).stacklumeFont(.callout).foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Reintentar") { runSearch() }
                    .buttonStyle(.borderedProminent).tint(palette.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(DesignSystem.Spacing.xl)
        case .loaded:
            ScrollView {
                LazyVStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(results) { repo in card(repo) }
                }
                .padding(DesignSystem.Spacing.md)
            }
        }
    }

    private func stateView<Icon: View>(text: String, @ViewBuilder icon: () -> Icon) -> some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            icon()
            Text(text).stacklumeFont(.callout).foregroundStyle(palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Tarjeta de repositorio

    private func card(_ repo: GitHubRepo) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            SecureRemoteImage(candidates: [repo.ownerAvatarURL]) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.background)
                    .overlay(Image(systemName: "shippingbox").foregroundStyle(palette.textSecondary))
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(palette.border.opacity(0.4)))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(repo.fullName)
                        .stacklumeFont(.headline)
                        .foregroundStyle(palette.textPrimary)
                        .stacklumeLineLimit(1)
                    if repo.isArchived { tag("Archivado", color: .orange) }
                }
                if let d = repo.description, !d.isEmpty {
                    Text(d)
                        .stacklumeFont(.callout)
                        .foregroundStyle(palette.textSecondary)
                        .stacklumeLineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                metaRow(repo)
                if !repo.topics.isEmpty { topicChips(Array(repo.topics.prefix(5))) }
            }

            Spacer(minLength: 0)

            VStack(spacing: 6) {
                addButton(repo)
                HStack(spacing: 4) {
                    iconButton("eye", help: "Vista previa") {
                        if let url = URL(string: repo.htmlURL) { preview = IdentifiableURL(url: url) }
                    }
                    iconButton("doc.on.doc", help: "Copiar enlace") { copyToPasteboard(repo.htmlURL) }
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(palette.border.opacity(0.4)))
    }

    /// Estrellas · lenguaje (con su color) · forks · última actualización · licencia.
    private func metaRow(_ repo: GitHubRepo) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            meta("star.fill", compact(repo.stars))
            if let lang = repo.language, !lang.isEmpty {
                HStack(spacing: 4) {
                    Circle().fill(GitHubLanguage.color(for: lang)).frame(width: 9, height: 9)
                    Text(lang).stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                }
            }
            if repo.forks > 0 { meta("tuningfork", compact(repo.forks)) }
            if let updated = repo.updatedAt {
                meta("clock", updated.formatted(.relative(presentation: .named)))
            }
            if let license = repo.licenseName, !license.isEmpty {
                meta("scale.3d", license)
            }
        }
        .stacklumeLineLimit(1)
    }

    private func meta(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text).stacklumeFont(.caption).monospacedDigit()
        }
        .foregroundStyle(palette.textSecondary)
    }

    private func topicChips(_ topics: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(topics, id: \.self) { topic in
                Text(topic)
                    .stacklumeFont(.caption2.weight(.medium))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(palette.accent.opacity(0.14), in: Capsule())
            }
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .stacklumeFont(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
    }

    private func addButton(_ repo: GitHubRepo) -> some View {
        let isAdded = added.contains(repo.id)
        return Button {
            guard !isAdded else { return }
            _ = LinkIngest.ingestLink(urlString: repo.htmlURL, in: context, aiEnrich: true)
            added.insert(repo.id)
        } label: {
            Label(isAdded ? "Añadido" : "Añadir", systemImage: isAdded ? "checkmark" : "plus")
                .stacklumeFont(.callout.weight(.semibold))
                .foregroundStyle(isAdded ? palette.textSecondary : palette.accent.contrastingForeground)
                .frame(minWidth: 92)
        }
        .buttonStyle(.borderedProminent)
        .tint(isAdded ? palette.surface : palette.accent)
        .disabled(isAdded)
        .themedHelp(isAdded ? "Ya está en tu biblioteca" : "Añadir a tu biblioteca")
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(palette.textSecondary)
                .frame(width: 28, height: 24)
                .background(palette.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .themedHelp(help)
        .accessibilityLabel(help)
    }

    // MARK: - Acciones

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { results = []; phase = .empty; return }
        phase = .loading
        Task {
            do {
                let repos = try await GitHubRepoSearcher.search(q)
                results = repos
                phase = repos.isEmpty ? .empty : .loaded
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "No se pudo buscar en GitHub."
                phase = .error(message)
            }
        }
    }

    /// Número compacto con separador decimal español: 831 → «831», 1234 → «1,2 k».
    private func compact(_ n: Int) -> String {
        guard n >= 1000 else { return "\(n)" }
        let v = Double(n) / 1000
        let s = n >= 10_000 ? String(Int(v.rounded())) : String(format: "%.1f", v)
        return s.replacingOccurrences(of: ".", with: ",") + " k"
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
