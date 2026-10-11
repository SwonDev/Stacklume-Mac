import AppIntents
import SwiftData
import StacklumeCore
import StacklumePersistence

/// Guarda un enlace en la biblioteca desde Siri, Atajos o Spotlight.
struct AddBookmarkIntent: AppIntent {
    static let title: LocalizedStringResource = "Añadir enlace a Stacklume"
    static let description = IntentDescription("Guarda un enlace en tu biblioteca de Stacklume y lo organiza automáticamente.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Enlace", description: "La URL que quieres guardar.")
    var url: URL

    static var parameterSummary: some ParameterSummary {
        Summary("Guardar \(\.$url) en Stacklume")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try CommercialLicenseAccessPolicy.requireAccess()
        guard StacklumeAutomationAccess.isAllowed(.capture) else {
            StacklumeAutomationAuditLog.record(
                capability: .capture, action: .captureOne, outcome: .blocked, itemCount: 1
            )
            return .result(
                dialog: "La captura desde Atajos está desactivada. Actívala en Stacklume › Ajustes › Privacidad."
            )
        }
        guard let webURL = DroppedContentImporter.validatedWebURL(url.absoluteString),
              StacklumeAutomationPolicy.allowsExternalCaptureURL(webURL) else {
            StacklumeAutomationAuditLog.record(
                capability: .capture, action: .captureOne, outcome: .blocked, itemCount: 1
            )
            return .result(
                dialog: "El enlace debe usar HTTP o HTTPS, ser público y no incluir credenciales."
            )
        }
        let container = PersistenceController.makeContainer()
        let context = ModelContext(container)
        let result = LinkIngest.ingestLinks(
            [.init(urlString: webURL.absoluteString)],
            in: context,
            category: nil,
            aiEnrich: true
        )
        if let link = result.added.first {
            StacklumeAutomationAuditLog.record(
                capability: .capture, action: .captureOne, outcome: .completed, itemCount: 1
            )
            return .result(dialog: "Guardado «\(link.title)» en Stacklume.")
        }
        StacklumeAutomationAuditLog.record(
            capability: .capture, action: .captureOne, outcome: .completed, itemCount: 0
        )
        return .result(dialog: "Ese enlace ya estaba en Stacklume.")
    }
}

/// Alta por lotes para automatizaciones de Atajos, usando la misma deduplicación y
/// el mismo pipeline que el resto de capturas de la app.
struct AddBookmarksIntent: AppIntent {
    static let title: LocalizedStringResource = "Añadir varios enlaces a Stacklume"
    static let description = IntentDescription("Guarda varios enlaces de una vez, sin crear duplicados.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Enlaces", description: "Las URLs que quieres guardar.")
    var urls: [URL]

    static var parameterSummary: some ParameterSummary {
        Summary("Guardar \(\.$urls) en Stacklume")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try CommercialLicenseAccessPolicy.requireAccess()
        guard StacklumeAutomationAccess.isAllowed(.capture) else {
            StacklumeAutomationAuditLog.record(
                capability: .capture, action: .captureBatch, outcome: .blocked, itemCount: urls.count
            )
            return .result(
                dialog: "La captura desde Atajos está desactivada. Actívala en Stacklume › Ajustes › Privacidad."
            )
        }
        let acceptedInput = Array(urls.prefix(DroppedContentImporter.maximumItemCount))
        let validURLs: [URL] = acceptedInput.compactMap { inputURL -> URL? in
            guard let validatedURL = DroppedContentImporter.validatedWebURL(inputURL.absoluteString),
                  StacklumeAutomationPolicy.allowsExternalCaptureURL(validatedURL)
            else { return nil }
            return validatedURL
        }
        guard !validURLs.isEmpty else {
            StacklumeAutomationAuditLog.record(
                capability: .capture, action: .captureBatch, outcome: .blocked,
                itemCount: acceptedInput.count
            )
            return .result(dialog: "No había enlaces públicos HTTP o HTTPS válidos para guardar.")
        }
        let context = ModelContext(PersistenceController.makeContainer())
        let result = LinkIngest.ingestLinks(
            validURLs.map { LinkIngest.IngestItem(urlString: $0.absoluteString) },
            in: context,
            category: nil,
            aiEnrich: true
        )
        StacklumeAutomationAuditLog.record(
            capability: .capture, action: .captureBatch, outcome: .completed,
            itemCount: result.added.count
        )
        let rejectedCount = urls.count - validURLs.count
        return .result(
            dialog: "Guardados: \(result.added.count); duplicados: \(result.skipped.count); rechazados: \(rejectedCount)."
        )
    }
}

/// Abre Stacklume.
struct OpenStacklumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Abrir Stacklume"
    static let description = IntentDescription("Abre la app Stacklume.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}

/// Busca enlaces guardados por palabra clave y devuelve sus URLs (para encadenar en Atajos).
struct SearchBookmarksIntent: AppIntent {
    static let title: LocalizedStringResource = "Buscar enlaces en Stacklume"
    static let description = IntentDescription("Busca enlaces guardados por palabra clave (título, URL, etiqueta, colección o descripción) y devuelve sus direcciones.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Búsqueda", description: "Palabra o frase a buscar.")
    var query: String
    @Parameter(title: "Máximo de resultados", default: 20)
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Buscar \(\.$query) en Stacklume")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[URL]> & ProvidesDialog {
        try CommercialLicenseAccessPolicy.requireAccess()
        guard StacklumeAutomationAccess.isAllowed(.read) else {
            StacklumeAutomationAuditLog.record(
                capability: .read, action: .search, outcome: .blocked, itemCount: 0
            )
            return .result(
                value: [],
                dialog: "La consulta desde Atajos está desactivada. Actívala en Stacklume › Ajustes › Privacidad."
            )
        }
        let context = ModelContext(PersistenceController.makeContainer())
        let cleanQuery = StacklumeAutomationPolicy.sanitizedQuery(query)
        let parsedQuery = SearchQuery.parse(cleanQuery)
        let resultLimit = StacklumeAutomationPolicy.resultLimit(limit)
        let all = ((try? context.fetch(FetchDescriptor<Bookmark>())) ?? [])
            .filter { $0.deletedAt == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
        let urls = all.lazy
            .filter { parsedQuery.lexicalMatches($0) }
            .compactMap { DroppedContentImporter.validatedWebURL($0.url) }
            .prefix(resultLimit)
        StacklumeAutomationAuditLog.record(
            capability: .read, action: .search, outcome: .completed, itemCount: urls.count
        )
        return .result(value: Array(urls),
                       dialog: urls.isEmpty ? "No encontré enlaces con esos criterios."
                                            : "Encontré \(urls.count) enlace(s).")
    }
}

/// Abre un enlace al azar de la biblioteca (descubrimiento, como «Open Random» de GoodLinks).
struct RandomBookmarkIntent: AppIntent {
    static let title: LocalizedStringResource = "Abrir un enlace al azar de Stacklume"
    static let description = IntentDescription("Abre en el navegador un enlace aleatorio de tu biblioteca.")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent & ProvidesDialog {
        try CommercialLicenseAccessPolicy.requireAccess()
        guard StacklumeAutomationAccess.isAllowed(.read) else {
            StacklumeAutomationAuditLog.record(
                capability: .read, action: .openRandom, outcome: .blocked, itemCount: 0
            )
            return .result(
                opensIntent: OpenStacklumeIntent(),
                dialog: "La consulta desde Atajos está desactivada. Actívala en Stacklume › Ajustes › Privacidad."
            )
        }
        let context = ModelContext(PersistenceController.makeContainer())
        let all = ((try? context.fetch(FetchDescriptor<Bookmark>())) ?? [])
            .filter { $0.deletedAt == nil && !$0.isArchived }
            .compactMap { link in
                DroppedContentImporter.validatedWebURL(link.url).map { (link, $0) }
            }
        guard let (pick, url) = all.randomElement() else {
            StacklumeAutomationAuditLog.record(
                capability: .read, action: .openRandom, outcome: .completed, itemCount: 0
            )
            return .result(opensIntent: OpenStacklumeIntent(), dialog: "No hay enlaces guardados.")
        }
        StacklumeAutomationAuditLog.record(
            capability: .read, action: .openRandom, outcome: .completed, itemCount: 1
        )
        return .result(opensIntent: OpenURLIntent(url), dialog: "Abriendo «\(pick.title)».")
    }
}

/// Abre el enlace SIN LEER más reciente (retomar la lectura pendiente).
struct OpenLastUnreadIntent: AppIntent {
    static let title: LocalizedStringResource = "Abrir el último enlace sin leer de Stacklume"
    static let description = IntentDescription("Abre el enlace pendiente de leer más reciente.")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent & ProvidesDialog {
        try CommercialLicenseAccessPolicy.requireAccess()
        guard StacklumeAutomationAccess.isAllowed(.read) else {
            StacklumeAutomationAuditLog.record(
                capability: .read, action: .openUnread, outcome: .blocked, itemCount: 0
            )
            return .result(
                opensIntent: OpenStacklumeIntent(),
                dialog: "La consulta desde Atajos está desactivada. Actívala en Stacklume › Ajustes › Privacidad."
            )
        }
        let context = ModelContext(PersistenceController.makeContainer())
        let candidates = ((try? context.fetch(FetchDescriptor<Bookmark>())) ?? [])
            .filter { $0.deletedAt == nil && !$0.isRead && !$0.isArchived }
            .compactMap { link in
                DroppedContentImporter.validatedWebURL(link.url).map { (link, $0) }
            }
        guard let (pick, url) = candidates.max(by: { $0.0.createdAt < $1.0.createdAt }) else {
            StacklumeAutomationAuditLog.record(
                capability: .read, action: .openUnread, outcome: .completed, itemCount: 0
            )
            return .result(opensIntent: OpenStacklumeIntent(), dialog: "No tienes enlaces sin leer.")
        }
        StacklumeAutomationAuditLog.record(
            capability: .read, action: .openUnread, outcome: .completed, itemCount: 1
        )
        return .result(opensIntent: OpenURLIntent(url), dialog: "Abriendo «\(pick.title)».")
    }
}

/// Abre directamente la Bandeja para poder componer automatizaciones de captura + triaje.
struct OpenInboxIntent: AppIntent {
    static let title: LocalizedStringResource = "Abrir la Bandeja de Stacklume"
    static let description = IntentDescription("Abre las capturas pendientes de organizar.")
    static let supportedModes: IntentModes = .background

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "stacklume://section/inbox")!))
    }
}

/// Atajos sugeridos por el sistema (Siri / Spotlight / app Atajos).
struct StacklumeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddBookmarkIntent(),
            phrases: [
                "Añadir enlace a \(.applicationName)",
                "Guardar enlace en \(.applicationName)",
                "Guardar en \(.applicationName)"
            ],
            shortTitle: "Añadir enlace",
            systemImageName: "bookmark.fill"
        )
        AppShortcut(
            intent: AddBookmarksIntent(),
            phrases: [
                "Añadir varios enlaces a \(.applicationName)",
                "Guardar varios enlaces en \(.applicationName)"
            ],
            shortTitle: "Añadir varios",
            systemImageName: "square.stack.3d.up.fill"
        )
        AppShortcut(
            intent: OpenStacklumeIntent(),
            phrases: ["Abrir \(.applicationName)"],
            shortTitle: "Abrir",
            systemImageName: "square.grid.2x2.fill"
        )
        AppShortcut(
            intent: SearchBookmarksIntent(),
            phrases: [
                "Buscar enlaces en \(.applicationName)",
                "Buscar en \(.applicationName)"
            ],
            shortTitle: "Buscar enlaces",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: GetStacklumeBookmarksIntent(),
            phrases: [
                "Obtener mis enlaces de \(.applicationName)",
                "Obtener enlaces de \(.applicationName)"
            ],
            shortTitle: "Obtener enlaces",
            systemImageName: "list.bullet.rectangle"
        )
        AppShortcut(
            intent: RandomBookmarkIntent(),
            phrases: [
                "Abrir un enlace al azar de \(.applicationName)",
                "Enlace al azar de \(.applicationName)"
            ],
            shortTitle: "Enlace al azar",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: OpenLastUnreadIntent(),
            phrases: [
                "Abrir el último sin leer de \(.applicationName)",
                "Seguir leyendo en \(.applicationName)"
            ],
            shortTitle: "Último sin leer",
            systemImageName: "book"
        )
        AppShortcut(
            intent: OpenInboxIntent(),
            phrases: [
                "Abrir la bandeja de \(.applicationName)",
                "Revisar la bandeja de \(.applicationName)"
            ],
            shortTitle: "Abrir Bandeja",
            systemImageName: "tray.fill"
        )
    }
}
