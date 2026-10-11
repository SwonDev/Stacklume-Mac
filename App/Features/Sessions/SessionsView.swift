import SwiftUI
import SwiftData
import StacklumeCore
import StacklumeDesignSystem

/// Sesiones de enlaces: grupos de marcadores que se abren todos a la vez.
/// Doble clic (o el botón «Abrir todos») lanza cada URL en el navegador.
/// Portada del iPhone; adaptada al patrón de 3 columnas y a los gestos de macOS.
struct SessionsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(\.themePalette) private var palette
    @Query(sort: \LinkSession.order) private var sessions: [LinkSession]
    @Query private var settingsList: [AppSettings]

    @State private var editor: SessionEditorView.Mode?
    @State private var pendingDelete: LinkSession?

    private let columns = [GridItem(.adaptive(minimum: 280), spacing: DesignSystem.Spacing.md)]

    private var confirmBeforeDelete: Bool { settingsList.first?.confirmBeforeDelete ?? true }

    var body: some View {
        Group {
            if sessions.isEmpty {
                EmptyStateView(icon: "rectangle.stack", title: "Sesiones",
                               message: SidebarSection.sessions.emptyMessage,
                               actionTitle: "Nueva sesión", action: { editor = .create })
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: DesignSystem.Spacing.md) {
                        ForEach(sessions) { session in
                            SessionCard(session: session, linkCount: activeLinks(session).count) {
                                openAll(session)
                            }
                            .contextMenu {
                                Button("Abrir todos", systemImage: "arrow.up.forward.app") {
                                    openAll(session)
                                }
                                Button("Editar", systemImage: "pencil") { editor = .edit(session) }
                                Button("Eliminar", systemImage: "trash", role: .destructive) {
                                    requestDelete(session)
                                }
                            }
                        }
                    }
                    .padding(DesignSystem.Spacing.lg)
                }
                .background(WindowBackground())
            }
        }
        .navigationTitle("Sesiones")
        .toolbar { ToolbarItem { Button("Nueva sesión", systemImage: "plus") { editor = .create }
                .themedHelp("Crear una nueva sesión de enlaces") } }
        .sheet(item: $editor) { SessionEditorView(mode: $0).themedSheet(palette) }
        .confirmationDialog("¿Eliminar esta sesión?",
                            isPresented: deleteDialogBinding,
                            titleVisibility: .visible,
                            presenting: pendingDelete) { session in
            Button("Eliminar", role: .destructive) { performDelete(session) }
            Button("Cancelar", role: .cancel) { pendingDelete = nil }
        } message: { session in
            Text("«\(session.name)». Los enlaces no se eliminan, solo la agrupación.")
        }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func activeLinks(_ session: LinkSession) -> [Bookmark] {
        session.links.filter { $0.deletedAt == nil }
    }

    /// Abre cada URL de la sesión en el navegador por defecto.
    private func openAll(_ session: LinkSession) {
        let links = activeLinks(session)
        guard !links.isEmpty else { return }
        for link in links {
            if let url = StacklumeAutomationPolicy.openableStoredURL(link.url) { openURL(url) }
        }
    }

    private func requestDelete(_ session: LinkSession) {
        if confirmBeforeDelete {
            pendingDelete = session
        } else {
            performDelete(session)
        }
    }

    private func performDelete(_ session: LinkSession) {
        withAnimation(.snappy) { context.delete(session) }
        context.saveLogging()
        pendingDelete = nil
    }
}

/// Tarjeta premium de una sesión: icono sobre su color, nombre, nº de enlaces y
/// una pista de acción. Doble clic abre todos los enlaces.
private struct SessionCard: View {
    let session: LinkSession
    let linkCount: Int
    let openAll: () -> Void

    @Environment(\.themePalette) private var palette
    private var color: Color { Color(hex: session.colorHex) }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(color.gradient)
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: session.icon)
                        .scaledFont(19, weight: .semibold, scalesWithText: false).foregroundStyle(.white)
                        .accessibilityHidden(true))
                    .shadow(color: color.opacity(0.35), radius: 5, y: 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name).stacklumeFont(.body.weight(.semibold))
                        .foregroundStyle(palette.textPrimary).stacklumeLineLimit(1)
                    Text("\(linkCount) \(linkCount == 1 ? "enlace" : "enlaces")")
                        .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                }
                Spacer(minLength: 0)
            }

            Button(action: openAll) {
                Label("Abrir todos", systemImage: "arrow.up.forward.app")
                    .stacklumeFont(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .stacklumeButton()
            .disabled(linkCount == 0)
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
            .strokeBorder(color.opacity(0.22), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: openAll)
        .accessibilityElement(children: .contain)
        .accessibilityHint("Haz doble clic para abrir todos los enlaces en el navegador")
    }
}

/// Alta y edición de una sesión de enlaces: nombre, color, icono y selección de
/// los enlaces que la componen.
struct SessionEditorView: View {
    enum Mode: Identifiable {
        case create
        case edit(LinkSession)
        var id: String { switch self { case .create: "create"; case .edit(let s): s.id.uuidString } }
    }
    let mode: Mode

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @Query(sort: \LinkSession.order) private var sessions: [LinkSession]
    @Query(filter: #Predicate<Bookmark> { $0.deletedAt == nil },
           sort: \Bookmark.createdAt, order: .reverse)
    private var activeLinks: [Bookmark]

    @State private var name = ""
    @State private var icon = "rectangle.stack.fill"
    @State private var colorHex = ColorPresets.all[7]
    @State private var selectedLinkIDs: Set<UUID> = []
    @State private var didLoad = false
    @State private var search = ""

    private var isEditing: Bool { if case .edit = mode { return true }; return false }
    private var filteredLinks: [Bookmark] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return activeLinks }
        return activeLinks.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.url.localizedCaseInsensitiveContains(query)
        }
    }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !selectedLinkIDs.isEmpty
    }

    var body: some View {
        // Marco TEMATIZADO común (ver [[EditorScaffold]]): sin la barra gris del NavigationStack.
        EditorScaffold(
            title: isEditing ? "Editar sesión" : "Nueva sesión",
            confirmTitle: isEditing ? "Guardar" : "Crear",
            canConfirm: canSave,
            onCancel: { dismiss() },
            onConfirm: { save() }
        ) {
            VStack(spacing: 0) {
                Form {
                    Section("Nombre") {
                        HStack {
                            Image(systemName: icon).foregroundStyle(Color(hex: colorHex))
                            TextField("Nombre de la sesión", text: $name)
                        }
                    }
                    Section("Color") { ColorSwatchPicker(selection: $colorHex) }
                    Section("Icono") { IconPicker(selection: $icon, tint: Color(hex: colorHex)) }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(height: 285)

                Divider().overlay(palette.border.opacity(0.4))

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(palette.textSecondary)
                    TextField("Buscar enlaces", text: $search).textFieldStyle(.plain)
                    Text("\(selectedLinkIDs.count) elegidos")
                        .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                }
                .padding(10)
                .background(palette.surface,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.sm)

                if activeLinks.isEmpty {
                    Spacer()
                    Text("No hay enlaces que añadir todavía.")
                        .foregroundStyle(palette.textSecondary)
                    Spacer()
                } else {
                    List(filteredLinks) { link in
                        Button {
                            toggle(link.id)
                        } label: {
                            HStack(spacing: DesignSystem.Spacing.sm) {
                                PlatformBadge(platform: link.platform, size: 26)
                                Text(link.title.isEmpty ? link.url : link.title)
                                    .foregroundStyle(palette.textPrimary).stacklumeLineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: selectedLinkIDs.contains(link.id)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedLinkIDs.contains(link.id)
                                                     ? palette.accent
                                                     : palette.textSecondary.opacity(0.5))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .frame(width: 480, height: 600)
        .onAppear(perform: loadIfNeeded)
    }

    private func toggle(_ id: UUID) {
        if selectedLinkIDs.contains(id) { selectedLinkIDs.remove(id) } else { selectedLinkIDs.insert(id) }
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        if case let .edit(session) = mode {
            name = session.name
            icon = session.icon
            colorHex = session.colorHex
            selectedLinkIDs = Set(session.links.map(\.id))
        }
    }

    private func save() {
        let chosen = activeLinks.filter { selectedLinkIDs.contains($0.id) }
        switch mode {
        case .create:
            // Dedup por nombre (sin may./tildes): no crear dos sesiones homónimas.
            let key = TagSanitizer.key(name)
            if !sessions.contains(where: { TagSanitizer.key($0.name) == key }) {
                context.insert(LinkSession(name: name, icon: icon, colorHex: colorHex,
                                           order: sessions.count, links: chosen))
            }
        case let .edit(session):
            session.name = name
            session.icon = icon
            session.colorHex = colorHex
            session.links = chosen
        }
        context.saveLogging()
        dismiss()
    }
}
