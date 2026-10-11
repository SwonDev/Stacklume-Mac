import SwiftUI
import SwiftData
import StacklumeCore
import StacklumeDesignSystem

/// Hoja para crear o editar un resaltado de un enlace (cita/fragmento + color).
///
/// Reusa el MODELO compartido `Highlight` del core (mismo que el iPhone): no
/// redefine ni añade campos. En el iPhone los resaltados se crean SIEMPRE como
/// cita manual escrita (un `TextField` + selector de color), no por selección de
/// texto en el lector; el Mac replica ese mismo flujo manual, que es robusto y
/// fiel al modelo de datos. Persiste vía `modelContext` y la relación
/// `Bookmark.highlights` (regla de borrado en cascada definida en el core).
struct HighlightEditorView: View {
    enum Mode: Identifiable {
        case create(Bookmark)
        case edit(Highlight)
        var id: String {
            switch self {
            case .create(let bookmark): "create-\(bookmark.id.uuidString)"
            case .edit(let highlight): "edit-\(highlight.id.uuidString)"
            }
        }
    }
    let mode: Mode

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var note = ""
    @State private var colorHex = ColorPresets.all[0]   // #D4A853 (dorado), mismo defecto que el iPhone
    @State private var didLoad = false

    private var isEditing: Bool { if case .edit = mode { return true }; return false }
    private var canSave: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        // Marco TEMATIZADO común (ver [[EditorScaffold]]): sin la barra gris del NavigationStack.
        EditorScaffold(
            title: isEditing ? "Editar resaltado" : "Nuevo resaltado",
            confirmTitle: isEditing ? "Guardar" : "Añadir",
            canConfirm: canSave,
            onCancel: { dismiss() },
            onConfirm: { save() }
        ) {
            Form {
                Section("Texto") {
                    TextField("Fragmento o cita…", text: $text, axis: .vertical)
                        .lineLimit(3...10)
                }
                Section("Nota (opcional)") {
                    TextField("Tu comentario sobre esta cita…", text: $note, axis: .vertical)
                        .lineLimit(2...8)
                }
                Section("Color") { ColorSwatchPicker(selection: $colorHex) }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(width: 460, height: 420)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            if case .edit(let highlight) = mode {
                text = highlight.text
                colorHex = highlight.colorHex
                note = HighlightNoteStore.note(for: highlight.id)
            }
        }
    }

    private func save() {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        switch mode {
        case .create(let bookmark):
            let highlight = Highlight(text: clean, colorHex: colorHex, bookmark: bookmark)
            context.insert(highlight)
            HighlightNoteStore.setNote(note, for: highlight.id)
            bookmark.updatedAt = Date()
        case .edit(let highlight):
            highlight.text = clean
            highlight.colorHex = colorHex
            HighlightNoteStore.setNote(note, for: highlight.id)
            highlight.bookmark?.updatedAt = Date()
        }
        context.saveLogging()
        dismiss()
    }
}
