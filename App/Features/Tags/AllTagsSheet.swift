import SwiftUI
import StacklumeCore
import StacklumeDesignSystem

/// Hoja con TODAS las etiquetas, **buscable** y **ordenable** (frecuencia o nombre).
/// Resuelve el problema de que la sidebar se vuelva enorme con muchas etiquetas: la
/// sidebar solo muestra las más usadas y «Ver todas» abre esta hoja. Supera a Raindrop,
/// que no ofrece buscador de etiquetas inline ni un «top N» real en el cliente.
struct AllTagsSheet: View {
    /// Etiquetas ya ordenadas por el criterio actual (se reordena en vivo según `byFrequency`).
    let tags: [Tag]
    /// Recuentos precalculados por la sidebar en una sola pasada por la biblioteca.
    /// Evita faultear la relación inversa de cada etiqueta al ordenar o buscar.
    let counts: [UUID: Int]
    /// Selección de la sidebar: al elegir una etiqueta se navega a ella y se cierra.
    @Binding var selection: NavTarget?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    /// Mismo criterio de orden que la sidebar (clave `@AppStorage` compartida).
    @AppStorage("stacklume.sidebar.tagsByFrequency") private var byFrequency = true
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    /// Etiquetas ordenadas y filtradas por el texto de búsqueda.
    private var filtered: [Tag] {
        let sorted = byFrequency
            ? tags.sorted {
                let left = count(for: $0), right = count(for: $1)
                return left == right
                    ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    : left > right
            }
            : tags.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return sorted }
        // Insensible a tildes y mayúsculas (la app es en español): «codigo» encuentra «Código».
        let needle = fold(q)
        return sorted.filter { fold($0.name).contains(needle) }
    }

    /// Normaliza para comparar: sin tildes ni distinción de mayúsculas.
    private func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.border.opacity(0.5))
            list
        }
        .frame(width: 380, height: 480)
        .background(palette.background)
        .task { searchFocused = true }
    }

    private var header: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: 6) {
                Text("Etiquetas")
                    .stacklumeFont(.headline)
                    .foregroundStyle(palette.textPrimary)
                Text("\(tags.count)")
                    .stacklumeFont(.caption.monospacedDigit())
                    .foregroundStyle(palette.textSecondary)
                    .accessibilityLabel("\(tags.count) \(tags.count == 1 ? "etiqueta" : "etiquetas")")
                Spacer()
                Button("Cerrar") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.readableAccent(on: palette.background))
            }
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(palette.textSecondary)
                    .accessibilityHidden(true)
                TextField("Buscar etiqueta", text: $search)
                    .textFieldStyle(.plain)
                    .foregroundStyle(palette.textPrimary)
                    .focused($searchFocused)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Limpiar búsqueda")
                }
                Picker("Orden", selection: $byFrequency) {
                    Text("Frecuencia").tag(true)
                    Text("Nombre").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(DesignSystem.Spacing.md)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filtered) { tag in
                    Button {
                        selection = .tag(tag.id)
                        dismiss()
                    } label: {
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Image(systemName: "number")
                                .foregroundStyle(Color(hex: tag.colorHex))
                                .accessibilityHidden(true)
                            // Ruta del padre (si la etiqueta está anidada), para distinguirla
                            // en la lista plana: «padre › hijo».
                            if let parent = tag.parent?.name {
                                Text("\(parent) ›")
                                    .foregroundStyle(palette.textSecondary)
                                    .stacklumeLineLimit(1)
                                    .layoutPriority(-1)
                            }
                            Text(tag.name)
                                .foregroundStyle(palette.textPrimary)
                                .stacklumeLineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(count(for: tag))")
                                .stacklumeFont(.caption.monospacedDigit())
                                .foregroundStyle(palette.textSecondary)
                        }
                        .padding(.horizontal, DesignSystem.Spacing.sm)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel({
                        let parentPrefix = tag.parent.map { "\($0.name) › " } ?? ""
                        let count = count(for: tag)
                        return "Ir a etiqueta \(parentPrefix)\(tag.name), \(count) \(count == 1 ? "enlace" : "enlaces")"
                    }())
                }
                if filtered.isEmpty {
                    VStack(spacing: DesignSystem.Spacing.xs) {
                        Text("Sin coincidencias para «\(search)»")
                            .stacklumeFont(.callout)
                            .foregroundStyle(palette.textSecondary)
                        Text("Prueba con otro término o cambia el orden")
                            .stacklumeFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(DesignSystem.Spacing.lg)
                }
            }
            .padding(DesignSystem.Spacing.sm)
        }
    }

    private func count(for tag: Tag) -> Int { counts[tag.id] ?? 0 }
}
