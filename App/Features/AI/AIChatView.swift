import SwiftUI
import AppKit
import OSLog
import SwiftData
import Foundation
import StacklumeCore
import StacklumeDesignSystem

/// Buzón para enviar una pregunta al asistente desde OTRAS partes de la app (p. ej. el
/// botón «Preguntar a la IA» de la ficha de un enlace). La sección IA lo consume al
/// aparecer: si el modelo está listo, envía la pregunta; si no, la deja escrita en el
/// campo. Inyectado en el entorno por `RootWindowView`.
@MainActor
@Observable
final class AssistantInbox {
    var pendingPrompt: String?
    /// Enlace que el usuario tiene «en contexto» para el asistente: el que está seleccionado
    /// al abrir el chat, o sobre el que pulsó «Preguntar a la IA». La sección IA lo lee para
    /// que «este enlace», «resúmelo», «muévelo a X», «ábrelo»… se refieran a ÉL sin tener que
    /// nombrarlo. Persiste al cambiar de sección (a diferencia de la selección de la lista).
    var contextLink: LinkContext?
    /// Nombre legible de la sección/colección/etiqueta que el usuario estaba viendo ANTES de
    /// entrar al chat (p. ej. «Favoritos», «la colección «IA»»). Da contexto al asistente para
    /// «¿cuántos hay aquí?», «organiza ESTA colección»… La fija `RootWindowView` al navegar.
    var activeSection: String?
}

/// Instantánea LIGERA de un enlace para dar contexto al asistente (Sendable: viaja al
/// prompt sin arrastrar el `@Model` de SwiftData). Se construye en el hilo principal.
struct LinkContext: Equatable, Sendable, Identifiable {
    let id: UUID
    let title: String
    let url: String
    let details: String?
    let collection: String?
    let tags: [String]

    @MainActor
    init(_ b: Bookmark) {
        id = b.id
        url = b.url
        title = b.title.isEmpty ? b.url.urlHost : b.title
        let d = (b.details?.isEmpty == false) ? b.details : b.summary
        details = (d?.isEmpty == false) ? d : nil
        collection = b.category?.name
        tags = b.tags.map(\.name).filter { !$0.isEmpty }
    }
}

/// Sección IA: chat con el asistente Liquid on-device, con acceso a la biblioteca
/// (tool calling). Si el modelo no está cargado, invita a cargarlo.
struct AIChatView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Buzón de preguntas enviadas desde otras vistas (p. ej. «Preguntar a la IA» de la ficha).
    @Environment(AssistantInbox.self) private var assistantInbox: AssistantInbox?
    @Environment(\.openURL) private var openURL
    @Query private var settingsList: [AppSettings]

    @State private var chat: LiquidConversation?
    @State private var runner = LocalAIRunner.shared
    @State private var input = ""
    @State private var showSettings = false
    @State private var showOrganize = false
    @State private var showTopics = false
    /// URLs que el usuario ya añadió desde una tarjeta «Agregar» del chat (para
    /// marcarlas como añadidas y evitar duplicados de un toque).
    @State private var addedURLs: Set<String> = []
    /// Divulgación progresiva: evita que una respuesta con muchos enlaces se convierta
    /// en otra lista saturada. El usuario abre solo la ficha que le interesa.
    @State private var expandedReferenceIDs: Set<String> = []
    @State private var expandedDeckMessageIDs: Set<UUID> = []
    @State private var linkFeedback: String?
    @State private var showHistory = false
    @State private var previewItem: DiscoverItem?
    @State private var chatViewportWidth: CGFloat = 0
    @State private var measuredChatContainerWidth: CGFloat = 0
    @State private var transcriptScroll = TranscriptScrollState()
    @FocusState private var inputFocused: Bool
    @AppStorage(AssistantWebAccess.enabledKey) private var webSearchEnabled = true

    private var lang: String { (settingsList.first?.language ?? .es).rawValue }

    private var canChat: Bool {
        runner.isReady || (runner.isAvailable && !runner.isDeactivated) || MarketingDemoRuntime.isActive
    }

    var body: some View {
        Group {
            if canChat, let chat {
                conversation(chat)
            } else {
                notReady
            }
        }
        .navigationTitle("Asistente IA")
        .toolbar {
            if let chat {
                ToolbarItem {
                    Button("Nuevo chat", systemImage: "square.and.pencil") { chat.newChat() }
                        .themedHelp("Empezar una conversación nueva")
                }
                ToolbarItem {
                    Button("Historial de chats", systemImage: "clock.arrow.circlepath") {
                        showHistory = true
                    }
                    .themedHelp("Buscar, cambiar, renombrar o borrar chats")
                    .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                        ChatHistoryView(chat: chat, isPresented: $showHistory)
                    }
                }
            }
            ToolbarItem {
                Button("Organizar con IA", systemImage: "wand.and.stars") { showOrganize = true }
            }
            ToolbarItem {
                Button("Organizar por temas", systemImage: "square.stack.3d.up") { showTopics = true }
                    .themedHelp("Agrupar automáticamente tus enlaces sin clasificar por tema")
            }
            ToolbarItem {
                Button("Ajustes de IA", systemImage: "slider.horizontal.3") { showSettings = true }
            }
        }
        // Modales tematizados (EditorScaffold + themedSheet): sin la barra/marco GRIS del
        // sistema que añadía el NavigationStack/toolbar. Heredan el tema y el acento activos.
        .sheet(isPresented: $showOrganize) {
            EditorScaffold(title: "Organizar con IA", confirmTitle: "Cerrar", cancelTitle: nil,
                           onCancel: { showOrganize = false }, onConfirm: { showOrganize = false }) {
                AutoOrganizeView()
            }
            .frame(width: 460, height: 380)
            .themedSheet(palette)
        }
        .sheet(isPresented: $showTopics) {
            TopicOrganizeView().themedSheet(palette)
        }
        .sheet(isPresented: $showSettings) {
            EditorScaffold(title: "IA", confirmTitle: "Listo", cancelTitle: nil,
                           onCancel: { showSettings = false }, onConfirm: { showSettings = false }) {
                AISettingsView()
            }
            .frame(width: 540, height: 560)
            .themedSheet(palette)
        }
        .sheet(item: $previewItem) { item in
            EditorScaffold(title: "Previsualización", confirmTitle: "Cerrar", cancelTitle: nil,
                           onCancel: { previewItem = nil }, onConfirm: { previewItem = nil }) {
                DiscoverItemDetailView(item: item)
            }
            .frame(minWidth: 480, idealWidth: 720, maxWidth: 1000,
                   minHeight: 480, idealHeight: 680, maxHeight: 1000)
            .presentationSizing(.fitted)
            .themedSheet(palette)
        }
        .task(id: lang) {
            if chat == nil || chat?.language != lang {
                chat = LiquidConversation(libraryContainer: context.container, language: lang)
            }
            chat?.activeLinkContext = assistantInbox?.contextLink
            chat?.activeSection = assistantInbox?.activeSection
            consumeInbox()
        }
        // Si llega una pregunta desde otra vista (ficha → «Preguntar a la IA»), consúmela.
        .onChange(of: assistantInbox?.pendingPrompt) { _, _ in consumeInbox() }
        // Mantén el enlace «en contexto» y la sección activa al día (se inyectan en el prompt
        // de cada turno). Cambian si el usuario abre el chat con otro enlace/desde otra sección.
        .onChange(of: assistantInbox?.contextLink) { _, newValue in
            chat?.activeLinkContext = newValue
        }
        .onChange(of: assistantInbox?.activeSection) { _, newValue in
            chat?.activeSection = newValue
        }
    }

    /// Consume una pregunta pendiente del buzón: si el modelo está listo la envía; si no,
    /// la deja escrita en el campo para que el usuario la mande al cargar el modelo.
    private func consumeInbox() {
        guard let prompt = assistantInbox?.pendingPrompt, !prompt.isEmpty else { return }
        assistantInbox?.pendingPrompt = nil
        if let chat, canChat, !chat.isResponding {
            chat.send(prompt)
        } else if input.isEmpty {
            input = prompt   // modelo aún no listo: queda escrita para enviarla al cargar
        }
    }

    private var notReady: some View {
        EmptyStateView(
            icon: "sparkles",
            title: "Asistente Liquid",
            message: runner.isBusy
                ? "Preparando el modelo…"
                : "Carga el modelo Liquid para chatear con tu biblioteca y dejar que la organice por ti.",
            actionTitle: runner.isBusy ? nil : "Cargar modelo",
            action: runner.isBusy ? nil : { Task { await runner.ensureReady(userInitiated: true) } }
        )
    }

    @ViewBuilder
    private func conversation(_ chat: LiquidConversation) -> some View {
        VStack(spacing: 0) {
            assistantStatusBar
            if let notice = chat.storageNotice {
                storageNoticeRow(notice, chat: chat)
            }
            AIChatTranscriptView(
                chat: AIChatTranscriptPresentation(messages: chat.messages, activeID: chat.activeID,
                    isResponding: chat.isResponding, researchProgress: chat.researchProgress),
                addedURLs: $addedURLs, expandedReferenceIDs: $expandedReferenceIDs,
                expandedDeckMessageIDs: $expandedDeckMessageIDs, chatViewportWidth: $chatViewportWidth,
                measuredChatContainerWidth: $measuredChatContainerWidth, transcriptScroll: $transcriptScroll,
                callbacks: AIChatTranscriptCallbacks(
                    send: { chat.send($0) }, copy: { DiscoverWidget.copyToPasteboard($0) },
                    regenerate: { chat.regenerate() }, preview: preview,
                    open: { reference in
                        if let url = StacklumeAutomationPolicy.openableStoredURL(reference.url) { openURL(url) }
                    }, add: addLinks),
                progressFallback: {
                    MultimodalSearchService.shared.isReady
                        ? "Preparando respuesta…" : MultimodalSearchService.shared.status
                }
            )
            if let pending = chat.pendingConfirmation {
                confirmationCard(pending, chat: chat)
            }
            if let linkFeedback {
                Label(linkFeedback, systemImage: "checkmark.circle.fill")
                    .stacklumeFont(.caption.weight(.medium))
                    .foregroundStyle(palette.textSecondary)
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .padding(.top, DesignSystem.Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
                    .accessibilityLabel(linkFeedback)
            }
            // Chip del enlace «en contexto»: hace VISIBLE que el asistente conoce el enlace
            // que tenías seleccionado, y permite quitarlo. Por encima de la barra de entrada.
            if let ctx = assistantInbox?.contextLink {
                contextChip(ctx)
            }
            inputBar(chat)
        }
        .background(WindowBackground())
        .onAppear { inputFocused = true }
        .task(id: linkFeedback) {
            guard linkFeedback != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { linkFeedback = nil }
        }
    }

    private func storageNoticeRow(_ notice: String, chat: LiquidConversation) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Label(notice, systemImage: (notice.localizedCaseInsensitiveContains("recuper")
                || notice.localizedCaseInsensitiveContains("recover"))
                ? "checkmark.circle" : "externaldrive.badge.exclamationmark")
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DesignSystem.Spacing.xs)
            Button {
                chat.dismissStorageNotice()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .themedHelp("Cerrar aviso")
            .accessibilityLabel("Cerrar aviso del historial")
        }
        .stacklumeFont(.caption)
        .foregroundStyle(palette.textSecondary)
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .background(palette.surface.opacity(0.72))
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.border.opacity(0.45)).frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private var assistantStatusBar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Label("Modelo local", systemImage: "macbook")
            Spacer(minLength: DesignSystem.Spacing.sm)
            Label(webSearchEnabled ? "Web para completar tu búsqueda" : "Web desactivada",
                  systemImage: webSearchEnabled ? "globe" : "globe.slash")
        }
        .stacklumeFont(.caption.weight(.medium))
        .foregroundStyle(palette.textSecondary)
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .background {
            StacklumeGlassBackdrop(
                shape: Rectangle(),
                tint: palette.accent,
                tintOpacity: 0.02
            )
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.border.opacity(0.45)).frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func confirmationCard(
        _ pending: LiquidConversation.PendingConfirmation,
        chat: LiquidConversation
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: pending.risk == .irreversible ? "exclamationmark.triangle.fill" : "shield.lefthalf.filled")
                    .foregroundStyle(palette.accent)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(pending.title)
                        .stacklumeFont(.callout.weight(.semibold))
                        .foregroundStyle(palette.textPrimary)
                    Text(pending.detail)
                        .stacklumeFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button("Cancelar") { chat.cancelPendingAction() }
                    .stacklumeButton(prominent: false)
                Spacer()
                Button(pending.risk == .irreversible ? "Confirmar definitivamente" : "Confirmar cambio") {
                    chat.confirmPendingAction()
                }
                .stacklumeButton()
            }
            .stacklumeGlassContainer(spacing: DesignSystem.Spacing.sm)
        }
        .padding(DesignSystem.Spacing.sm)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
                .strokeBorder(palette.accent.opacity(0.28), lineWidth: 0.5)
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.top, DesignSystem.Spacing.xs)
        .accessibilityElement(children: .contain)
    }

    /// Chip que muestra el enlace que el asistente tiene «en contexto» (el seleccionado al
    /// abrir el chat). Tocar la ✕ lo quita; entonces el asistente deja de tenerlo presente.
    @ViewBuilder
    private func contextChip(_ ctx: LinkContext) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.textPrimary)
                .frame(width: 18, height: 18)
                .background(palette.accent.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text("En contexto")
                    .stacklumeFont(.caption2.weight(.semibold))
                    .foregroundStyle(palette.textPrimary)
                Text(ctx.title)
                    .stacklumeFont(.caption)
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button { assistantInbox?.contextLink = nil } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(palette.textSecondary)
            }
            .buttonStyle(.plain)
            .themedHelp("Quitar el enlace del contexto")
            .accessibilityLabel("Quitar el enlace del contexto")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(palette.accent.opacity(0.25), lineWidth: 0.5))
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.top, DesignSystem.Spacing.xs)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Reutiliza la ficha de «Descubrir» en una hoja para conservar el ancho del chat.
    private func preview(_ reference: AssistantLinkReference) {
        previewItem = DiscoverItem(
            id: reference.url,
            title: reference.title,
            url: reference.url,
            imageURL: nil,
            sourceName: reference.origin == .library ? "Tu biblioteca" : "Fuente web",
            sourceIcon: reference.origin == .library ? "books.vertical" : "globe"
        )
    }

    private func addLinks(_ references: [AssistantLinkReference]) {
        let safe = references.filter { reference in
            guard reference.origin == .web,
                  !addedURLs.contains(reference.url),
                  let url = URL(string: reference.url) else { return false }
            return StacklumeAutomationPolicy.allowsExternalCaptureURL(url)
        }
        guard !safe.isEmpty else { return }
        let result = LinkIngest.ingestLinks(
            safe.map { LinkIngest.IngestItem(urlString: $0.url, suggestedTitle: $0.title) },
            in: context,
            category: nil,
            aiEnrich: true
        )
        let urls = safe.map(\.url)
        if reduceMotion {
            addedURLs.formUnion(urls)
        } else {
            withAnimation(.snappy) { addedURLs.formUnion(urls) }
        }
        if result.added.isEmpty {
            linkFeedback = safe.count == 1
                ? "Ese enlace ya estaba en tu biblioteca."
                : "Los \(safe.count) enlaces ya estaban en tu biblioteca."
        } else if result.skipped.isEmpty {
            linkFeedback = result.added.count == 1
                ? "Enlace añadido a tu biblioteca."
                : "\(result.added.count) enlaces añadidos a tu biblioteca."
        } else {
            linkFeedback = "\(result.added.count) añadidos · \(result.skipped.count) ya estaban guardados."
        }
    }

    private func inputBar(_ chat: LiquidConversation) -> some View {
        let fieldShape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return HStack(spacing: DesignSystem.Spacing.sm) {
            TextField("Pregunta a tu asistente…", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .accessibilityLabel("Mensaje para el asistente")
                .accessibilityHint("Escribe una pregunta o una instrucción para tu biblioteca")
                .lineLimit(1...5)
                .padding(10)
                .background(palette.background.opacity(0.32), in: fieldShape)
                .stacklumeGlass(in: fieldShape, interactive: true)
                .overlay {
                    fieldShape.strokeBorder(palette.textPrimary.opacity(0.12), lineWidth: 0.6)
                }
                .onSubmit { sendMessage(chat) }
                .onChange(of: input) { _, newValue in
                    if newValue.count > AssistantActionPolicy.maximumUserInputCharacters {
                        input = String(newValue.prefix(AssistantActionPolicy.maximumUserInputCharacters))
                    }
                }
            if chat.isResponding {
                // Mientras genera: botón para DETENER (usa LiquidConversation.stop()).
                Button { chat.stop() } label: {
                    Image(systemName: "stop.circle.fill").font(.title)
                }
                .stacklumeButton(prominent: false, compact: true)
                .foregroundStyle(palette.textSecondary)
                .themedHelp("Detener")
                .accessibilityLabel("Detener generación")
            } else {
                Button { sendMessage(chat) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .stacklumeButton(compact: true)
                .foregroundStyle(palette.textPrimary)
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                .themedHelp("Enviar")
                .accessibilityLabel("Enviar mensaje")
            }
        }
        .padding(DesignSystem.Spacing.sm)
        .background {
            StacklumeGlassBackdrop(
                shape: Rectangle(),
                tint: palette.accent,
                tintOpacity: 0.025
            )
        }
        .overlay(alignment: .top) {
            Rectangle().fill(palette.border.opacity(0.5)).frame(height: 0.5)
        }
    }

    private func sendMessage(_ chat: LiquidConversation) {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !chat.isResponding else { return }
        chat.send(text)
        input = ""
        inputFocused = true
    }
}

/// Panel de historial de chats: buscar dentro de los chats, cambiar de conversación,
/// renombrar, borrar y crear una nueva. Se presenta como popover desde la toolbar.
private struct ChatHistoryView: View {
    let chat: LiquidConversation
    @Binding var isPresented: Bool

    @Environment(\.themePalette) private var palette
    @State private var query = ""
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var pendingDelete: LiquidConversation.SessionInfo?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 2) {
                    let list = chat.searchSessions(query)
                    if list.isEmpty {
                        Text(query.isEmpty ? "No hay chats todavía." : "Sin resultados.")
                            .stacklumeFont(.callout).foregroundStyle(palette.textSecondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    } else {
                        ForEach(list) { row($0) }
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 340, height: 420)
        .background(palette.surface)
        .alert("¿Borrar este chat?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { s in
            Button("Borrar", role: .destructive) { chat.deleteChat(s.id); pendingDelete = nil }
            Button("Cancelar", role: .cancel) { pendingDelete = nil }
        } message: { s in
            Text("Se eliminará «\(s.title)» de forma permanente.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(palette.textSecondary)
            TextField("Buscar en los chats…", text: $query)
                .textFieldStyle(.plain)
                .foregroundStyle(palette.textPrimary)
            Button { chat.newChat(); isPresented = false } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain).foregroundStyle(palette.textPrimary).themedHelp("Nuevo chat")
            .accessibilityLabel("Nuevo chat")
        }
        .padding(10)
    }

    @ViewBuilder
    private func row(_ s: LiquidConversation.SessionInfo) -> some View {
        let active = s.id == chat.activeID
        HStack(spacing: 8) {
            Image(systemName: active ? "checkmark.circle.fill" : "bubble.left")
                .font(.caption)
                .foregroundStyle(active ? palette.textPrimary : palette.textSecondary)
                .frame(width: 16)
            if renamingID == s.id {
                TextField("Título", text: $renameText)
                    .textFieldStyle(.plain)
                    .foregroundStyle(palette.textPrimary)
                    .onSubmit { commitRename(s.id) }
                Button { commitRename(s.id) } label: { Image(systemName: "checkmark") }
                    .buttonStyle(.plain).foregroundStyle(palette.textPrimary)
                    .accessibilityLabel("Confirmar nombre")
            } else {
                Button { chat.selectChat(s.id); isPresented = false } label: {
                    Text(s.title).lineLimit(1)
                        .foregroundStyle(palette.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                Menu {
                    Button("Renombrar", systemImage: "pencil") { renameText = s.title; renamingID = s.id }
                    Button("Borrar", systemImage: "trash", role: .destructive) { pendingDelete = s }
                } label: {
                    Image(systemName: "ellipsis").font(.caption).foregroundStyle(palette.textSecondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Más opciones")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(active ? palette.accent.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func commitRename(_ id: UUID) {
        chat.renameChat(id, to: renameText)
        renamingID = nil
    }
}
