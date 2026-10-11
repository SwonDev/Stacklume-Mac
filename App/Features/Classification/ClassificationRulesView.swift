import SwiftUI
import SwiftData
import StacklumeCore
import StacklumeDesignSystem

/// Gestión (CRUD) de las reglas de auto-clasificación en Mac.
///
/// Portada del iPhone (`ClassificationRulesView`): misma lista de reglas
/// (nombre, condición → acción, activa/inactiva, prioridad por `order`) y mismo
/// editor en hoja. Adaptada al patrón de macOS: gestos de deslizar y `EditButton`
/// se sustituyen por menú contextual (editar, activar/desactivar, subir/bajar,
/// eliminar) sobre el fondo de ventana con profundidad. Reutiliza el motor
/// `ClassificationEngine`, que ya aplica estas reglas al guardar enlaces.
struct ClassificationRulesView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.themePalette) private var palette
    @Query(sort: \ClassificationRule.order) private var rules: [ClassificationRule]
    @Query private var settingsList: [AppSettings]

    @State private var editor: RuleEditorView.Mode?
    @State private var pendingDelete: ClassificationRule?

    private var confirmBeforeDelete: Bool { settingsList.first?.confirmBeforeDelete ?? true }

    var body: some View {
        Group {
            if rules.isEmpty {
                EmptyStateView(icon: "wand.and.stars",
                               title: "Reglas",
                               message: SidebarSection.rules.emptyMessage,
                               actionTitle: "Nueva regla",
                               action: { editor = .create })
            } else {
                ScrollView {
                    LazyVStack(spacing: DesignSystem.Spacing.sm) {
                        ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                            RuleRow(rule: rule)
                                .contextMenu {
                                    Button("Editar", systemImage: "pencil") { editor = .edit(rule) }
                                    Button(rule.isActive ? "Desactivar" : "Activar",
                                           systemImage: rule.isActive ? "pause.circle" : "play.circle") {
                                        toggleActive(rule)
                                    }
                                    Divider()
                                    Button("Subir", systemImage: "arrow.up") { move(rule, by: -1) }
                                        .disabled(index == 0)
                                    Button("Bajar", systemImage: "arrow.down") { move(rule, by: 1) }
                                        .disabled(index == rules.count - 1)
                                    Divider()
                                    Button("Eliminar", systemImage: "trash", role: .destructive) {
                                        requestDelete(rule)
                                    }
                                }
                                .onTapGesture(count: 2) { editor = .edit(rule) }
                                .themedHelp("Doble clic para editar · Clic derecho para más opciones")
                                .accessibilityHint("Doble clic para editar. Clic derecho para opciones.")
                        }
                    }
                    .padding(DesignSystem.Spacing.lg)
                }
                .background(WindowBackground())
            }
        }
        .navigationTitle("Reglas")
        .toolbar {
            ToolbarItem {
                Button("Nueva regla", systemImage: "plus") { editor = .create }
                    .themedHelp("Nueva regla de clasificación automática")
                    .accessibilityLabel("Nueva regla de clasificación")
            }
        }
        .sheet(item: $editor) { RuleEditorView(mode: $0).themedSheet(palette) }
        .confirmationDialog("¿Eliminar esta regla?",
                            isPresented: deleteDialogBinding,
                            titleVisibility: .visible,
                            presenting: pendingDelete) { rule in
            Button("Eliminar", role: .destructive) { performDelete(rule) }
            Button("Cancelar", role: .cancel) { pendingDelete = nil }
        } message: { rule in
            Text(rule.name.isEmpty ? "Regla" : rule.name)
        }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func toggleActive(_ rule: ClassificationRule) {
        rule.isActive.toggle()
        context.saveLogging()
    }

    /// Reordena la regla una posición (prioridad por `order`), reescribiendo todos
    /// los índices para mantenerlos contiguos.
    private func move(_ rule: ClassificationRule, by delta: Int) {
        guard let current = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        let target = current + delta
        guard rules.indices.contains(target) else { return }
        var ordered = rules
        ordered.swapAt(current, target)
        for (index, item) in ordered.enumerated() { item.order = index }
        withAnimation(.snappy) { context.saveLogging() }
    }

    private func requestDelete(_ rule: ClassificationRule) {
        if confirmBeforeDelete {
            pendingDelete = rule
        } else {
            performDelete(rule)
        }
    }

    private func performDelete(_ rule: ClassificationRule) {
        withAnimation(.snappy) { context.delete(rule) }
        context.saveLogging()
        pendingDelete = nil
    }
}

/// Fila de una regla: nombre, resumen «condición “valor” → acción» y estado.
private struct RuleRow: View {
    let rule: ClassificationRule
    @Environment(\.themePalette) private var palette

    /// Resumen legible de las condiciones, unidas con «y» (TODAS) u «o» (ALGUNA).
    private var conditionSummary: String {
        let conds = rule.allConditions.filter {
            !$0.value.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let separator = rule.matchMode == .all ? " y " : " o "
        return conds.map { "\($0.type.displayName) “\($0.value)”" }.joined(separator: separator)
    }

    /// Resumen de las acciones (una o varias) de la regla.
    private var actionSummary: String {
        rule.allActions.filter { !$0.value.isEmpty }
            .map { $0.type.displayName }
            .joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.accent.gradient)
                .frame(width: 40, height: 40)
                .overlay(Image(systemName: "wand.and.stars")
                    .scaledFont(17, weight: .semibold, scalesWithText: false).foregroundStyle(.white))
                .opacity(rule.isActive ? 1 : 0.45)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name.isEmpty ? "Regla" : rule.name)
                    .stacklumeFont(.body.weight(.semibold))
                    .foregroundStyle(palette.textPrimary)
                    .stacklumeLineLimit(1)
                Text("\(conditionSummary) → \(actionSummary)")
                    .stacklumeFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .stacklumeLineLimit(1)
            }
            Spacer(minLength: 0)

            if !rule.isActive {
                Text("Inactiva")
                    .stacklumeFont(.caption2.weight(.medium))
                    .readableTint(palette.textSecondary, palette: palette, on: [palette.surface],
                                  overlay: palette.textSecondary.opacity(0.12))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(palette.textSecondary.opacity(0.12),
                                in: Capsule())
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
            .strokeBorder(palette.accent.opacity(0.16), lineWidth: 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel({
            let displayName = rule.name.isEmpty ? "Regla" : rule.name
            let estado = rule.isActive ? "activa" : "inactiva"
            return "\(displayName), \(conditionSummary) → \(actionSummary), \(estado)"
        }())
    }
}

/// Alta y edición de una regla de clasificación: nombre, condición (tipo + valor)
/// y acción (asignar categoría o añadir etiqueta, eligiendo el destino).
struct RuleEditorView: View {
    enum Mode: Identifiable {
        case create
        case edit(ClassificationRule)
        var id: String { switch self { case .create: "create"; case .edit(let r): r.id.uuidString } }
    }
    let mode: Mode

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette

    @Query(filter: #Predicate<BookmarkCategory> { $0.deletedAt == nil }, sort: \BookmarkCategory.order)
    private var categories: [BookmarkCategory]
    @Query(filter: #Predicate<Tag> { $0.deletedAt == nil }, sort: \Tag.order)
    private var tags: [Tag]
    @Query(sort: \ClassificationRule.order) private var rules: [ClassificationRule]

    @State private var name = ""
    @State private var conditions: [RuleConditionSpec] = [RuleConditionSpec()]
    @State private var matchMode: RuleMatchMode = .all
    @State private var actions: [RuleActionSpec] = [RuleActionSpec()]
    @State private var isActive = true
    @State private var didLoad = false
    @State private var destinationPicker: RuleDestinationPickerRequest?

    private var isEditing: Bool { if case .edit = mode { return true }; return false }

    private var canSave: Bool {
        conditions.contains { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            && actions.contains { !$0.value.isEmpty }
    }

    var body: some View {
        // Marco TEMATIZADO común (ver [[EditorScaffold]]): sin la barra gris del NavigationStack.
        EditorScaffold(
            title: isEditing ? "Editar regla" : "Nueva regla",
            confirmTitle: isEditing ? "Guardar" : "Crear",
            canConfirm: canSave,
            onCancel: { dismiss() },
            onConfirm: { save() }
        ) {
            Form {
                Section("Nombre") {
                    TextField("Nombre de la regla", text: $name)
                }
                Section {
                    if conditions.count > 1 {
                        Picker("Coincidencia", selection: $matchMode) {
                            ForEach(RuleMatchMode.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    ForEach($conditions) { $cond in
                        HStack(spacing: 8) {
                            Picker("Si", selection: $cond.type) {
                                ForEach(RuleConditionType.allCases) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            TextField(cond.type == .platform ? "youtube, github…" : "valor", text: $cond.value)
                                .autocorrectionDisabled()
                            if conditions.count > 1 {
                                Button(role: .destructive) { removeCondition(cond.id) } label: {
                                    Image(systemName: "minus.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.red)
                                .themedHelp("Quitar esta condición")
                                .accessibilityLabel("Quitar esta condición")
                            }
                        }
                    }
                    Button("Añadir condición", systemImage: "plus.circle") {
                        conditions.append(RuleConditionSpec(type: conditions.last?.type ?? .domain, value: ""))
                    }
                    .themedHelp("Añadir otra condición a esta regla")
                } header: {
                    Text(conditions.count > 1 ? "Condiciones" : "Condición")
                }
                Section {
                    ForEach($actions) { $action in
                        actionRow($action)
                    }
                    Button("Añadir acción", systemImage: "plus.circle") {
                        actions.append(RuleActionSpec(type: .addTag, value: ""))
                    }
                    .themedHelp("Añadir otra acción a esta regla")
                } header: {
                    Text(actions.count > 1 ? "Acciones" : "Acción")
                }
                Section {
                    Toggle("Regla activa", isOn: $isActive)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(width: 460, height: 500)
        .onAppear(perform: loadIfNeeded)
        .sheet(item: $destinationPicker) { request in
            let options: [RuleDestinationOption] = request.type == .setCategory
                ? categories.map {
                    RuleDestinationOption(id: $0.id, name: $0.name,
                                          icon: $0.icon, colorHex: $0.colorHex)
                }
                : tags.map {
                    RuleDestinationOption(id: $0.id, name: $0.name,
                                          icon: "tag.fill", colorHex: $0.colorHex)
                }
            RuleDestinationPickerSheet(
                title: request.type == .setCategory ? "Elegir colección" : "Elegir etiqueta",
                options: options
            ) { id in
                guard let index = actions.firstIndex(where: { $0.id == request.id }) else { return }
                actions[index].value = id.uuidString
                destinationPicker = nil
            }
            .themedSheet(palette)
        }
    }

    /// Fila de una acción: tipo (categoría/etiqueta) + destino, y quitar (si hay más de una).
    @ViewBuilder
    private func actionRow(_ action: Binding<RuleActionSpec>) -> some View {
        HStack(spacing: 8) {
            // Cambiar el tipo resetea el destino (un id de categoría no vale para una etiqueta).
            Picker("Entonces", selection: Binding(
                get: { action.wrappedValue.type },
                set: { action.wrappedValue.type = $0; action.wrappedValue.value = "" })) {
                ForEach(RuleActionType.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Button {
                destinationPicker = RuleDestinationPickerRequest(
                    id: action.wrappedValue.id, type: action.wrappedValue.type)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: destinationIcon(for: action.wrappedValue))
                    Text(destinationName(for: action.wrappedValue))
                        .stacklumeLineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            if actions.count > 1 {
                Button(role: .destructive) {
                    actions.removeAll { $0.id == action.wrappedValue.id }
                } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .themedHelp("Quitar esta acción")
                .accessibilityLabel("Quitar esta acción")
            }
        }
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        if case let .edit(rule) = mode {
            name = rule.name
            conditions = rule.allConditions
            if conditions.isEmpty { conditions = [RuleConditionSpec()] }
            matchMode = rule.matchMode
            actions = rule.allActions
            if actions.isEmpty { actions = [RuleActionSpec()] }
            isActive = rule.isActive
        }
    }

    private func destinationName(for action: RuleActionSpec) -> String {
        guard let id = UUID(uuidString: action.value) else { return "Elegir…" }
        if action.type == .setCategory {
            return categories.first(where: { $0.id == id })?.name ?? "Elegir…"
        }
        return tags.first(where: { $0.id == id })?.name ?? "Elegir…"
    }

    private func destinationIcon(for action: RuleActionSpec) -> String {
        guard let id = UUID(uuidString: action.value) else {
            return action.type == .setCategory ? "folder" : "tag"
        }
        if action.type == .setCategory {
            return categories.first(where: { $0.id == id })?.icon ?? "folder"
        }
        return "tag.fill"
    }

    private func removeCondition(_ id: UUID) {
        conditions.removeAll { $0.id == id }
        if conditions.isEmpty { conditions = [RuleConditionSpec()] }
    }

    private func save() {
        // La primera condición/acción con valor es la primaria; el resto, adicionales.
        let validC = conditions.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        let validA = actions.filter { !$0.value.isEmpty }
        guard let firstC = validC.first, let firstA = validA.first else { return }
        let extraC = Array(validC.dropFirst())
        let extraA = Array(validA.dropFirst())
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let finalName = trimmed.isEmpty ? "\(firstC.type.displayName) \(firstC.value)" : trimmed
        let sig = signature(conditions: validC, mode: matchMode, actions: validA)
        switch mode {
        case .create:
            // Dedup: no crear una regla idéntica (mismo conjunto de condiciones + modo + acciones).
            if !rules.contains(where: { signature(of: $0) == sig }) {
                let rule = ClassificationRule(
                    name: finalName,
                    conditionType: firstC.type, conditionValue: firstC.value,
                    actionType: firstA.type, actionValue: firstA.value,
                    order: rules.count, isActive: isActive)
                rule.matchMode = matchMode
                rule.extraConditions = extraC
                rule.extraActions = extraA
                context.insert(rule)
            }
        case let .edit(rule):
            rule.name = finalName
            rule.conditionType = firstC.type
            rule.conditionValue = firstC.value
            rule.extraConditions = extraC
            rule.matchMode = matchMode
            rule.actionType = firstA.type
            rule.actionValue = firstA.value
            rule.extraActions = extraA
            rule.isActive = isActive
        }
        context.saveLogging()
        dismiss()
    }

    /// Firma estable de una regla (condiciones + modo + acciones, sin orden) para deduplicar.
    private func signature(of rule: ClassificationRule) -> String {
        signature(conditions: rule.allConditions, mode: rule.matchMode, actions: rule.allActions)
    }

    private func signature(conditions: [RuleConditionSpec], mode: RuleMatchMode,
                           actions: [RuleActionSpec]) -> String {
        let conds = conditions
            .filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "\($0.type.rawValue):\($0.value.lowercased().trimmingCharacters(in: .whitespaces))" }
            .sorted().joined(separator: "|")
        let acts = actions
            .filter { !$0.value.isEmpty }
            .map { "\($0.type.rawValue):\($0.value.lowercased())" }
            .sorted().joined(separator: "|")
        return "\(mode.rawValue)#\(conds)#\(acts)"
    }
}

private struct RuleDestinationPickerRequest: Identifiable {
    let id: UUID
    let type: RuleActionType
}

private struct RuleDestinationOption: Identifiable {
    let id: UUID
    let name: String
    let icon: String
    let colorHex: String
}

/// Selector buscable y perezoso para destinos de reglas. Evita construir `Picker` con todas las
/// colecciones/etiquetas, que en macOS es eager y se degrada con bibliotecas grandes.
private struct RuleDestinationPickerSheet: View {
    let title: String
    let options: [RuleDestinationOption]
    let onPick: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [RuleDestinationOption] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty ? options : options.filter { $0.name.localizedCaseInsensitiveContains(q) }
        return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        EditorScaffold(title: title, confirmTitle: "Cerrar", cancelTitle: nil,
                       onCancel: { dismiss() }, onConfirm: { dismiss() }) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(palette.textSecondary)
                    TextField("Buscar…", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                }
                .padding(10)
                .background(palette.surface,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(DesignSystem.Spacing.md)

                List(filtered) { option in
                    Button {
                        onPick(option.id)
                        dismiss()
                    } label: {
                        Label {
                            Text(option.name).stacklumeLineLimit(1)
                        } icon: {
                            Image(systemName: option.icon)
                                .foregroundStyle(Color(hex: option.colorHex))
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 380, height: 460)
        .task { searchFocused = true }
    }
}
