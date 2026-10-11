import SwiftUI
import SwiftData
import AppKit
import StacklumeCore
import StacklumeDesignSystem

/// Espacio de trabajo de un proyecto: un panel que reúne TODO lo de aquello que estás
/// construyendo — sus enlaces clave (repo, docs, deploy, paquetes…), una nota/scratchpad
/// y un estado (activo/en pausa/hecho). Un enlace puede estar aquí sin salir de su
/// colección. La pertenencia, la nota y el estado viven en `@AppStorage`
/// ([[ProjectWorkspaceStore]]), porque el modelo `Project` es de solo lectura.
struct ProjectWorkspaceView: View {
    let project: Project

    @Environment(\.themePalette) private var palette
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var context
    @AppStorage(ProjectWorkspaceStore.storageKey) private var workspaceJSON = ""
    @Query private var allLinks: [Bookmark]

    @State private var showPicker = false
    @State private var showEditor = false
    @State private var newTask = ""
    @State private var newCommand = ""
    @State private var pasteMessage: String?
    /// Tarea en edición en línea (toca su texto para editarlo, sin borrar y reescribir).
    @State private var editingTaskID: UUID?
    @State private var editingTaskText = ""
    @FocusState private var taskEditFocused: Bool
    /// Comando en edición en línea (por índice).
    @State private var editingCommandIndex: Int?
    @State private var editingCommandText = ""
    @FocusState private var commandEditFocused: Bool
    /// Campo de añadir enfocado (toca cualquier parte de la fila para escribir).
    @FocusState private var focusedAddField: AddField?
    /// Modo vista previa de las notas (Markdown renderizado en vez del editor).
    @State private var notePreview = false

    private enum AddField: Hashable { case task, command }

    private var color: Color { Color(hex: project.colorHex) }

    private var workspace: ProjectWorkspace {
        ProjectWorkspaceStore.workspace(for: project.id, in: workspaceJSON)
    }

    /// Enlaces del proyecto resueltos desde sus ids, en el orden de adición y sin los
    /// que ya estén borrados o no existan.
    private var links: [Bookmark] {
        let active = Dictionary(
            allLinks.filter { $0.deletedAt == nil }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        return workspace.linkIDs.compactMap { active[$0] }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                headerCard
                tasksSection
                linksSection
                commandsSection
                noteCard
            }
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WindowBackground())
        .navigationTitle(project.name)
        .toolbar {
            ToolbarItem {
                Button("Añadir enlaces", systemImage: "plus") { showPicker = true }
                    .themedHelp("Buscar y añadir enlaces de tu biblioteca a este proyecto")
            }
            ToolbarItem {
                Button("Editar proyecto", systemImage: "pencil") { showEditor = true }
                    .themedHelp("Cambiar el nombre, icono o color del proyecto")
            }
        }
        .sheet(isPresented: $showEditor) { ProjectEditorView(mode: .edit(project)) }
        .sheet(isPresented: $showPicker) {
            ProjectLinkPickerView(projectName: project.name, initialSelection: workspace.linkIDs) { ids in
                workspaceJSON = ProjectWorkspaceStore.updating(workspaceJSON, for: project.id) { $0.linkIDs = ids }
            }
            .themedSheet(palette)
        }
    }

    // MARK: - Cabecera (icono, nombre, estado, abrir todos)

    private var headerCard: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(color.gradient)
                .frame(width: 56, height: 56)
                .overlay(Image(systemName: project.icon)
                    .scaledFont(24, weight: .semibold, scalesWithText: false).foregroundStyle(.white)
                    .accessibilityHidden(true))
                .shadow(color: color.opacity(0.35), radius: 6, y: 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(project.name)
                    .stacklumeFont(.title2.weight(.bold))
                    .foregroundStyle(palette.textPrimary)
                    .stacklumeLineLimit(2)
                    .stacklumeMinimumScaleFactor(0.75)
                statusMenu
            }

            Spacer(minLength: DesignSystem.Spacing.sm)

            Button {
                openAll()
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.title3)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
            }
            .stacklumeButton()
            .disabled(links.isEmpty)
            .themedHelp(links.isEmpty ? "Añade enlaces para abrirlos todos a la vez"
                                : "Abre los \(links.count) enlaces del proyecto en el navegador")
            .accessibilityLabel("Abrir todos los enlaces del proyecto")
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
            .strokeBorder(color.opacity(0.22), lineWidth: 1))
    }

    private var statusMenu: some View {
        Menu {
            ForEach(ProjectStatus.allCases) { status in
                Button {
                    workspaceJSON = ProjectWorkspaceStore.updating(workspaceJSON, for: project.id) { $0.status = status }
                } label: {
                    Label(status.displayName, systemImage: status.symbol)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: workspace.status.symbol)
                Text(workspace.status.displayName)
                Image(systemName: "chevron.down").scaledFont(9, weight: .bold, scalesWithText: false)
            }
            .stacklumeFont(.caption.weight(.semibold))
            .readableTint(Color(hex: workspace.status.colorHex), palette: palette, on: [palette.surface],
                          overlay: Color(hex: workspace.status.colorHex).opacity(0.14))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(hex: workspace.status.colorHex).opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .themedHelp("Cambiar el estado del proyecto")
    }

    // MARK: - Notas / scratchpad

    private var noteBinding: Binding<String> {
        Binding(
            get: { workspace.note },
            set: { new in
                workspaceJSON = ProjectWorkspaceStore.updating(workspaceJSON, for: project.id) { $0.note = new }
            })
    }

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack {
                Label("Notas", systemImage: "note.text")
                    .stacklumeFont(.headline)
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 0)
                if !workspace.note.isEmpty {
                    Button { withAnimation(.snappy) { notePreview.toggle() } } label: {
                        Label(notePreview ? "Editar" : "Vista previa",
                              systemImage: notePreview ? "pencil" : "eye")
                            .stacklumeFont(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.accent)
                    .themedHelp(notePreview ? "Volver al editor de texto" : "Ver la nota con Markdown renderizado")
                }
            }
            Group {
                if notePreview && !workspace.note.isEmpty {
                    markdownText(workspace.note)
                        .stacklumeFont(.body)
                        .foregroundStyle(palette.textPrimary)
                        .tint(palette.accent)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                        .padding(12)
                } else {
                    ZStack(alignment: .topLeading) {
                        if workspace.note.isEmpty {
                            Text("Apunta aquí lo que necesites: pendientes, ideas, comandos, decisiones del proyecto… (admite Markdown).")
                                .stacklumeFont(.body)
                                .foregroundStyle(palette.textSecondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 12)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: noteBinding)
                            .stacklumeFont(.body)
                            .foregroundStyle(palette.textPrimary)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .frame(minHeight: 120)
                    }
                }
            }
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.border.opacity(0.4), lineWidth: 1))
        }
    }

    /// Renderiza el texto de la nota como Markdown en línea (negrita, cursiva, código,
    /// enlaces clicables), conservando saltos de línea. Para una vista previa legible
    /// del scratchpad sin perder lo que escribiste si no es Markdown válido.
    private func markdownText(_ raw: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(raw)
    }

    // MARK: - Enlaces del proyecto

    private var linksSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Enlaces (\(links.count))", systemImage: "link")
                        .stacklumeFont(.headline)
                        .foregroundStyle(palette.textPrimary)
                    Spacer(minLength: 0)
                    Button("Pegar enlace", systemImage: "doc.on.clipboard") { pasteLink() }
                        .stacklumeButton(prominent: false, compact: true)
                        .themedHelp("Guarda el enlace (o comando) del portapapeles y lo añade al proyecto")
                    Button("Añadir enlaces", systemImage: "plus") { showPicker = true }
                        .stacklumeButton(compact: true)
                }
                .stacklumeGlassContainer(spacing: DesignSystem.Spacing.xs)
                if let pasteMessage {
                    Text(pasteMessage)
                        .stacklumeFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .transition(.opacity)
                }
            }

            if links.isEmpty {
                Text("Aún no has añadido enlaces a este proyecto. Pulsa «Añadir enlaces» para reunir aquí el repositorio, la documentación, los paquetes y todo lo que uses mientras lo construyes.")
                    .stacklumeFont(.callout)
                    .foregroundStyle(palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignSystem.Spacing.md)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                VStack(spacing: 2) {
                    ForEach(links) { link in
                        NavigationLink {
                            LinkDetailView(link: link)
                        } label: {
                            LinkRowView(link: link)
                        }
                        .buttonStyle(.plain)
                        .draggable(link.id.uuidString) {
                            LinkRowView(link: link).frame(width: 320)
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard let dragged = items.first else { return false }
                            moveLink(fromID: dragged, toID: link.id)
                            return true
                        }
                        .contextMenu {
                            Button("Abrir en el navegador", systemImage: "safari") { open(link) }
                            Divider()
                            Button("Subir", systemImage: "arrow.up") { moveLinkUp(link) }
                            Button("Bajar", systemImage: "arrow.down") { moveLinkDown(link) }
                            Divider()
                            Button("Quitar del proyecto", systemImage: "minus.circle", role: .destructive) {
                                remove(link)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Tareas (checklist — NO kanban)

    private var tasksSection: some View {
        let tasks = workspace.tasks
        let done = tasks.filter(\.done).count
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Label(tasks.isEmpty ? "Tareas" : "Tareas (\(done)/\(tasks.count))", systemImage: "checklist")
                .stacklumeFont(.headline)
                .foregroundStyle(palette.textPrimary)
            if !tasks.isEmpty {
                VStack(spacing: 3) {
                    ForEach(tasks) { task in taskRow(task) }
                }
            }
            addRow(placeholder: "Nueva tarea", text: $newTask, field: .task, onAdd: addTask)
        }
    }

    private func taskRow(_ task: ProjectTask) -> some View {
        HStack(spacing: 10) {
            Button { toggleTask(task) } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.done ? Color(hex: "#34D399") : palette.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.done ? "Marcar tarea como pendiente" : "Marcar tarea como hecha")

            if editingTaskID == task.id {
                TextField("Tarea", text: $editingTaskText)
                    .textFieldStyle(.plain)
                    .focused($taskEditFocused)
                    .onSubmit { commitTaskEdit() }
                    .onChange(of: taskEditFocused) { _, focused in if !focused { commitTaskEdit() } }
            } else {
                Text(task.text)
                    .foregroundStyle(task.done ? palette.textSecondary : palette.textPrimary)
                    .strikethrough(task.done)
                    .stacklumeLineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { startEditingTask(task) }
                    .themedHelp("Toca para editar · arrastra para reordenar")
            }

            Button { deleteTask(task) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(palette.textSecondary)
            }
            .buttonStyle(.plain)
            .themedHelp("Eliminar tarea")
            .accessibilityLabel("Eliminar tarea")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .draggable(task.id.uuidString) {
            Text(task.text)
                .stacklumeLineLimit(1)
                .padding(8)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first else { return false }
            moveTask(fromID: dragged, toID: task.id)
            return true
        }
        .contextMenu {
            Button("Editar", systemImage: "pencil") { startEditingTask(task) }
            Button(task.done ? "Marcar pendiente" : "Marcar hecha",
                   systemImage: task.done ? "circle" : "checkmark.circle") { toggleTask(task) }
            Divider()
            Button("Subir", systemImage: "arrow.up") { moveTaskUp(task) }
            Button("Bajar", systemImage: "arrow.down") { moveTaskDown(task) }
            Divider()
            Button("Eliminar", systemImage: "trash", role: .destructive) { deleteTask(task) }
        }
    }

    // MARK: - Comandos rápidos (copiar al portapapeles)

    private var commandsSection: some View {
        let commands = workspace.commands
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Label("Comandos", systemImage: "terminal")
                .stacklumeFont(.headline)
                .foregroundStyle(palette.textPrimary)
            if !commands.isEmpty {
                VStack(spacing: 4) {
                    ForEach(Array(commands.enumerated()), id: \.offset) { index, command in
                        commandRow(index: index, command: command)
                    }
                }
            }
            addRow(placeholder: "p. ej. npm run dev", text: $newCommand, field: .command, onAdd: addCommand, monospaced: true)
        }
    }

    private func commandRow(index: Int, command: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(palette.accent)
                .accessibilityHidden(true)
            if editingCommandIndex == index {
                TextField("Comando", text: $editingCommandText)
                    .textFieldStyle(.plain)
                    .stacklumeFont(.callout.monospaced())
                    .focused($commandEditFocused)
                    .onSubmit { commitCommandEdit() }
                    .onChange(of: commandEditFocused) { _, focused in if !focused { commitCommandEdit() } }
            } else {
                Text(command)
                    .stacklumeFont(.callout.monospaced())
                    .foregroundStyle(palette.textPrimary)
                    .stacklumeLineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { startEditingCommand(index: index, command: command) }
                    .themedHelp("Toca para editar")
            }
            Button { copyCommand(command) } label: {
                Image(systemName: "doc.on.doc").foregroundStyle(palette.textSecondary)
            }
            .buttonStyle(.plain)
            .themedHelp("Copiar comando")
            .accessibilityLabel("Copiar comando")
            Button { deleteCommand(at: index) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(palette.textSecondary)
            }
            .buttonStyle(.plain)
            .themedHelp("Eliminar comando")
            .accessibilityLabel("Eliminar comando")
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(palette.border.opacity(0.3), lineWidth: 1))
        .contextMenu {
            Button("Editar", systemImage: "pencil") { startEditingCommand(index: index, command: command) }
            Button("Copiar", systemImage: "doc.on.doc") { copyCommand(command) }
            Divider()
            Button("Subir", systemImage: "arrow.up") { moveCommandUp(index) }
            Button("Bajar", systemImage: "arrow.down") { moveCommandDown(index) }
            Divider()
            Button("Eliminar", systemImage: "trash", role: .destructive) { deleteCommand(at: index) }
        }
    }

    /// Fila de entrada reutilizable para añadir una tarea o un comando. Toda la fila es
    /// zona de toque: pulsar en cualquier punto enfoca el campo (sin apuntar al texto).
    private func addRow(placeholder: LocalizedStringKey, text: Binding<String>, field: AddField,
                        onAdd: @escaping () -> Void, monospaced: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill").foregroundStyle(palette.accent)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .stacklumeFont(monospaced ? .callout.monospaced() : .body)
                .focused($focusedAddField, equals: field)
                .onSubmit(onAdd)
            if !text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Añadir", action: onAdd)
                    .buttonStyle(.plain)
                    .stacklumeFont(.callout.weight(.semibold))
                    .foregroundStyle(palette.accent)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(palette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { focusedAddField = field }
    }

    // MARK: - Acciones

    /// Aplica una mutación al workspace del proyecto (persistida en @AppStorage).
    private func update(_ transform: @escaping (inout ProjectWorkspace) -> Void) {
        workspaceJSON = ProjectWorkspaceStore.updating(workspaceJSON, for: project.id, transform)
    }

    private func addTask() {
        let text = newTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        update { $0.tasks.append(ProjectTask(text: text)) }
        newTask = ""
    }

    private func toggleTask(_ task: ProjectTask) {
        update { ws in
            if let i = ws.tasks.firstIndex(where: { $0.id == task.id }) { ws.tasks[i].done.toggle() }
        }
    }

    private func deleteTask(_ task: ProjectTask) {
        withAnimation(.snappy) { update { $0.tasks.removeAll { $0.id == task.id } } }
    }

    private func startEditingTask(_ task: ProjectTask) {
        editingTaskText = task.text
        editingTaskID = task.id
        taskEditFocused = true
    }

    /// Guarda el texto editado de la tarea. Si queda vacío, la elimina (atajo natural).
    private func commitTaskEdit() {
        guard let id = editingTaskID else { return }
        let text = editingTaskText.trimmingCharacters(in: .whitespacesAndNewlines)
        update { ws in
            guard let i = ws.tasks.firstIndex(where: { $0.id == id }) else { return }
            if text.isEmpty { ws.tasks.remove(at: i) } else { ws.tasks[i].text = text }
        }
        editingTaskID = nil
    }

    /// Reordena una tarea soltándola sobre otra (arrastrar para priorizar).
    private func moveTask(fromID: String, toID: UUID) {
        guard let from = UUID(uuidString: fromID), from != toID else { return }
        withAnimation(.snappy) {
            update { ws in
                guard let src = ws.tasks.firstIndex(where: { $0.id == from }) else { return }
                let item = ws.tasks.remove(at: src)
                if let dst = ws.tasks.firstIndex(where: { $0.id == toID }) {
                    ws.tasks.insert(item, at: dst)
                } else {
                    ws.tasks.append(item)
                }
            }
        }
    }

    /// Reordena un enlace soltándolo sobre otro.
    private func moveLink(fromID: String, toID: UUID) {
        guard let from = UUID(uuidString: fromID), from != toID else { return }
        withAnimation(.snappy) {
            update { ws in
                guard let src = ws.linkIDs.firstIndex(of: from) else { return }
                ws.linkIDs.remove(at: src)
                if let dst = ws.linkIDs.firstIndex(of: toID) {
                    ws.linkIDs.insert(from, at: dst)
                } else {
                    ws.linkIDs.append(from)
                }
            }
        }
    }

    private func moveTaskUp(_ task: ProjectTask) {
        withAnimation(.snappy) {
            update { ws in
                guard let i = ws.tasks.firstIndex(where: { $0.id == task.id }), i > 0 else { return }
                ws.tasks.swapAt(i, i - 1)
            }
        }
    }

    private func moveTaskDown(_ task: ProjectTask) {
        withAnimation(.snappy) {
            update { ws in
                guard let i = ws.tasks.firstIndex(where: { $0.id == task.id }), i < ws.tasks.count - 1 else { return }
                ws.tasks.swapAt(i, i + 1)
            }
        }
    }

    private func moveLinkUp(_ link: Bookmark) {
        withAnimation(.snappy) {
            update { ws in
                guard let i = ws.linkIDs.firstIndex(of: link.id), i > 0 else { return }
                ws.linkIDs.swapAt(i, i - 1)
            }
        }
    }

    private func moveLinkDown(_ link: Bookmark) {
        withAnimation(.snappy) {
            update { ws in
                guard let i = ws.linkIDs.firstIndex(of: link.id), i < ws.linkIDs.count - 1 else { return }
                ws.linkIDs.swapAt(i, i + 1)
            }
        }
    }

    private func addCommand() {
        let command = newCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        update { $0.commands.append(command) }
        newCommand = ""
    }

    private func copyCommand(_ command: String) {
        NSPasteboard.copyString(command)
    }

    private func deleteCommand(at index: Int) {
        withAnimation(.snappy) {
            update { ws in if ws.commands.indices.contains(index) { ws.commands.remove(at: index) } }
        }
    }

    private func startEditingCommand(index: Int, command: String) {
        editingCommandText = command
        editingCommandIndex = index
        commandEditFocused = true
    }

    private func commitCommandEdit() {
        guard let index = editingCommandIndex else { return }
        let text = editingCommandText.trimmingCharacters(in: .whitespacesAndNewlines)
        update { ws in
            guard ws.commands.indices.contains(index) else { return }
            if text.isEmpty { ws.commands.remove(at: index) } else { ws.commands[index] = text }
        }
        editingCommandIndex = nil
    }

    private func moveCommandUp(_ index: Int) {
        withAnimation(.snappy) {
            update { ws in guard ws.commands.indices.contains(index), index > 0 else { return }; ws.commands.swapAt(index, index - 1) }
        }
    }

    private func moveCommandDown(_ index: Int) {
        withAnimation(.snappy) {
            update { ws in guard ws.commands.indices.contains(index), index < ws.commands.count - 1 else { return }; ws.commands.swapAt(index, index + 1) }
        }
    }

    /// Captura rápida: guarda el enlace (o comando) del portapapeles en la biblioteca
    /// —si es nuevo— y lo añade al proyecto. Reutiliza el alta común ([[LinkIngest]],
    /// idempotente y command-aware), igual que el guardado rápido global.
    private func pasteLink() {
        guard let saveable = ClipboardLink.currentSaveable() else {
            showPasteMessage("No hay ningún enlace ni comando en el portapapeles")
            return
        }
        let bookmark = LinkIngest.ingestLink(urlString: saveable, in: context, aiEnrich: true)
        let id = bookmark.id
        let already = workspace.linkIDs.contains(id)
        withAnimation(.snappy) {
            update { ws in if !ws.linkIDs.contains(id) { ws.linkIDs.append(id) } }
        }
        showPasteMessage(already ? "Ese enlace ya estaba en el proyecto" : "Añadido al proyecto")
    }

    private func showPasteMessage(_ text: String) {
        withAnimation(.snappy) { pasteMessage = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.snappy) { pasteMessage = nil }
        }
    }

    private func open(_ link: Bookmark) {
        if let url = StacklumeAutomationPolicy.openableStoredURL(link.url) { openURL(url) }
    }

    private func openAll() {
        for link in links {
            if let url = StacklumeAutomationPolicy.openableStoredURL(link.url) { openURL(url) }
        }
    }

    private func remove(_ link: Bookmark) {
        let id = link.id
        withAnimation(.snappy) {
            workspaceJSON = ProjectWorkspaceStore.updating(workspaceJSON, for: project.id) {
                $0.linkIDs.removeAll { $0 == id }
            }
        }
    }
}

/// Selector de enlaces para añadir/quitar de un proyecto. Lista buscable con
/// multiselección; conserva el orden de adición. Devuelve los ids elegidos por `onSave`.
struct ProjectLinkPickerView: View {
    let projectName: String
    let initialSelection: [UUID]
    let onSave: ([UUID]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @Query(sort: \Bookmark.createdAt, order: .reverse) private var allLinks: [Bookmark]

    @State private var selected: [UUID] = []
    @State private var search = ""
    @State private var didLoad = false

    private var activeLinks: [Bookmark] { allLinks.filter { $0.deletedAt == nil } }

    private var filtered: [Bookmark] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return activeLinks }
        return activeLinks.filter {
            $0.title.lowercased().contains(query) || $0.url.lowercased().contains(query)
        }
    }

    var body: some View {
        EditorScaffold(title: "Añadir a «\(projectName)»", confirmTitle: "Hecho",
                       onCancel: { dismiss() }, onConfirm: { onSave(selected); dismiss() }) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(palette.textSecondary)
                    TextField("Buscar enlaces", text: $search)
                        .textFieldStyle(.plain)
                }
                .padding(10)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(DesignSystem.Spacing.md)

                if activeLinks.isEmpty {
                    Spacer()
                    Text("No hay enlaces que añadir todavía.")
                        .foregroundStyle(palette.textSecondary)
                    Spacer()
                } else {
                    List {
                        ForEach(filtered) { link in
                            Button { toggle(link.id) } label: { row(link) }
                                .buttonStyle(.plain)
                                .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .frame(width: 540, height: 620)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            // Conserva solo los ids que sigan existiendo, en su orden actual.
            let existing = Set(activeLinks.map(\.id))
            selected = initialSelection.filter { existing.contains($0) }
        }
    }

    private func row(_ link: Bookmark) -> some View {
        let isSelected = selected.contains(link.id)
        return HStack(spacing: DesignSystem.Spacing.sm) {
            PlatformBadge(platform: link.platform, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(link.title.isEmpty ? link.url : link.title)
                    .foregroundStyle(palette.textPrimary).stacklumeLineLimit(1)
                Text(link.url.urlHost)
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary).stacklumeLineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? palette.accent : palette.textSecondary.opacity(0.5))
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private func toggle(_ id: UUID) {
        if let index = selected.firstIndex(of: id) {
            selected.remove(at: index)
        } else {
            selected.append(id)   // conserva el orden de adición
        }
    }
}
