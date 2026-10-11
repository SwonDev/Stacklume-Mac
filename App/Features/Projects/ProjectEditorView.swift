import SwiftUI
import SwiftData
import StacklumeCore
import StacklumeDesignSystem

struct ProjectEditorView: View {
    enum Mode: Identifiable {
        case create
        case edit(Project)
        var id: String { switch self { case .create: "create"; case .edit(let p): p.id.uuidString } }
    }
    let mode: Mode

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Project.order) private var all: [Project]

    @State private var name = ""
    @State private var icon = "square.stack.3d.up.fill"
    @State private var colorHex = ColorPresets.all[0]
    @State private var didLoad = false

    private var isEditing: Bool { if case .edit = mode { return true }; return false }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        EditorScaffold(title: isEditing ? "Editar proyecto" : "Nuevo proyecto",
                       confirmTitle: isEditing ? "Guardar" : "Crear",
                       canConfirm: canSave,
                       onCancel: { dismiss() },
                       onConfirm: save) {
            Form {
                Section("Nombre") {
                    HStack {
                        Image(systemName: icon).foregroundStyle(Color(hex: colorHex))
                        TextField("Nombre del proyecto", text: $name)
                    }
                }
                Section("Color") { ColorSwatchPicker(selection: $colorHex) }
                Section("Icono") { IconPicker(selection: $icon, tint: Color(hex: colorHex)) }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(width: 460, height: 540)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            if case .edit(let p) = mode { name = p.name; icon = p.icon; colorHex = p.colorHex }
        }
    }

    private func save() {
        switch mode {
        case .create:
            // Dedup por nombre (sin may./tildes): no crear dos proyectos «Trabajo».
            let key = TagSanitizer.key(name)
            if !all.contains(where: { $0.deletedAt == nil && TagSanitizer.key($0.name) == key }) {
                context.insert(Project(name: name, icon: icon, colorHex: colorHex,
                                       order: all.filter { $0.deletedAt == nil }.count))
            }
        case .edit(let p):
            p.name = name; p.icon = icon; p.colorHex = colorHex; p.updatedAt = Date()
        }
        context.saveLogging()
        dismiss()
    }
}
