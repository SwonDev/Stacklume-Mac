import SwiftUI
import SwiftData
import OSLog
import StacklumeCore
import StacklumeDesignSystem

struct ModelCatalogSaveSheet: View {
    let selection: ModelCatalogSaveSelection
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @Environment(\.appTheme) private var theme
    @Query(filter: #Predicate<BookmarkCategory> { $0.deletedAt == nil }, sort: \BookmarkCategory.order) private var collections: [BookmarkCategory]
    @Query(filter: #Predicate<Tag> { $0.deletedAt == nil }, sort: \Tag.name) private var allTags: [Tag]
    @State private var collection: BookmarkCategory?
    @State private var automaticCollection = true
    @State private var tags: [Tag] = []
    @State private var favorite = false
    @State private var readingStatus: ReadingStatus = .inbox
    @State private var showsCollections = false
    @State private var showsTags = false
    @State private var saved = false
    @State private var savedMessage: String?
    @State private var error: String?
    @State private var isSaving = false
    @State private var existingLink: Bookmark?
    @State private var newCollection = ""
    @State private var newTag = ""
    @State private var appendArtifactDetails = false
    @State private var lookupCompleted = false
    @State private var lookupFailed = false
    @State private var lookupTraceID = UUID().uuidString
    private static let lookupLog = Logger(subsystem: "com.swondev.stacklume", category: "ModelCatalogOrganization")

    private enum LookupPhase: String {
        case appeared, taskStarted, missingURL, fetched, unmatched, stateAssigned, linkChanged, automaticChanged, disappeared
    }

    var body: some View {
        EditorScaffold(title: selection.artifact != nil ? "Guardar ejemplo o publicación" : selection.version == nil ? "Guardar modelo" : "Guardar versión", confirmTitle: saved ? "Hecho" : "Guardar en mi biblioteca", canConfirm: !isSaving && lookupCompleted && !lookupFailed && selection.url != nil, onCancel: { dismiss() }, onConfirm: { if saved { dismiss() } else { save() } }) {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    ModelCatalogFormSection("Selección") {
                        Text(selection.title).stacklumeFont(.headline).textSelection(.enabled)
                        if let version = selection.version { Text("Versión: \(version.name)") }
                        if selection.artifact != nil, selection.artifact?.kind == .widget || selection.artifact?.url == selection.item.bookmarkURL() { Text("Este ejemplo pertenece a la ficha del modelo y comparte su marcador. La organización se aplica a esa ficha.").stacklumeFont(.caption).foregroundStyle(palette.textSecondary) }
                        if let url = selection.url {
                            Text(url.absoluteString).stacklumeFont(.caption).foregroundStyle(palette.textSecondary).textSelection(.enabled)
                        }
                        if let existingLink {
                            Text("Ubicación actual: \(existingLink.category?.name ?? "Sin clasificar")").stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                            if !existingLink.tags.isEmpty { Text("Etiquetas actuales: \(existingLink.tags.map(\.name).joined(separator: ", "))").stacklumeFont(.caption).foregroundStyle(palette.textSecondary) }
                            Text("Este marcador ya está en tu biblioteca. Puedes actualizar su organización sin crear otro.")
                                .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                        }
                    }
                    if !saved {
                        ModelCatalogFormSection("Organizar") {
                            Toggle(existingLink == nil ? "Clasificar la colección automáticamente" : "Mantener la colección actual", isOn: $automaticCollection)
                            if !automaticCollection {
                                Button { showsCollections = true } label: {
                                    Label(collection?.name ?? "Sin clasificar", systemImage: collection?.icon ?? "tray")
                                }
                                .stacklumeButton(prominent: false)
                                .themedHelp("Elegir la colección para este marcador")
                            }
                            Button { showsTags = true } label: { Label("Elegir etiquetas…", systemImage: "tag") }
                                .stacklumeButton(prominent: false)
                            if !tags.isEmpty {
                                ForEach(tags) { tag in
                                    HStack {
                                        Text(tag.name)
                                        Spacer()
                                        Button { tags.removeAll { $0.id == tag.id } } label: { Image(systemName: "xmark.circle") }
                                            .buttonStyle(.plain).accessibilityLabel("Quitar etiqueta \(tag.name)")
                                            .themedHelp("Quitar esta etiqueta de la selección")
                                    }
                                }
                            }
                            DisclosureGroup("Crear colección o etiqueta") {
                                ModelCatalogField("Nombre de colección", text: $newCollection)
                                Button("Crear y elegir colección") {
                                    if let value = EntityResolver.category(newCollection, in: context) {
                                        collection = value; automaticCollection = false; newCollection = ""
                                        do { try context.save() } catch { self.error = error.localizedDescription }
                                    }
                                }
                                .stacklumeButton(prominent: false)
                                .disabled(newCollection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newCollection.count > 200)
                                ModelCatalogField("Nombre de etiqueta", text: $newTag)
                                Button("Crear y añadir etiqueta") {
                                    if let value = EntityResolver.tag(newTag, in: context) {
                                        if !tags.contains(where: { $0.id == value.id }) { tags.append(value) }
                                        newTag = ""
                                        do { try context.save() } catch { self.error = error.localizedDescription }
                                    }
                                }
                                .stacklumeButton(prominent: false)
                                .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newTag.count > 200)
                            }
                            if selection.artifact != nil, existingLink != nil {
                                Toggle("Añadir procedencia y parámetros a la descripción actual", isOn: $appendArtifactDetails)
                            }
                            Toggle("Marcar como favorito", isOn: $favorite)
                            ModelCatalogPicker("Estado de lectura", selection: $readingStatus) {
                                Text("Bandeja").tag(ReadingStatus.inbox)
                                Text("Cola de lectura").tag(ReadingStatus.reading)
                                Text("Leído").tag(ReadingStatus.done)
                            }
                        }
                        .disabled(!lookupCompleted || lookupFailed)
                    }
                    if let savedMessage { ModelCatalogFormSection { Label(savedMessage, systemImage: "checkmark.circle").foregroundStyle(palette.textPrimary) } }
                    if let error {
                        ModelCatalogFormSection {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(palette.textPrimary)
                            if lookupFailed {
                                Button("Volver a comprobar") { loadExistingSelection() }
                                    .stacklumeButton(prominent: false)
                            }
                        }
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }
        }
        .frame(minWidth: 340, idealWidth: 520, maxWidth: 640, minHeight: 380, idealHeight: 590, maxHeight: 720)
        .onAppear { recordLookup(.appeared) }
        .task { loadExistingSelection() }
        .onChange(of: existingLink != nil) { recordLookup(.linkChanged) }
        .onChange(of: automaticCollection) { recordLookup(.automaticChanged) }
        .onDisappear { recordLookup(.disappeared) }
        .sheet(isPresented: $showsCollections) {
            BulkCollectionPickerSheet(collections: collections, title: "Colección", noneLabel: "Sin clasificar") { collection = $0 }
                .themedSheet(palette, theme)
        }
        .sheet(isPresented: $showsTags) {
            BulkTagPickerSheet(tags: allTags, count: 1) { tag in
                if !tags.contains(where: { $0.id == tag.id }) { tags.append(tag) }
            }
            .themedSheet(palette, theme)
        }
    }

    private func save() {
        guard let url = selection.url else { error = "La selección no tiene una página válida en el proveedor."; return }
        isSaving = true; error = nil
        let category = automaticCollection ? nil : collection
        let organization: LinkIngest.UserOrganization? = automaticCollection && tags.isEmpty ? nil : .init(category: category, tags: tags, preservesCategory: !automaticCollection)
        let title = selection.title
        let result = LinkIngest.ingestLinks([.init(urlString: url.absoluteString, suggestedTitle: title)], in: context, category: category, aiEnrich: true, userOrganization: organization)
        guard let link = result.added.first ?? result.skipped.first else { isSaving = false; error = "No se pudo guardar el marcador."; return }
        if !result.added.isEmpty {
            link.isFavorite = favorite; link.readingStatus = readingStatus
            let licenses = selection.item.licenses(for: selection.version)
            let description = selection.item.metadataMatches(version: selection.version) ? selection.item.description : ""
            let facts = selection.details ?? [description, selection.version.map { "Versión: \($0.name)" }, selection.version?.baseModel.map { "Modelo base: \($0)" }, selection.version?.revision.map { "Revisión: \($0)" }, licenses.isEmpty ? nil : "Licencia: \(licenses.joined(separator: ", "))"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            if let thumbnail = selection.artifact?.media?.thumbnailURL ?? (selection.artifact?.media?.kind == .image ? selection.artifact?.media?.url : nil) { link.imageURL = thumbnail.absoluteString }
            if !facts.isEmpty { link.details = facts; UserEditLedger.markDetailsEdited(link.id) }
            UserEditLedger.markTitleEdited(link.id)
        } else {
            if !automaticCollection { link.category = collection }
            if existingLink != nil { link.tags = tags }
            else { for tag in tags where !link.tags.contains(where: { $0.id == tag.id }) { link.tags.append(tag) } }
            LinkIngest.userChangedOrganization(link.id)
            if appendArtifactDetails, let facts = selection.details, !facts.isEmpty {
                link.details = [link.details, facts].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                UserEditLedger.markDetailsEdited(link.id); LinkIngest.userChangedText(link.id)
            }
            if existingLink != nil || favorite { link.isFavorite = favorite }
            if existingLink != nil || readingStatus != .inbox { link.readingStatus = readingStatus }
        }
        link.updatedAt = .now
        do {
            try context.save()
            NotificationCenter.default.post(name: .stacklumeModelDidSave, object: nil)
            SpotlightIndexer.index(link); saved = true
            savedMessage = result.added.isEmpty ? "Este marcador ya estaba en tu biblioteca. Se ha actualizado la organización elegida." : "Recurso guardado en tu biblioteca."
        }
        catch { self.error = "No se pudo guardar la biblioteca. \(error.localizedDescription)" }
        isSaving = false
    }

    private func loadExistingSelection() {
        lookupCompleted = false
        defer { lookupCompleted = true }
        lookupFailed = false
        error = nil
        recordLookup(.taskStarted)
        let isMainContext = context === context.container.mainContext
        let hasPendingChanges = context.hasChanges
        let isCancelled = Task.isCancelled
        Self.lookupLog.info("lookup trace=\(lookupTraceID, privacy: .public) mainContext=\(isMainContext, privacy: .public) pendingChanges=\(hasPendingChanges, privacy: .public) cancelled=\(isCancelled, privacy: .public)")
        guard let url = selection.url?.absoluteString else { recordLookup(.missingURL); return }
        let normalized = LinkIngest.normalizeURL(url)
        let base = selection.artifact?.url?.absoluteString ?? selection.item.bookmarkURL()?.absoluteString ?? normalized
        let resourcePath = URL(string: base)?.path ?? base
        let descriptor = FetchDescriptor<Bookmark>(predicate: #Predicate { $0.deletedAt == nil && $0.url.localizedStandardContains(resourcePath) })
        let key = CanonicalURL.key(normalized)
        do {
            let candidates = try context.fetch(descriptor)
            recordLookup(.fetched, candidateCount: candidates.count)
            guard let link = candidates.first(where: { CanonicalURL.key($0.url) == key }) else { recordLookup(.unmatched); return }
            existingLink = link; collection = link.category; automaticCollection = false
            tags = link.tags; favorite = link.isFavorite; readingStatus = link.readingStatus
            recordLookup(.stateAssigned)
        } catch {
            lookupFailed = true
            self.error = "No se pudo comprobar si este recurso ya está en tu biblioteca. Vuelve a comprobarlo antes de guardar."
            let failure = error as NSError
            let unsupportedPredicate = (error as? SwiftDataError) == .unsupportedPredicate
            let unsupportedKeyPath = (error as? SwiftDataError) == .unsupportedKeyPath
            Self.lookupLog.info("lookup trace=\(lookupTraceID, privacy: .public) phase=fetchFailed domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public) unsupportedPredicate=\(unsupportedPredicate, privacy: .public) unsupportedKeyPath=\(unsupportedKeyPath, privacy: .public)")
        }
    }

    private func recordLookup(_ phase: LookupPhase, candidateCount: Int = -1) {
        let found = existingLink != nil
        Self.lookupLog.info("lookup trace=\(lookupTraceID, privacy: .public) phase=\(phase.rawValue, privacy: .public) candidates=\(candidateCount, privacy: .public) existing=\(found, privacy: .public) automatic=\(automaticCollection, privacy: .public)")
    }
}
