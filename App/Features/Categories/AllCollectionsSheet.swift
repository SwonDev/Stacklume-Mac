import SwiftUI
import StacklumeCore
import StacklumeDesignSystem

/// Índice completo y buscable de colecciones. La sidebar conserva solo un conjunto
/// pequeño de destinos frecuentes; esta hoja mantiene accesible el árbol entero sin
/// obligar al usuario a recorrer una columna lateral interminable.
struct AllCollectionsSheet: View {
    let collections: [BookmarkCategory]
    let counts: [UUID: Int]
    @Binding var selection: NavTarget?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private struct Entry: Identifiable {
        let collection: BookmarkCategory
        let path: String

        var id: UUID { collection.id }
    }

    private var entries: [Entry] {
        collections
            .map { Entry(collection: $0, path: hierarchyPath(for: $0)) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private var filteredEntries: [Entry] {
        let needle = folded(search.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return entries }
        return entries.filter { folded($0.path).contains(needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.border.opacity(0.5))
            collectionList
        }
        .frame(width: 420, height: 500)
        .background(palette.background)
        .task { searchFocused = true }
    }

    private var header: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: 6) {
                Text("Colecciones")
                    .stacklumeFont(.headline)
                    .foregroundStyle(palette.textPrimary)
                Text("\(collections.count)")
                    .stacklumeFont(.caption.monospacedDigit())
                    .foregroundStyle(palette.textSecondary)
                    .accessibilityLabel("\(collections.count) \(collections.count == 1 ? "colección" : "colecciones")")
                Spacer()
                Button("Cerrar") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.readableAccent(on: palette.background))
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(palette.textSecondary)
                    .accessibilityHidden(true)
                TextField("Buscar por nombre o ruta…", text: $search)
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
            }
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xs)
            .background(palette.surface,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(palette.border.opacity(0.5), lineWidth: 0.5)
            }
        }
        .padding(DesignSystem.Spacing.md)
    }

    private var collectionList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filteredEntries) { entry in
                    collectionButton(entry)
                }

                if filteredEntries.isEmpty {
                    VStack(spacing: DesignSystem.Spacing.xs) {
                        Text("Sin coincidencias para «\(search)»")
                            .stacklumeFont(.callout)
                            .foregroundStyle(palette.textSecondary)
                        Text("Busca por cualquier nivel de la ruta")
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

    private func collectionButton(_ entry: Entry) -> some View {
        let collection = entry.collection
        let count = counts[collection.id] ?? 0
        let isSelected = selection == .collection(collection.id)
        return Button {
            selection = .collection(collection.id)
            dismiss()
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: collection.icon)
                    .foregroundStyle(Color(hex: collection.colorHex))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(entry.path)
                    .readableTint(palette.textPrimary, palette: palette, on: [palette.background],
                                  overlay: isSelected ? palette.accent.opacity(0.12) : nil)
                    .stacklumeLineLimit(1)
                Spacer(minLength: DesignSystem.Spacing.sm)
                Text("\(count)")
                    .stacklumeFont(.caption.monospacedDigit())
                    .readableTint(palette.textSecondary, palette: palette, on: [palette.background],
                                  overlay: isSelected ? palette.accent.opacity(0.12) : nil)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .readableTint(palette.accent, palette: palette, on: [palette.background],
                                      overlay: palette.accent.opacity(0.12), minimumContrast: 3)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                isSelected ? palette.accent.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ir a colección \(entry.path)")
        .accessibilityValue("\(count) \(count == 1 ? "enlace" : "enlaces")")
    }

    private func hierarchyPath(for collection: BookmarkCategory) -> String {
        var names = [collection.name]
        var parent = collection.parent
        var visited: Set<UUID> = [collection.id]
        while let current = parent, visited.insert(current.id).inserted {
            names.append(current.name)
            parent = current.parent
        }
        return names.reversed().joined(separator: " › ")
    }

    private func folded(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive],
                      locale: Locale(identifier: "es"))
    }
}
