import SwiftUI
import SwiftData
import StacklumeCore
import StacklumeDesignSystem

/// Gestor de enlaces duplicados (paridad con el iPhone): agrupa los enlaces por
/// URL normalizada, conserva uno por grupo (el más antiguo —o el favorito— por
/// defecto, editable) y elimina el resto. Se presenta como hoja desde
/// Mantenimiento. Respeta `AppSettings.confirmBeforeDelete`.
struct DuplicatesView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @Query private var allLinks: [Bookmark]
    @Query private var settingsList: [AppSettings]

    /// IDs marcados para conservar (uno por grupo). El resto del grupo se elimina.
    @State private var keepIDs: Set<UUID> = []
    @State private var showConfirm = false
    /// Modo de detección: por URL exacta (como Raindrop) o por CONTENIDO similar (semántico).
    @State private var mode: DupMode = .url
    @State private var contentGroups: [DuplicateGroup] = []
    @State private var computingContent = false

    enum DupMode: String, CaseIterable, Identifiable {
        case url, content
        var id: String { rawValue }
        var label: String { self == .url ? "Por URL" : "Por contenido" }
    }

    private var confirmBeforeDelete: Bool { settingsList.first?.confirmBeforeDelete ?? true }
    private var language: String { (settingsList.first?.language ?? .es).rawValue }

    private struct DuplicateGroup: Identifiable {
        let id: String
        let title: String
        let links: [Bookmark] // ordenados por antigüedad (más antiguo primero)
    }

    /// Clave EXACTA ([[CanonicalURL]]): agrupa como duplicados solo los enlaces idénticos
    /// (normaliza esquema, host, barra final y seguimiento; conserva contenido y fragmento).
    private func normalize(_ url: String) -> String { CanonicalURL.key(url) }

    private var urlGroups: [DuplicateGroup] {
        let active = allLinks.filter {
            $0.deletedAt == nil && CanonicalURL.webBookmarkKey($0.url, fileKind: $0.fileKind) != nil
        }
        let grouped = Dictionary(grouping: active) { normalize($0.url) }
        return grouped
            .filter { $0.value.count > 1 }
            .map { kv -> DuplicateGroup in
                let links = kv.value.sorted { $0.createdAt < $1.createdAt }
                return DuplicateGroup(id: kv.key, title: links.first?.url.urlHost ?? "Duplicado", links: links)
            }
            .sorted { $0.links.count > $1.links.count }
    }

    /// Grupos mostrados según el modo (URL exacta vs contenido similar).
    private var displayedGroups: [DuplicateGroup] { mode == .url ? urlGroups : contentGroups }

    /// Nº de enlaces que se eliminarán (todos menos el conservado de cada grupo).
    private var removableCount: Int {
        displayedGroups.reduce(0) { $0 + $1.links.filter { !keepIDs.contains($0.id) }.count }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if mode == .content && computingContent {
                    VStack(spacing: DesignSystem.Spacing.sm) {
                        ProgressView()
                        Text("Analizando el contenido…")
                            .stacklumeFont(.callout).foregroundStyle(palette.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if displayedGroups.isEmpty {
                    ContentUnavailableView(
                        mode == .url ? "Sin duplicados" : "Sin contenido duplicado",
                        systemImage: "checkmark.seal.fill",
                        description: Text(mode == .url
                            ? "Todos tus enlaces tienen una URL única."
                            : "No hay enlaces con contenido casi idéntico."))
                } else {
                    list
                }
            }
            if !displayedGroups.isEmpty, !(mode == .content && computingContent) {
                Divider()
                footer
            }
        }
        .frame(width: 520, height: 520)
        .background(WindowBackground())
        .task(id: mode) {
            if mode == .content { await computeContentGroups() }
            resetKeepSelection()
        }
        .confirmationDialog("¿Eliminar los duplicados?", isPresented: $showConfirm, titleVisibility: .visible) {
            Button(removableCount == 1 ? "Eliminar 1 duplicado" : "Eliminar \(removableCount) duplicados",
                   role: .destructive) { removeDuplicates() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Antes de borrarlos, sus datos (etiquetas, favorito, notas…) se FUNDEN en el que conservas, para no perder nada. Los duplicados van a la papelera; podrás restaurarlos.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Duplicados")
                        .stacklumeFont(.headline)
                        .foregroundStyle(palette.textPrimary)
                    Text("Toca el enlace que quieres CONSERVAR en cada grupo. El resto se eliminará.")
                        .stacklumeFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
                Spacer()
                Button("Cerrar") { dismiss() }
                    .themedHelp("Cerrar el panel de duplicados")
            }
            Picker("Modo de detección", selection: $mode) {
                ForEach(DupMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .themedHelp("Por URL: detecta URLs idénticas. Por contenido: detecta páginas casi iguales aunque la URL sea distinta.")
        }
        .padding(DesignSystem.Spacing.md)
    }

    private var list: some View {
        List {
            ForEach(displayedGroups) { group in
                Section(group.title) {
                    ForEach(group.links) { link in
                        Button { keepOne(link.id, in: group) } label: {
                            row(link, kept: keepIDs.contains(link.id))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(link.title.isEmpty ? link.url : link.title)
                        .accessibilityValue(keepIDs.contains(link.id) ? "Se conserva" : "Se eliminará")
                        .accessibilityAddTraits(keepIDs.contains(link.id) ? .isSelected : [])
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func row(_ link: Bookmark, kept: Bool) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: kept ? "checkmark.circle.fill" : "trash.circle")
                .foregroundStyle(kept ? .green : Color.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(link.title.isEmpty ? link.url : link.title)
                    .stacklumeFont(.subheadline)
                    .foregroundStyle(palette.textPrimary)
                    .stacklumeLineLimit(1)
                Text(kept ? "Se conserva" : "Se eliminará")
                    .stacklumeFont(.caption2)
                    .foregroundStyle(kept ? .green : Color.red)
            }
            Spacer()
            if link.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(palette.accent)
                    .accessibilityHidden(true)
            }
        }
        .listRowBackground(palette.surface)
    }

    private var footer: some View {
        Button(role: .destructive) {
            if confirmBeforeDelete { showConfirm = true } else { removeDuplicates() }
        } label: {
            Label(removableCount == 1 ? "Eliminar 1 duplicado" : "Eliminar \(removableCount) duplicados",
                  systemImage: "trash")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.red)
        .disabled(removableCount == 0)
        .padding(DesignSystem.Spacing.md)
    }

    /// (Re)calcula la selección a conservar: por defecto el enlace MÁS COMPLETO de cada
    /// grupo (favorito, imagen, descripción, etiquetas, notas, colección…), no solo el más
    /// antiguo — así la fusión conserva el de mayor calidad y se pierde menos. En empate,
    /// gana el más antiguo (los grupos vienen ordenados de más antiguo a más nuevo). El
    /// usuario siempre puede tocar otro para sobrescribir la elección.
    private func resetKeepSelection() {
        var keep = Set<UUID>()
        for group in displayedGroups {
            let preferred = group.links.reduce(group.links.first) { best, link in
                guard let best else { return link }
                return DuplicateCleaner.richness(link) > DuplicateCleaner.richness(best) ? link : best
            }
            if let preferred { keep.insert(preferred.id) }
        }
        keepIDs = keep
    }

    /// Calcula los grupos de CONTENIDO casi idéntico (semántico): precalienta los vectores
    /// y agrupa por alta similitud. Marca `computingContent` para mostrar el progreso.
    private func computeContentGroups() async {
        computingContent = true
        defer { computingContent = false }
        let active = allLinks.filter { $0.deletedAt == nil && !$0.isArchived }
        guard SemanticSearch.isAvailable(language: language), active.count > 1 else {
            contentGroups = []; return
        }
        await SemanticSearch.warm(active, language: language, task: "similarity")
        guard !Task.isCancelled else { return }
        let clusters = SemanticSearch.duplicateClusters(in: active, language: language)
        // Tras el `await warm` (segundos): descarta los enlaces borrados entretanto
        // (modelContext == nil) antes de leer sus propiedades, para no tocar un @Model invalidado.
        contentGroups = clusters.enumerated().compactMap { idx, links in
            let valid = links.filter { $0.modelContext != nil }
            guard valid.count > 1 else { return nil }
            let sorted = valid.sorted { $0.createdAt < $1.createdAt }
            let title = sorted.first.map { $0.title.isEmpty ? $0.url.urlHost : $0.title } ?? "Contenido similar"
            return DuplicateGroup(id: "content-\(sorted.first?.id.uuidString ?? "\(idx)")",
                                  title: title, links: sorted)
        }
    }

    private func keepOne(_ id: UUID, in group: DuplicateGroup) {
        withAnimation(.snappy) {
            for link in group.links { keepIDs.remove(link.id) }
            keepIDs.insert(id)
        }
    }

    private func removeDuplicates() {
        var removedIDs: [UUID] = []
        var keptModified: [Bookmark] = []
        withAnimation(.snappy) {
            for group in displayedGroups {
                guard let kept = group.links.first(where: { keepIDs.contains($0.id) }) else { continue }
                let dups = group.links.filter { !keepIDs.contains($0.id) }
                for dup in dups {
                    DuplicateCleaner.merge(dup, into: kept)   // funde antes de borrar (sin perder datos)
                    dup.deletedAt = Date()
                    removedIDs.append(dup.id)
                }
                if !dups.isEmpty { kept.updatedAt = Date(); keptModified.append(kept) }
            }
        }
        context.saveLogging()
        removedIDs.forEach { SpotlightIndexer.remove(id: $0) }
        keptModified.forEach { SpotlightIndexer.index($0) }   // reindexa el fusionado
        WidgetReloader.reload()
        dismiss()
    }

}
