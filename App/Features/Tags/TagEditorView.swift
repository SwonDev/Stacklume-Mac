import SwiftUI
import SwiftData
import StacklumeCore
import StacklumeDesignSystem

struct TagEditorView: View {
    enum Mode: Identifiable {
        case create
        case edit(Tag)
        var id: String { switch self { case .create: "create"; case .edit(let t): t.id.uuidString } }
    }
    let mode: Mode

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Tag> { $0.deletedAt == nil }, sort: \Tag.order) private var all: [Tag]

    @State private var name = ""
    @State private var colorHex = ColorPresets.all[6]
    @State private var parentID: UUID?
    @State private var didLoad = false

    private var isEditing: Bool { if case .edit = mode { return true }; return false }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Etiquetas que pueden ser padre: todas menos la propia y sus descendientes,
    /// para no crear ciclos en la jerarquía (igual que el iPhone).
    private var parentOptions: [Tag] {
        guard case let .edit(current) = mode else { return all }
        var forbidden: Set<UUID> = [current.id]
        var stack = current.children
        while let t = stack.popLast() { forbidden.insert(t.id); stack.append(contentsOf: t.children) }
        return all.filter { !forbidden.contains($0.id) }
    }

    var body: some View {
        EditorScaffold(title: isEditing ? "Editar etiqueta" : "Nueva etiqueta",
                       confirmTitle: isEditing ? "Guardar" : "Crear",
                       canConfirm: canSave,
                       onCancel: { dismiss() },
                       onConfirm: save) {
            Form {
                Section("Nombre") {
                    HStack {
                        Circle()
                            .fill(Color(hex: colorHex))
                            .frame(width: 12, height: 12)
                            .accessibilityHidden(true)
                        TextField("Nombre de la etiqueta", text: $name)
                    }
                }
                Section("Color") { ColorSwatchPicker(selection: $colorHex) }
                if !parentOptions.isEmpty {
                    Section {
                        Picker("Etiqueta padre", selection: $parentID) {
                            Text("Ninguna").tag(UUID?.none)
                            ForEach(parentOptions) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                    } header: {
                        Text("Anidar en")
                    } footer: {
                        Text("Convierte esta etiqueta en subetiqueta de otra (#padre/hijo).")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(width: 440, height: 460)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            if case .edit(let t) = mode { name = t.name; colorHex = t.colorHex; parentID = t.parent?.id }
        }
    }

    private func save() {
        let parent = parentID.flatMap { id in all.first { $0.id == id } }
        switch mode {
        case .create:
            let key = EntityResolver.tagKey(name)
            let exists = all.contains { $0.deletedAt == nil && EntityResolver.tagKey($0.name) == key }
            if !exists, let tag = EntityResolver.tag(name, in: context, colorHex: colorHex) {
                tag.order = all.count
                tag.parent = parent
            }
        case .edit(let t):
            t.name = name; t.colorHex = colorHex; t.parent = parent
        }
        context.saveLogging()
        dismiss()
    }
}
