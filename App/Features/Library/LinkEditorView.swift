import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import StacklumeCore
import StacklumeDesignSystem
import StacklumeMetadata

/// Editor de enlace (crear o editar) en hoja con formulario premium. Paridad con
/// el editor del iPhone: adjuntar archivo, vista previa, recordatorio, colección,
/// además de las secciones básicas (enlace, organización, categoría, etiquetas,
/// notas) adaptadas a macOS.
struct LinkEditorView: View {
    let target: EditorTarget
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Query(filter: #Predicate<BookmarkCategory> { $0.deletedAt == nil }, sort: \BookmarkCategory.order)
    private var categories: [BookmarkCategory]
    @Query(filter: #Predicate<Tag> { $0.deletedAt == nil }, sort: \Tag.order) private var allTags: [Tag]
    @Query(sort: \LinkSession.order) private var sessions: [LinkSession]
    @Query private var settingsList: [AppSettings]

    /// Autocompletar con IA al detectar la URL (lo respeta solo el disparo automático;
    /// el botón manual «Autocompletar con IA» funciona siempre). Por defecto, activado.
    @AppStorage("stacklume.aiAutoEnrich") private var aiAutoEnrich = true

    @State private var url = ""
    @State private var title = ""
    @State private var details = ""
    @State private var notes = ""
    @State private var isFavorite = false
    @State private var categoryID: UUID?
    @State private var selectedTagIDs: Set<UUID> = []
    @State private var readingStatus: ReadingStatus = .inbox

    // Metadatos derivados de la URL (para la vista previa).
    @State private var imageURL: String?
    @State private var faviconURL: String?
    @State private var siteName: String?
    @State private var platform: Platform = .generic
    @State private var contentType: ContentType = .website
    @State private var platformColor: String?

    // Archivo adjunto (imagen/PDF/EPUB): el marcador será un archivo en vez de una URL.
    @State private var fileData: Data?
    @State private var fileKind: String?
    @State private var documentAuthor: String?
    @State private var showFileImporter = false
    @State private var fileLoadTask: Task<Void, Never>?
    @State private var fileError: String?

    // Recordatorio «leer más tarde».
    @State private var hasReminder = false
    @State private var reminderDate = Date().addingTimeInterval(3600)

    // Colección (sesión de enlaces) a la que pertenece el marcador.
    @State private var sessionID: UUID?

    // Buscadores para crear sobre la marcha (paridad iPhone).
    @State private var categoryQuery = ""
    @State private var tagQuery = ""
    /// Icono y color elegidos para la colección NUEVA que se va a crear desde aquí (al pulsar
    /// «Crear»). Por defecto, carpeta + primer color de la paleta. La etiqueta nueva solo lleva
    /// color (el modelo `Tag` no tiene icono; se pinta con «#»).
    @State private var newCategoryIcon = "folder.fill"
    @State private var newCategoryColor = ColorPresets.all.first ?? "#7AA2F7"
    @State private var newTagColor = ColorPresets.all.first ?? "#7AA2F7"

    @State private var didLoad = false

    /// URL detectada en el portapapeles del sistema (solo al crear y con el campo
    /// vacío). Guardamos la cadena para poder mostrar el dominio sin volver a leer el
    /// portapapeles en cada redibujado y para pegarla con un clic.
    @State private var clipboardURL: String?

    // Autocompletado con IA (paridad iPhone).
    /// Autocompletado MANUAL (botón «Autocompletar con IA»): bloquea Guardar mientras corre.
    @State private var isSuggesting = false
    /// Autocompletado AUTOMÁTICO (al detectar la URL): corre en 2.º plano sin bloquear Guardar.
    @State private var isAutoSuggesting = false
    @State private var autoSuggestedURL: String?
    @State private var autoSuggestTask: Task<Void, Never>?
    @State private var aiMessage: String?
    @State private var showAIMessage = false
    /// Fase animada del indicador «Generando…» mientras corre la IA.
    @State private var suggestPhase = 0
    @State private var phaseTask: Task<Void, Never>?
    static let suggestPhases = [
        "Leyendo la página…", "Mejorando el título…", "Redactando la descripción…",
        "Eligiendo categoría y etiquetas…", "Traduciendo…", "Casi listo…"
    ]

    /// Idioma activo para la IA (por defecto «es»), igual que el resto del Mac.
    private var aiLanguage: String { (settingsList.first?.language ?? .es).rawValue }

    private var isEditing: Bool { if case .edit = target { return true }; return false }
    private var canSave: Bool {
        fileLoadTask == nil && (!url.trimmingCharacters(in: .whitespaces).isEmpty || fileData != nil)
    }

    var body: some View {
        // `EditorScaffold` (mismo marco TEMATIZADO de CategoryEditor/ProjectEditor/TagEditor):
        // cabecera + pie con Cancelar/Confirmar sobre `WindowBackground`, SIN el `NavigationStack`
        // + `.toolbar` del sistema, cuya barra de título se veía GRIS y no adoptaba el tema.
        // Conserva Intro (confirmar) y Escape (cancelar) vía los `keyboardShortcut` del scaffold.
        EditorScaffold(
            title: isEditing ? "Editar enlace" : "Nuevo enlace",
            confirmTitle: isEditing ? "Guardar" : "Añadir",
            canConfirm: canSave,
            onCancel: { dismiss() },
            onConfirm: { save() }
        ) {
            Form {
                if !isEditing { fileSection }
                linkSection
                if imageURL != nil || platform != .generic {
                    previewSection
                }
                categorySection
                organizationSection
                tagsSection
                reminderSection
                if !sessions.isEmpty { collectionSection }
                notesSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            // Ancho DURO del formulario: corta la propagación del ancho IDEAL hacia arriba.
            // Sin esto, con ciertos enlaces (varias etiquetas o etiquetas largas) el `FlowLayout`
            // de los chips —al medirse con propuesta de ancho NULA— devuelve la suma de TODOS los
            // chips en una fila (un ancho enorme), inflaba el modal y descentraba el contenido
            // (se salía por ambos lados). Fijar 480 aquí obliga al formulario a medirse a 480 en
            // todas las pasadas, así los chips se reparten en varias filas dentro del modal.
            .frame(width: 480)
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.image, .pdf, .epub, .audio, .movie]) { result in
                handlePickedFile(result)
            }
        }
        .frame(width: 480, height: 620)
        .onAppear {
            load()
            refreshClipboardSuggestion()
        }
        // Al volver la app a primer plano (paridad iPhone): re-comprueba el portapapeles
        // por si el usuario copió un enlace en otra app mientras el editor estaba abierto.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshClipboardSuggestion()
        }
        .onDisappear {
            fileLoadTask?.cancel()
            autoSuggestTask?.cancel()
            phaseTask?.cancel()
        }
        .alert("IA", isPresented: $showAIMessage) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text(aiMessage ?? "")
        }
        .alert("No se pudo adjuntar el archivo", isPresented: Binding(
            get: { fileError != nil },
            set: { if !$0 { fileError = nil } }
        )) {
            Button("Aceptar", role: .cancel) { fileError = nil }
        } message: {
            Text(fileError ?? "")
        }
    }

    // MARK: - Archivo adjunto

    /// Adjuntar una imagen, PDF o EPUB: el marcador será un archivo guardado localmente.
    @ViewBuilder
    private var fileSection: some View {
        Section {
            if let fileData, let kind = fileKind {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    if kind == "image", let image = DocumentPreviewImage.make(from: fileData) {
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: 54, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        Image(systemName: kind == "epub" ? "book.closed.fill" : "doc.fill")
                            .font(.title2).foregroundStyle(palette.accent)
                            .frame(width: 54, height: 54)
                            .background(palette.accent.opacity(0.16),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localFileDescription(for: kind))
                            .stacklumeFont(.subheadline).foregroundStyle(palette.textPrimary)
                        if kind == "epub", let documentAuthor, !documentAuthor.isEmpty {
                            Text(documentAuthor)
                                .stacklumeFont(.caption)
                                .foregroundStyle(palette.textSecondary)
                                .stacklumeLineLimit(1)
                        }
                    }
                    Spacer()
                    Button(role: .destructive) {
                        withAnimation(.snappy) {
                            self.fileData = nil
                            self.fileKind = nil
                            self.documentAuthor = nil
                        }
                    } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(palette.textSecondary) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Quitar archivo")
                }
            } else {
                Button { showFileImporter = true } label: {
                    Label(fileLoadTask == nil ? "Adjuntar imagen, documento, audio o vídeo" : "Preparando archivo…", systemImage: "paperclip")
                }
            }
        } header: {
            Text("Archivo")
        } footer: {
            Text("Guarda una imagen, PDF, EPUB, audio o vídeo de hasta \(DocumentTextExtractor.maximumInputMegabytes) MB. El texto se extrae en tu Mac para poder buscarlo, sin subir el archivo a ningún servicio.")
        }
    }

    // MARK: - Enlace

    private var linkSection: some View {
        Section("Enlace") {
            // Sugerencia del portapapeles (solo al crear y con el campo vacío). Banner
            // sutil al estilo macOS: icono `doc.on.clipboard`, dominio y «pégalo».
            if let clip = clipboardURL, !isEditing,
               url.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(action: pasteFromClipboard) {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "doc.on.clipboard.fill")
                            .font(.title3)
                            .foregroundStyle(palette.accent)
                            .frame(width: 34, height: 34)
                            .background(palette.accent.opacity(0.16),
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Enlace en el portapapeles")
                                .stacklumeFont(.subheadline.weight(.semibold))
                                .foregroundStyle(palette.textPrimary)
                            Text(clip.urlHost)
                                .stacklumeFont(.caption2)
                                .foregroundStyle(palette.textSecondary)
                                .stacklumeLineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.down.doc.fill")
                            .foregroundStyle(palette.accent)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(palette.accent.opacity(0.08))
                .themedHelp("Pega «\(clip.urlHost)» y rellena el enlace")
            }
            TextField("https://…", text: $url)
                .onChange(of: url) { _, newURL in
                    autoFetchMetadata(for: newURL)
                    autoSuggestIfNeeded(for: newURL)
                }
            // Un único botón de IA: mejora el título, enriquece la descripción, propone
            // categoría y etiquetas, y traduce todo al idioma activo. Los metadatos básicos
            // (favicon, imagen, plataforma) se obtienen solos al introducir la URL.
            Button { suggestWithAI(auto: false) } label: {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    if isSuggesting || isAutoSuggesting {
                        ProgressView().controlSize(.small)
                        Text(Self.suggestPhases[suggestPhase % Self.suggestPhases.count])
                            .contentTransition(.opacity)
                            .id(suggestPhase)
                            .transition(.opacity)
                    } else {
                        Image(systemName: "sparkles")
                            .accessibilityHidden(true)
                        Text("Autocompletar con IA")
                    }
                    Spacer(minLength: 0)
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: suggestPhase)
            }
            // Solo el autocompletado MANUAL bloquea Guardar; el automático corre en 2.º
            // plano y deja guardar en cualquier momento.
            .disabled(!canSave || isSuggesting || isAutoSuggesting)
            .themedHelp("Rellena título, descripción, categoría y etiquetas con IA")

            // Comando de instalación detectado en vivo (npm i…, pip install…): aviso de que
            // se guardará como comando (apuntando a la página del paquete).
            if fileData == nil, let cmd = CommandDetector.detect(url) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "terminal.fill")
                        .foregroundStyle(Color(hex: cmd.colorHex))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Comando \(cmd.manager) detectado")
                            .stacklumeFont(.caption.weight(.semibold))
                            .foregroundStyle(palette.textPrimary)
                        Text("Se guardará «\(cmd.packageName)» con el comando para copiarlo")
                            .stacklumeFont(.caption2)
                            .foregroundStyle(palette.textSecondary)
                            .stacklumeLineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }

            TextField("Título", text: $title)
            TextField("Descripción", text: $details, axis: .vertical).lineLimit(2...4)
        }
    }

    // MARK: - Vista previa

    private var previewFaviconCandidates: [String?] {
        let host = url.urlHost
        // Prefiere el favicon real del sitio (suele ser de mayor calidad) y cae al de
        // Google s2 a `sz=256` (alta resolución) para que no se vea borroso en Retina.
        return [faviconURL, "https://www.google.com/s2/favicons?domain=\(host)&sz=256"]
    }

    /// Tarjeta de vista previa: muestra al instante cómo se guardará el enlace.
    private var previewSection: some View {
        Section("Vista previa") {
            VStack(alignment: .leading, spacing: 0) {
                if let imageURL, !imageURL.isEmpty {
                    SecureRemoteImage(candidates: [imageURL]) {
                        Rectangle().fill(Color(hex: platformColor ?? "#6E7186").opacity(0.18))
                    }
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .clipped()
                }
                HStack(spacing: DesignSystem.Spacing.sm) {
                    SecureRemoteImage(candidates: previewFaviconCandidates) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(hex: platformColor ?? "#6E7186").opacity(0.2))
                            .overlay(
                                Image(systemName: platform.sfSymbol)
                                    .font(.subheadline)
                                    .foregroundStyle(Color(hex: platformColor ?? "#D4A853"))
                            )
                    }
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title.isEmpty ? url.urlHost : title)
                            .stacklumeFont(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.textPrimary)
                            .stacklumeLineLimit(2)
                        HStack(spacing: 6) {
                            Text(url.urlHost)
                                .stacklumeFont(.caption2)
                                .foregroundStyle(palette.textSecondary)
                                .stacklumeLineLimit(1)
                            if platform != .generic {
                                Text(platform.displayName)
                                    .stacklumeFont(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Color(hex: platformColor ?? "#6E7186").opacity(0.18), in: Capsule())
                                    .foregroundStyle(Color(hex: platformColor ?? "#6E7186"))
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(DesignSystem.Spacing.sm)
            }
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: - Categoría (buscar / crear, igual que el iPhone)

    private var trimmedCategoryQuery: String { categoryQuery.trimmingCharacters(in: .whitespaces) }

    private var selectedCategory: BookmarkCategory? {
        categories.first { $0.id == categoryID }
    }

    private var pickableCategories: [BookmarkCategory] {
        let q = trimmedCategoryQuery.lowercased()
        if q.isEmpty { return Array(categories.prefix(12)) }
        return Array(categories.filter { $0.name.lowercased().contains(q) }.prefix(20))
    }

    private var canCreateCategory: Bool {
        !trimmedCategoryQuery.isEmpty &&
        !categories.contains { $0.name.caseInsensitiveCompare(trimmedCategoryQuery) == .orderedSame }
    }

    private var categorySection: some View {
        Section("Categoría") {
            if let category = selectedCategory {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: category.icon)
                        .foregroundStyle(Color(hex: category.colorHex))
                    Text(category.name).foregroundStyle(palette.textPrimary)
                    Spacer()
                    Button {
                        categoryID = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Quitar categoría")
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.footnote)
                        .foregroundStyle(palette.textSecondary)
                    TextField("Buscar o crear colección", text: $categoryQuery)
                        .autocorrectionDisabled()
                        .onSubmit { if canCreateCategory { createAndSelectCategory() } }
                    if !categoryQuery.isEmpty {
                        Button { categoryQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(palette.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Borrar búsqueda")
                    }
                }
                if canCreateCategory {
                    // Crear con el ICONO y COLOR elegidos (no por defecto). El botón muestra una
                    // vista previa en vivo de cómo quedará la colección.
                    Button { createAndSelectCategory() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                            Image(systemName: newCategoryIcon)
                                .foregroundStyle(Color(hex: newCategoryColor))
                            Text("Crear «\(trimmedCategoryQuery)»")
                        }
                        .stacklumeFont(.subheadline.weight(.medium))
                        .foregroundStyle(palette.accent)
                    }
                    .buttonStyle(.plain)
                    Text("Color")
                        .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                    ColorSwatchPicker(selection: $newCategoryColor)
                    Text("Icono")
                        .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                    IconPicker(selection: $newCategoryIcon, tint: Color(hex: newCategoryColor))
                }
                if pickableCategories.isEmpty && !canCreateCategory && trimmedCategoryQuery.isEmpty {
                    Label {
                        Text("Aún no hay colecciones. Escribe un nombre y pulsa Intro para crear la primera.")
                            .foregroundStyle(palette.textSecondary)
                            .stacklumeFont(.subheadline)
                    } icon: {
                        Image(systemName: "folder")
                            .foregroundStyle(palette.textSecondary)
                            .accessibilityHidden(true)
                    }
                }
                ForEach(pickableCategories) { category in
                    Button {
                        categoryID = category.id
                        categoryQuery = ""
                    } label: {
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Image(systemName: category.icon)
                                .foregroundStyle(Color(hex: category.colorHex))
                            Text(category.name).foregroundStyle(palette.textPrimary)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Crea (o reutiliza) la categoría con el texto del buscador y la selecciona. Pasa por el
    /// resolutor canónico ÚNICO (`EntityResolver`): si ya existe una equivalente (sinónimo/
    /// traducción/acento) la reutiliza en vez de crear un duplicado como «Juegos»/«Videojuegos».
    private func createAndSelectCategory() {
        let name = trimmedCategoryQuery
        guard !name.isEmpty,
              let category = EntityResolver.category(name, in: context,
                                                     colorHex: newCategoryColor, icon: newCategoryIcon)
        else { return }
        categoryID = category.id
        categoryQuery = ""
        newCategoryIcon = "folder.fill"   // restablece para la próxima colección nueva
        newCategoryColor = ColorPresets.all.first ?? "#7AA2F7"
    }

    // MARK: - Organización

    private var organizationSection: some View {
        Section("Organización") {
            Toggle("Favorito", isOn: $isFavorite)
            Picker("Estado de lectura", selection: $readingStatus) {
                ForEach(ReadingStatus.allCases) { status in
                    Label(status.displayName, systemImage: status.sfSymbol).tag(status)
                }
            }
        }
    }

    // MARK: - Etiquetas (buscar / crear, igual que el iPhone)

    private var trimmedTagQuery: String { tagQuery.trimmingCharacters(in: .whitespaces) }

    private var selectedTags: [Tag] {
        allTags.filter { selectedTagIDs.contains($0.id) }
    }

    private var pickableTags: [Tag] {
        let q = trimmedTagQuery.lowercased()
        let pool = allTags.filter { !selectedTagIDs.contains($0.id) }
        if q.isEmpty { return Array(pool.prefix(12)) }
        return Array(pool.filter { $0.name.lowercased().contains(q) }.prefix(20))
    }

    private var canCreateTag: Bool {
        !trimmedTagQuery.isEmpty &&
        !allTags.contains { $0.name.caseInsensitiveCompare(trimmedTagQuery) == .orderedSame }
    }

    private var tagsSection: some View {
        Section("Etiquetas") {
            if !selectedTags.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(selectedTags) { tag in
                        SelectableChip(tag.name, isSelected: true, colorHex: tag.colorHex) {
                            toggleTag(tag.id)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.footnote)
                    .foregroundStyle(palette.textSecondary)
                TextField("Buscar o crear etiqueta", text: $tagQuery)
                    .autocorrectionDisabled()
                    .onSubmit { if canCreateTag { createAndSelectTag() } }
                if !tagQuery.isEmpty {
                    Button { tagQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Borrar búsqueda")
                }
            }

            if canCreateTag {
                // Crear con el COLOR elegido. (Las etiquetas se pintan con «#»: no tienen icono
                // propio en el modelo, solo color.)
                Button { createAndSelectTag() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                        Circle().fill(Color(hex: newTagColor)).frame(width: 12, height: 12)
                        Text("Crear «\(trimmedTagQuery)»")
                    }
                    .stacklumeFont(.subheadline.weight(.medium))
                    .foregroundStyle(palette.accent)
                }
                .buttonStyle(.plain)
                Text("Color")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                ColorSwatchPicker(selection: $newTagColor)
            }

            if !pickableTags.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(pickableTags) { tag in
                        SelectableChip(tag.name, isSelected: false, colorHex: tag.colorHex) {
                            toggleTag(tag.id)
                            tagQuery = ""
                        }
                    }
                }
                .padding(.vertical, 2)
            } else if allTags.isEmpty && trimmedTagQuery.isEmpty {
                Label {
                    Text("Aún no hay etiquetas. Escribe un nombre y pulsa Intro para crear la primera.")
                        .foregroundStyle(palette.textSecondary)
                        .stacklumeFont(.subheadline)
                } icon: {
                    Image(systemName: "tag")
                        .foregroundStyle(palette.textSecondary)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    /// Crea (o reutiliza) la etiqueta con el texto del buscador y la selecciona. Pasa por el
    /// resolutor canónico ÚNICO (deduplica may./tildes y singular/plural: «videojuego» reutiliza
    /// «videojuegos»), conservando la grafía del usuario si la etiqueta es nueva.
    private func createAndSelectTag() {
        let name = trimmedTagQuery
        guard !name.isEmpty, let tag = EntityResolver.tag(name, in: context, colorHex: newTagColor) else { return }
        selectedTagIDs.insert(tag.id)
        tagQuery = ""
        newTagColor = ColorPresets.all.first ?? "#7AA2F7"   // restablece para la próxima etiqueta nueva
    }

    // MARK: - Recordatorio (leer más tarde)

    private var reminderSection: some View {
        Section("Recordatorio") {
            Toggle(isOn: $hasReminder) {
                Label("Leer más tarde", systemImage: hasReminder ? "bell.fill" : "bell")
            }
            if hasReminder {
                DatePicker("Recordarme el", selection: $reminderDate,
                           in: Date()..., displayedComponents: [.date, .hourAndMinute])
            }
        }
    }

    // MARK: - Colección (sesión de enlaces)

    private var collectionSection: some View {
        Section("Colección") {
            Picker("Pertenece a", selection: $sessionID) {
                Text("Ninguna").tag(UUID?.none)
                ForEach(sessions) { session in
                    Label(session.name, systemImage: session.icon).tag(Optional(session.id))
                }
            }
        }
    }

    // MARK: - Notas

    private var notesSection: some View {
        Section("Notas") {
            TextField("Tus notas…", text: $notes, axis: .vertical).lineLimit(3...6)
        }
    }

    // MARK: - Acciones

    private func toggleTag(_ id: UUID) {
        if selectedTagIDs.contains(id) { selectedTagIDs.remove(id) } else { selectedTagIDs.insert(id) }
    }

    /// Rellena metadatos básicos (título, descripción, favicon, imagen, plataforma) de
    /// forma silenciosa al introducir una URL (solo campos vacíos, sin tocar la URL).
    @State private var autoMetaTask: Task<Void, Never>?
    @State private var autoMetaURL: String?
    private func autoFetchMetadata(for newURL: String) {
        guard !isEditing else { return }
        let trimmed = newURL.trimmingCharacters(in: .whitespaces)
        autoMetaTask?.cancel()
        // Comando (npm i…) → previsualiza la PÁGINA DEL PAQUETE; si no, la URL escrita.
        let target = CommandDetector.detect(trimmed)?.registryURL ?? trimmed
        guard target.count >= 8, target.contains("."), target != autoMetaURL else { return }
        autoMetaTask = Task {
            try? await Task.sleep(for: .seconds(0.7))
            guard !Task.isCancelled else { return }
            let meta = await MacMetadataService().fetchMetadata(for: target)
            guard !Task.isCancelled else { return }
            autoMetaURL = target
            if title.trimmingCharacters(in: .whitespaces).isEmpty, let t = meta.title { title = t }
            if details.trimmingCharacters(in: .whitespaces).isEmpty, let d = meta.details { details = d }
            if imageURL == nil { imageURL = meta.imageURL }
            if faviconURL == nil { faviconURL = meta.faviconURL }
            if siteName == nil || siteName?.isEmpty == true { siteName = meta.siteName }
            if platform == .generic { platform = meta.platform }
            if contentType == .website { contentType = meta.contentType }
            if platformColor == nil { platformColor = meta.platformColor }
        }
    }

    // MARK: - Autocompletado con IA (paridad iPhone, motor Liquid)

    /// Autocompletado AUTOMÁTICO al detectar una URL válida: tras un breve debounce,
    /// lanza el mismo flujo que «Autocompletar con IA» (metadatos + enriquecido) sin que
    /// el usuario pulse nada. Una sola vez por URL, solo al CREAR, solo si el toggle de
    /// auto-IA está activo y el modelo Liquid ya está descargado (no fuerza descarga ni
    /// lo carga si el usuario lo desactivó). Corre en 2.º plano sin bloquear el guardado
    /// ni molestar con errores.
    private func autoSuggestIfNeeded(for newURL: String) {
        guard !isEditing, aiAutoEnrich else { return }
        // Para el modelo local no forzamos descarga: solo si ya está descargado y no lo
        // desactivó el usuario manualmente («Liberar memoria» en Ajustes › IA).
        guard LocalAIRunner.shared.isDownloaded, !LocalAIRunner.shared.isDeactivated else { return }
        let trimmed = newURL.trimmingCharacters(in: .whitespaces)
        autoSuggestTask?.cancel()
        guard trimmed.count >= 8, trimmed.contains("."),
              trimmed != autoSuggestedURL,
              !isSuggesting, !isAutoSuggesting else { return }
        autoSuggestedURL = trimmed
        autoSuggestTask = Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled, !isSuggesting, !isAutoSuggesting else { return }
            // Asegura el modelo cargado (si está descargado) antes de enriquecer; con la
            // precarga al abrir la app esto ya suele estar listo → percepción instantánea.
            if await LocalAIRunner.shared.ensureReady() == nil {
                autoSuggestedURL = nil   // falló la carga: permite reintentar más tarde
                return
            }
            guard !Task.isCancelled, url.trimmingCharacters(in: .whitespaces) == trimmed else { return }
            suggestWithAI(auto: true)
        }
    }

    /// Enriquecido COMPLETO con IA (motor Liquid): metadatos de red como vista previa
    /// instantánea y, en una sola pasada, título mejorado + descripción rica + categoría
    /// + etiquetas traducidos al idioma activo. Respeta lo que el usuario ya escribió
    /// (solo rellena los campos vacíos del título/descripción y la categoría sin elegir).
    private func suggestWithAI(auto: Bool) {
        let rawURL = url.trimmingCharacters(in: .whitespaces)
        guard !rawURL.isEmpty, !isSuggesting, !isAutoSuggesting else { return }
        // Si es un comando (npm i…, pip install…), la IA debe analizar la PÁGINA DEL
        // PAQUETE (npmjs.com/package/zod…), no el texto del comando: «zod» a secas se
        // categoriza mal (p. ej. como videojuego). Resuélvelo a su registryURL.
        let commandInfo = CommandDetector.detect(rawURL)
        let effectiveURL = commandInfo?.registryURL ?? rawURL
        let currentTitle = title
        let currentDetails = details
        // Solo proponemos categoría si el usuario aún no eligió una.
        let needsCategory = categoryID == nil
        let existingCategoryNames = categories.map(\.name)
        let language = aiLanguage
        if auto { isAutoSuggesting = true } else { isSuggesting = true }
        startPhaseCycler()
        Task {
            do {
                // 1) Metadatos de la página: rellenan el título/resumen AL INSTANTE como
                //    vista previa, mientras la IA prepara la versión mejorada/traducida.
                let meta = await MacMetadataService().fetchMetadata(for: effectiveURL)
                let pageTitle = meta.title ?? (currentTitle.isEmpty ? nil : currentTitle)
                let pageDescription = (meta.details?.isEmpty == false)
                    ? meta.details
                    : (currentDetails.isEmpty ? nil : currentDetails)
                // Contenido REAL de la página para que el resumen de la IA sea rico y fiel
                // (mismo camino que el enriquecido automático). Reutiliza el extractor.
                let pageContent = await AIBatchEnricher.pageContentExcerpt(for: effectiveURL)
                // Si el usuario cambió la URL mientras tanto, no apliques datos viejos —y
                // libera el estado de sugerencia para no dejar el botón bloqueado.
                guard url.trimmingCharacters(in: .whitespaces) == rawURL else {
                    isSuggesting = false; isAutoSuggesting = false; stopPhaseCycler(); return
                }
                if title.trimmingCharacters(in: .whitespaces).isEmpty, let t = pageTitle { title = t }
                if details.trimmingCharacters(in: .whitespaces).isEmpty, let d = pageDescription { details = d }
                if imageURL == nil { imageURL = meta.imageURL }
                if siteName == nil || siteName?.isEmpty == true { siteName = meta.siteName }

                // 2) UNA sola llamada al modelo Liquid: título mejorado + descripción rica
                //    + categoría + etiquetas, TODO traducido al idioma activo.
                let service = UnifiedAIService(provider: "liquid")
                let result = try await service.enrich(
                    url: effectiveURL,
                    pageTitle: pageTitle,
                    pageDescription: pageDescription,
                    siteName: meta.siteName,
                    existingCategories: existingCategoryNames,
                    language: language,
                    pageContent: pageContent)
                // Si el usuario cambió la URL mientras la IA trabajaba, descarta el
                // resultado (es de otra URL) en vez de sobrescribir el formulario.
                guard url.trimmingCharacters(in: .whitespaces) == rawURL else {
                    isSuggesting = false; isAutoSuggesting = false; stopPhaseCycler(); return
                }
                // Título: para COMANDOS, el nombre del paquete (el 8B alucina títulos de
                // paquetes, p. ej. inventa un videojuego); para enlaces normales, el de la IA.
                if let commandInfo {
                    title = commandInfo.packageName
                } else if !result.title.isEmpty {
                    title = result.title
                }
                if !result.summary.isEmpty { details = result.summary }
                applySuggestedTags(result.tags)
                // CATEGORÍA fiable (que NO se equivoca): determinista según el tipo de
                // contenido/plataforma (AutoCategorizer: código→Desarrollo, vídeo→Vídeos,
                // juego→Juegos, diseño→Diseño…). La categoría LIBRE del modelo SOLO se usa
                // en contenido genérico (.website), donde no hay señal determinista, y nunca
                // para comandos. Así se eliminan los desajustes absurdos (p. ej. zod→Videojuegos).
                if needsCategory {
                    if let det = AutoCategorizer.suggestion(contentType: meta.contentType, platform: meta.platform) {
                        applySuggestedCategory(det.name)
                    } else if commandInfo == nil, !result.category.trimmingCharacters(in: .whitespaces).isEmpty {
                        applySuggestedCategory(result.category)
                    }
                }
                isSuggesting = false
                isAutoSuggesting = false
                stopPhaseCycler()
            } catch {
                // El autocompletado AUTOMÁTICO no molesta con alertas si falla.
                if !auto {
                    aiMessage = error.localizedDescription
                    showAIMessage = true
                }
                isSuggesting = false
                isAutoSuggesting = false
                stopPhaseCycler()
            }
        }
    }

    /// Cicla las fases del indicador «Generando…» cada 2,5 s para dar feedback visual.
    private func startPhaseCycler() {
        suggestPhase = 0
        phaseTask?.cancel()
        phaseTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { break }
                withAnimation(.easeInOut(duration: 0.35)) { suggestPhase += 1 }
            }
        }
    }

    private func stopPhaseCycler() {
        phaseTask?.cancel()
        phaseTask = nil
    }

    /// Selecciona la categoría sugerida por la IA: reutiliza una equivalente existente (vía el
    /// resolutor canónico ÚNICO) o crea una nueva con el nombre preferido. Solo actúa si el
    /// usuario no eligió categoría.
    private func applySuggestedCategory(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, categoryID == nil,
              let category = EntityResolver.category(name, in: context) else { return }
        categoryID = category.id
    }

    /// Selecciona las etiquetas sugeridas, creando las que no existan. Normaliza y
    /// DEDUPLICA (sin distinguir mayúsculas/acentos ni casi-duplicados como
    /// «videojuego»/«videojuegos») para no llenar de etiquetas redundantes.
    private func applySuggestedTags(_ names: [String]) {
        var usedKeys = Set<String>()
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespaces)
            guard name.count >= 2 else { continue }
            // Misma clave canónica que el resolutor (sin acentos, singular/plural) para no
            // repetir dentro de la propia sugerencia; el resolutor deduplica contra lo guardado.
            guard usedKeys.insert(EntityResolver.tagKey(name)).inserted else { continue }
            if let tag = EntityResolver.tag(name, in: context) {
                selectedTagIDs.insert(tag.id)
            }
        }
    }

    /// Comparte con Finder la lectura, validación y límites de los adjuntos.
    private func handlePickedFile(_ result: Result<URL, Error>) {
        guard case let .success(fileURL) = result else {
            if case let .failure(error) = result, (error as? CocoaError)?.code != .userCancelled { fileError = error.localizedDescription }
            return
        }
        fileLoadTask?.cancel()
        fileLoadTask = Task {
            let prepared = await DroppedContentImporter.prepare([fileURL])
            guard !Task.isCancelled else { return }
            guard let document = prepared.documents.first else {
                fileError = prepared.rejections.first?.reason ?? "No se pudo leer el archivo."
                fileLoadTask = nil
                return
            }
            withAnimation(.snappy) {
                fileData = document.data
                fileKind = document.kind
                documentAuthor = document.author
                if title.trimmingCharacters(in: .whitespaces).isEmpty { title = document.title }
            }
            fileLoadTask = nil
        }
    }

    private func localFileDescription(for kind: String) -> String {
        switch kind {
        case "image": "Imagen adjunta"
        case "epub": "Libro EPUB adjunto"
        case "audio": "Audio adjunto"
        case "video": "Vídeo adjunto"
        default: "Documento PDF adjunto"
        }
    }

    private func localFileFallbackTitle(for kind: String?) -> String {
        switch kind {
        case "image": "Imagen"
        case "epub": "Libro"
        case "audio": "Audio"
        case "video": "Vídeo"
        default: "Documento"
        }
    }

    private func localFileSiteName(for kind: String?) -> String {
        switch kind {
        case "image": "Imagen"
        case "epub": "EPUB"
        case "audio": "Audio"
        case "video": "Vídeo"
        default: "PDF"
        }
    }

    /// Re-comprueba si el portapapeles trae una URL `http(s)` (al abrir y al volver a
    /// primer plano). Solo lee texto cuando la app está activa; si no hay URL, no muestra
    /// nada. Reutiliza el detector compartido `ClipboardLink` (mismo que el banner de
    /// ventana) para no duplicar la lógica de lectura de `NSPasteboard`.
    private func refreshClipboardSuggestion() {
        guard !isEditing else { return }
        withAnimation(.snappy) { clipboardURL = ClipboardLink.currentURLString() }
    }

    /// Pega la URL del portapapeles en el campo y dispara el flujo de metadatos + IA ya
    /// existente (`autoFetchMetadata` + `autoSuggestIfNeeded`, vía `onChange(of: url)`).
    private func pasteFromClipboard() {
        guard let pasted = clipboardURL ?? ClipboardLink.currentURLString() else { return }
        url = pasted
        clipboardURL = nil
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        switch target {
        case .new(let prefilled):
            url = prefilled ?? ""
            if !url.trimmingCharacters(in: .whitespaces).isEmpty { autoFetchMetadata(for: url) }
        case .edit(let link):
            url = link.url; title = link.title; details = link.details ?? ""
            notes = link.notes ?? ""; isFavorite = link.isFavorite
            categoryID = link.category?.id; readingStatus = link.readingStatus
            selectedTagIDs = Set(link.tags.map(\.id))
            imageURL = link.imageURL
            faviconURL = link.faviconURL
            siteName = link.siteName
            platform = link.platform
            contentType = link.contentType
            platformColor = link.platformColor
            fileData = link.fileData
            fileKind = link.fileKind
            documentAuthor = link.author
            if let date = link.reminderAt {
                hasReminder = true
                reminderDate = date
            }
            sessionID = sessions.first(where: { $0.links.contains(where: { $0.id == link.id }) })?.id
        }
    }

    private func save() {
        let isFile = fileData != nil
        var trimmedURL = url.trimmingCharacters(in: .whitespaces)
        // Comando de instalación (npm i…, pip install…, brew install…): se guarda apuntando
        // a la página del registro del paquete y se conserva el comando original en
        // `link.command` (lo muestra `CommandCard`). Reutiliza el detector compartido.
        let commandInfo = isFile ? nil : CommandDetector.detect(trimmedURL)
        if let commandInfo { trimmedURL = commandInfo.registryURL }
        let detection = PlatformDetector.detect(trimmedURL)
        let resolvedPlatform: Platform = isFile ? .local : (commandInfo?.platform ?? detection.platform)
        let resolvedContentType: ContentType = isFile ? (fileKind == "audio" ? .music : fileKind == "video" ? .video : .document) : (commandInfo != nil ? .code : detection.contentType)
        let resolvedColor: String? = isFile ? nil : (commandInfo?.colorHex ?? detection.brandColorHex)
        let category = categoryID.flatMap { id in categories.first { $0.id == id } }
        let tags = allTags.filter { selectedTagIDs.contains($0.id) }
        // Título por defecto: el paquete (comando), el host o el tipo de archivo.
        let finalTitle: String = {
            if !title.isEmpty { return title }
            if isFile { return localFileFallbackTitle(for: fileKind) }
            return commandInfo?.packageName ?? URL(string: trimmedURL)?.host() ?? trimmedURL
        }()

        let savedLink: Bookmark

        switch target {
        case .new:
            // Dedup: si ya existe la MISMA página (clave canónica), no crear otra — vuelca
            // las ediciones del usuario sobre la existente y selecciónala.
            let dupKey = isFile ? "" : CanonicalURL.key(trimmedURL)
            if !dupKey.isEmpty,
               let existing = (((try? context.fetch(FetchDescriptor<Bookmark>(
                   predicate: #Predicate { $0.deletedAt == nil }))) ?? [])
                   .first(where: { CanonicalURL.key($0.url) == dupKey })) {
                // Edición manual sobre un enlace existente: protégela del enriquecido automático.
                if !title.isEmpty { if finalTitle != existing.title { UserEditLedger.markTitleEdited(existing.id) }; existing.title = finalTitle }
                if !details.isEmpty { if details != existing.details { UserEditLedger.markDetailsEdited(existing.id) }; existing.details = details }
                LinkIngest.userChangedText(existing.id)
                if let category { existing.category = category }
                for t in tags where !existing.tags.contains(where: { $0.id == t.id }) { existing.tags.append(t) }
                LinkIngest.userChangedOrganization(existing.id)
                if isFavorite { existing.isFavorite = true }
                if !notes.isEmpty { existing.notes = notes }
                existing.readingStatus = readingStatus
                existing.updatedAt = Date()
                context.saveLogging()
                savedLink = existing
                SpotlightIndexer.index(existing)
                break
            }
            let link = Bookmark(url: isFile ? "" : trimmedURL, title: finalTitle,
                                details: details.isEmpty ? nil : details,
                                category: category, tags: tags, isFavorite: isFavorite,
                                notes: notes.isEmpty ? nil : notes, readingStatus: readingStatus,
                                platform: resolvedPlatform,
                                contentType: resolvedContentType)
            link.imageURL = imageURL
            link.faviconURL = faviconURL
            link.siteName = isFile ? localFileSiteName(for: fileKind) : siteName
            if isFile { link.author = documentAuthor }
            link.platformColor = resolvedColor
            link.command = commandInfo?.command
            link.fileData = fileData
            link.fileKind = fileKind
            context.insert(link)
            // Auto-etiquetas y auto-categoría deterministas con lo que ya se conoce
            // (reglas de seguridad sobre el enlace), igual que el iPhone.
            if !isFile { LinkEnricher.autoOrganize(link, in: context) }
            // Reglas de clasificación del usuario (sección «Reglas»): también al crear
            // desde el editor, para que clasifiquen de verdad (añaden etiquetas y fijan
            // la colección si aún no tiene). Mismo [[ClassificationEngine]] compartido.
            let rules = (try? context.fetch(FetchDescriptor<ClassificationRule>())) ?? []
            if !rules.isEmpty {
                ClassificationEngine.apply(to: link, rules: rules, categories: categories, tags: allTags)
            }
            context.saveLogging()
            savedLink = link
            SpotlightIndexer.index(link)
            // Enriquecido en segundo plano: enlaces sin plataforma aún Y comandos (para
            // traer título/descripción/imagen de la página del paquete).
            if !isFile, link.platform == .generic || commandInfo != nil {
                let overwrite = title.trimmingCharacters(in: .whitespaces).isEmpty
                Task { await MacLinkEnricher.enrichFromNetwork(link, in: context, overwriteTitle: overwrite) }
            }
        case .edit(let link):
            let organizationChanged = link.category?.id != category?.id || Set(link.tags.map(\.id)) != Set(tags.map(\.id))
            // Si el usuario CAMBIÓ el título o la descripción a mano, márcalos como «editado por ti»
            // para que el enriquecido automático no los pise ([[UserEditLedger]]).
            if finalTitle != link.title { UserEditLedger.markTitleEdited(link.id) }
            let newDetails = details.isEmpty ? nil : details
            if newDetails != link.details { UserEditLedger.markDetailsEdited(link.id) }
            link.url = trimmedURL; link.title = finalTitle
            link.details = details.isEmpty ? nil : details
            link.notes = notes.isEmpty ? nil : notes
            link.isFavorite = isFavorite; link.category = category; link.tags = tags
            LinkIngest.userChangedText(link.id)
            if organizationChanged { LinkIngest.userChangedOrganization(link.id) }
            link.readingStatus = readingStatus; link.updatedAt = Date()
            if let c = commandInfo?.command { link.command = c }   // preserva el existente si no es comando
            link.fileData = fileData
            link.fileKind = fileKind
            if isFile {
                link.url = ""
                link.platform = .local
                link.contentType = resolvedContentType
                link.siteName = localFileSiteName(for: fileKind)
                link.author = documentAuthor
            }
            context.saveLogging()
            savedLink = link
            SpotlightIndexer.index(link)
        }

        applyCollection(to: savedLink)
        applyReminder(to: savedLink)
        context.saveLogging()
        if savedLink.fileKind != nil, savedLink.fileKind != "audio", savedLink.fileKind != "video", savedLink.offlineText == nil {
            // Tarea independiente del ciclo de vida de la hoja: al cerrarla continúa en
            // segundo plano y el coordinador cede mientras el usuario interactúa.
            Task { @MainActor in
                _ = try? await DocumentTextCoordinator.indexIfNeeded(
                    savedLink, in: context, waitForIdle: true
                )
            }
        }
        dismiss()
    }

    /// Sincroniza la pertenencia del enlace a la colección (sesión) elegida.
    private func applyCollection(to link: Bookmark) {
        for session in sessions where session.links.contains(where: { $0.id == link.id }) {
            session.links.removeAll { $0.id == link.id }
        }
        if let sessionID, let session = sessions.first(where: { $0.id == sessionID }),
           !session.links.contains(where: { $0.id == link.id }) {
            session.links.append(link)
        }
    }

    /// Programa o cancela el recordatorio del enlace según el formulario.
    private func applyReminder(to link: Bookmark) {
        if hasReminder {
            link.reminderAt = reminderDate
            let id = link.id, title = link.title, host = link.url.urlHost, date = reminderDate
            Task { await ReminderService.schedule(id: id, title: title, host: host, at: date) }
        } else if link.reminderAt != nil {
            link.reminderAt = nil
            ReminderService.cancel(id: link.id)
        }
    }
}
