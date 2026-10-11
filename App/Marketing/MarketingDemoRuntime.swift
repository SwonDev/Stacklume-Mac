import Foundation
import SwiftData
import StacklumeCore
import StacklumeDesignSystem

/// Entorno efímero para producir material de marketing con la interfaz real.
/// Solo se activa con `--stacklume-marketing-demo <escena>`.
enum MarketingDemoRuntime {
    enum Scene: String {
        case hero, list, grid, moodboard, headlines, ai, tags, filters
        case sessions, rules, stats, command, editor, theme
    }

    static let swiftCollectionID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    static let designCollectionID = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
    static let inspirationCollectionID = UUID(uuidString: "10000000-0000-4000-8000-000000000003")!
    static let readingCollectionID = UUID(uuidString: "10000000-0000-4000-8000-000000000004")!
    static let aiCollectionID = UUID(uuidString: "10000000-0000-4000-8000-000000000005")!
    static let toolsCollectionID = UUID(uuidString: "10000000-0000-4000-8000-000000000006")!
    static let swiftTagID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
    static let selectedBookmarkID = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!

    static var scene: Scene? {
        let arguments = ProcessInfo.processInfo.arguments
        if let inline = arguments.first(where: { $0.hasPrefix("--stacklume-marketing-demo=") }) {
            return Scene(rawValue: String(inline.dropFirst("--stacklume-marketing-demo=".count)))
        }
        guard let index = arguments.firstIndex(of: "--stacklume-marketing-demo"),
              arguments.indices.contains(index + 1)
        else { return nil }
        return Scene(rawValue: arguments[index + 1])
    }

    static var isActive: Bool { scene != nil }

    static var initialTarget: NavTarget {
        switch scene ?? .hero {
        case .grid, .theme: .collection(designCollectionID)
        case .moodboard: .collection(inspirationCollectionID)
        case .headlines: .collection(readingCollectionID)
        case .ai: .ai
        case .tags: .tag(swiftTagID)
        case .filters: .smart(.unread)
        case .sessions: .sessions
        case .rules: .rules
        case .stats: .stats
        case .hero, .list, .command, .editor: .collection(swiftCollectionID)
        }
    }

    static var selectedLinkIDs: Set<Bookmark.ID> {
        switch scene ?? .hero {
        case .hero, .list, .command, .editor: [selectedBookmarkID]
        default: []
        }
    }

    static var viewModeOverride: LibraryViewMode? {
        switch scene {
        case .grid, .theme: .grid
        case .moodboard: .moodboard
        case .headlines: .headlines
        case .hero, .list, .command, .editor: .list
        default: nil
        }
    }

    static var themeOverride: Theme? { scene == .theme ? .sakura : .dark }

    @MainActor
    static func seed(into container: ModelContainer) {
        guard isActive else { return }
        MarketingDemoSeeder(context: container.mainContext).seed()
    }
}

private struct MarketingBookmarkSpec {
    let id: Int
    let title: String
    let url: String
    let details: String
    let tags: [String]
    var platform: Platform = .generic
    var type: ContentType = .website
    var image: String?
    var favorite = false
    var read = false
    var stars: Int?
    var forks = 0
    var language: String?
}

@MainActor
private final class MarketingDemoSeeder {
    private let context: ModelContext
    private var categories: [String: BookmarkCategory] = [:]
    private var tags: [String: Tag] = [:]
    private var linksByID: [Int: Bookmark] = [:]

    init(context: ModelContext) {
        self.context = context
    }

    func seed() {
        seedSettings()
        seedTaxonomy()
        insert(Self.swiftSpecs, category: "swift")
        insert(Self.designSpecs, category: "design")
        insert(Self.inspirationSpecs, category: "inspiration")
        insert(Self.readingSpecs, category: "reading")
        insert(Self.aiSpecs, category: "ai")
        insert(Self.toolSpecs, category: "tools")
        seedSessions()
        seedRules()
        seedProject()
        seedAssistantConversation()
        context.saveLogging()
    }

    private func seedSettings() {
        let settings = AppSettings(themeID: MarketingDemoRuntime.themeOverride?.rawValue ?? Theme.dark.rawValue)
        settings.onboardingCompleted = true
        settings.aiProvider = "liquid"
        context.insert(settings)
    }

    private func seedTaxonomy() {
        let work = BookmarkCategory(
            id: UUID(uuidString: "10000000-0000-4000-8000-000000000010")!,
            name: "Trabajo", details: "Referencias activas para diseñar y construir.",
            icon: "briefcase.fill", colorHex: "#D4A853", order: 0
        )
        let reference = BookmarkCategory(
            id: UUID(uuidString: "10000000-0000-4000-8000-000000000011")!,
            name: "Referencia", details: "Lecturas, investigación e inspiración.",
            icon: "books.vertical.fill", colorHex: "#7AA2F7", order: 1
        )
        let entries: [(String, BookmarkCategory)] = [
            ("work", work),
            ("reference", reference),
            ("swift", BookmarkCategory(
                id: MarketingDemoRuntime.swiftCollectionID, name: "Swift & Apple",
                details: "Frameworks, diseño nativo y herramientas para Apple silicon.",
                icon: "swift", colorHex: "#F59E0B", order: 0, parent: work)),
            ("design", BookmarkCategory(
                id: MarketingDemoRuntime.designCollectionID, name: "Diseño de producto",
                details: "Interfaces claras, sistemas visuales y microinteracciones.",
                icon: "paintpalette.fill", colorHex: "#EC4899", order: 1, parent: work)),
            ("ai", BookmarkCategory(
                id: MarketingDemoRuntime.aiCollectionID, name: "IA local",
                details: "Modelos privados y flujos on-device.",
                icon: "sparkles", colorHex: "#22C55E", order: 2, parent: work)),
            ("tools", BookmarkCategory(
                id: MarketingDemoRuntime.toolsCollectionID, name: "Herramientas",
                details: "Utilidades abiertas para el trabajo diario.",
                icon: "wrench.and.screwdriver.fill", colorHex: "#38BDF8", order: 3, parent: work)),
            ("inspiration", BookmarkCategory(
                id: MarketingDemoRuntime.inspirationCollectionID, name: "Inspiración visual",
                details: "Arquitectura, materia, color y composición.",
                icon: "camera.aperture", colorHex: "#A78BFA", order: 0, parent: reference)),
            ("reading", BookmarkCategory(
                id: MarketingDemoRuntime.readingCollectionID, name: "Lecturas",
                details: "Artículos seleccionados para volver con tiempo.",
                icon: "text.book.closed.fill", colorHex: "#60A5FA", order: 1, parent: reference))
        ]
        for (key, category) in entries {
            categories[key] = category
            context.insert(category)
        }

        let tagEntries: [(String, Tag)] = [
            ("swift", Tag(id: MarketingDemoRuntime.swiftTagID, name: "SwiftUI", colorHex: "#F59E0B", order: 0)),
            ("local", Tag(name: "On-device", colorHex: "#22C55E", order: 1)),
            ("design", Tag(name: "Interfaz", colorHex: "#EC4899", order: 2)),
            ("read", Tag(name: "Por leer", colorHex: "#60A5FA", order: 3)),
            ("open", Tag(name: "Open source", colorHex: "#A78BFA", order: 4)),
            ("research", Tag(name: "Investigación", colorHex: "#38BDF8", order: 5)),
            ("performance", Tag(name: "Rendimiento", colorHex: "#F97316", order: 6)),
            ("apple", Tag(name: "Apple silicon", colorHex: "#EAB308", order: 7))
        ]
        for (key, tag) in tagEntries {
            tags[key] = tag
            context.insert(tag)
        }
    }

    private func insert(_ specs: [MarketingBookmarkSpec], category categoryKey: String) {
        guard let category = categories[categoryKey] else { return }
        let now = Date()
        for spec in specs {
            let id = spec.id == 1
                ? MarketingDemoRuntime.selectedBookmarkID
                : UUID(uuidString: String(format: "30000000-0000-4000-8000-%012d", spec.id))!
            let bookmark = Bookmark(
                id: id,
                url: spec.url,
                title: spec.title,
                details: spec.details,
                category: category,
                tags: spec.tags.compactMap { tags[$0] },
                isFavorite: spec.favorite,
                readingStatus: spec.read ? .done : .inbox,
                platform: spec.platform,
                contentType: spec.type,
                order: spec.id
            )
            bookmark.imageURL = spec.image
            bookmark.siteName = URL(string: spec.url)?.host?.replacingOccurrences(of: "www.", with: "")
            bookmark.summary = spec.details
            bookmark.semanticTags = spec.tags.compactMap { tags[$0]?.name }
            bookmark.createdAt = Calendar.current.date(byAdding: .day, value: -spec.id, to: now) ?? now
            bookmark.updatedAt = Calendar.current.date(byAdding: .hour, value: -(spec.id % 23), to: now) ?? now
            bookmark.lastCheckedAt = now
            bookmark.healthStatus = .ok
            bookmark.isRead = spec.read
            if spec.id.isMultiple(of: 7) { bookmark.reminderAt = now.addingTimeInterval(172_800) }
            if spec.id.isMultiple(of: 6) { bookmark.reviewAt = now.addingTimeInterval(-3_600) }
            if let stars = spec.stars {
                bookmark.repoInfo = RepoInfo(
                    stars: stars,
                    forks: spec.forks,
                    language: spec.language,
                    ownerAvatarURL: nil,
                    lastPush: now.addingTimeInterval(-86_400)
                )
            }
            linksByID[spec.id] = bookmark
            context.insert(bookmark)
        }
    }

    private func seedSessions() {
        insertSession(
            name: "Diseño semanal", icon: "paintpalette.fill", color: "#EC4899",
            order: 0, linkIDs: [9, 10, 11, 12, 13]
        )
        insertSession(
            name: "Build de Stacklume", icon: "hammer.fill", color: "#D4A853",
            order: 1, linkIDs: [1, 2, 3, 4, 5, 8]
        )
        insertSession(
            name: "IA local", icon: "sparkles", color: "#22C55E",
            order: 2, linkIDs: [29, 30, 31]
        )
        insertSession(
            name: "Lecturas del viernes", icon: "cup.and.saucer.fill", color: "#60A5FA",
            order: 3, linkIDs: [22, 23, 24, 25, 26]
        )
    }

    private func insertSession(
        name: String,
        icon: String,
        color: String,
        order: Int,
        linkIDs: [Int]
    ) {
        let session = LinkSession(name: name, icon: icon, colorHex: color, order: order)
        context.insert(session)
        for id in linkIDs {
            if let bookmark = linksByID[id] {
                session.links.append(bookmark)
            }
        }
    }

    private func seedRules() {
        guard let swift = categories["swift"], let ai = categories["ai"],
              let design = tags["design"], let read = tags["read"], let apple = tags["apple"]
        else { return }
        let rules = [
            ClassificationRule(name: "Repositorios Swift", conditionType: .domain,
                               conditionValue: "github.com", actionType: .setCategory,
                               actionValue: swift.id.uuidString, order: 0),
            ClassificationRule(name: "Diseño y prototipos", conditionType: .titleKeyword,
                               conditionValue: "design", actionType: .addTag,
                               actionValue: design.id.uuidString, order: 1),
            ClassificationRule(name: "Lecturas pendientes", conditionType: .titleKeyword,
                               conditionValue: "guide", actionType: .addTag,
                               actionValue: read.id.uuidString, order: 2),
            ClassificationRule(name: "Modelos locales", conditionType: .urlPattern,
                               conditionValue: "mlx", actionType: .setCategory,
                               actionValue: ai.id.uuidString, order: 3),
            ClassificationRule(name: "Recursos Apple", conditionType: .domain,
                               conditionValue: "developer.apple.com", actionType: .addTag,
                               actionValue: apple.id.uuidString, order: 4)
        ]
        rules[2].isActive = false
        rules.forEach(context.insert)
    }

    private func seedProject() {
        context.insert(Project(
            name: "Stacklume 2.0", icon: "macbook.and.iphone",
            colorHex: "#D4A853", order: 0, isDefault: true
        ))
    }

    private func seedAssistantConversation() {
        guard let url = AssistantConversationStore.defaultURL() else { return }
        let references = [
            AssistantLinkReference(
                title: "Human Interface Guidelines",
                url: "https://developer.apple.com/design/human-interface-guidelines/",
                summary: "Principios oficiales de diseño para las plataformas Apple.",
                collection: "Swift & Apple", tags: ["SwiftUI", "Interfaz"], origin: .library),
            AssistantLinkReference(
                title: "SwiftUI Layout: composición y alineación",
                url: "https://developer.apple.com/documentation/swiftui/layout",
                summary: "Documentación para construir interfaces adaptativas.",
                collection: "Swift & Apple", tags: ["SwiftUI"], origin: .library),
            AssistantLinkReference(
                title: "Microinteracciones con intención",
                url: "https://m3.material.io/foundations/interaction",
                summary: "Estados, feedback y movimiento al servicio de la comprensión.",
                collection: "Diseño de producto", tags: ["Interfaz", "Por leer"], origin: .library)
        ]
        let session = AssistantStoredSession(
            id: UUID(uuidString: "40000000-0000-4000-8000-000000000001")!,
            title: "Ruta de diseño para Stacklume",
            createdAt: Date().addingTimeInterval(-3_600),
            updatedAt: Date(),
            messages: [
                AssistantStoredMessage(
                    isUser: true,
                    text: "Reúne mis referencias sobre SwiftUI y diseño de producto. ¿Qué debería leer primero?"),
                AssistantStoredMessage(
                    isUser: false,
                    text: """
                    He encontrado 14 referencias relacionadas y las he ordenado por utilidad práctica.

                    ## Ruta recomendada
                    1. Empieza por las Human Interface Guidelines para fijar jerarquía, materiales y comportamiento nativo.
                    2. Continúa con SwiftUI Layout para convertir esos principios en una composición adaptable.
                    3. Cierra con microinteracciones: movimiento breve, feedback inmediato y siempre con una función clara.

                    ## Lo que ya está organizado
                    - 8 enlaces en «Swift & Apple».
                    - 6 referencias en «Diseño de producto».
                    - Las etiquetas «SwiftUI», «Interfaz» y «Por leer» conectan ambos temas.

                    Todo el análisis se ha hecho de forma local y tu biblioteca permanece en este Mac.
                    """,
                    references: references),
                AssistantStoredMessage(
                    isUser: true,
                    text: "Perfecto. Déjame una sesión corta para revisarlo el viernes."),
                AssistantStoredMessage(
                    isUser: false,
                    text: "He preparado una ruta de cinco lecturas, de fundamentos a implementación. La sesión «Lecturas del viernes» ya está lista y conserva el orden recomendado.")
            ]
        )
        _ = AssistantConversationStore.save([session], to: url)
    }

    private static let swiftSpecs: [MarketingBookmarkSpec] = [
        .init(id: 1, title: "Swift: el lenguaje para crear en todas las plataformas Apple", url: "https://github.com/swiftlang/swift", details: "Lenguaje seguro, expresivo y de alto rendimiento, con metadatos y organización local.", tags: ["swift", "open", "apple"], platform: .github, type: .code, image: "https://opengraph.githubassets.com/stacklume/swiftlang/swift", favorite: true, stars: 69_800, forks: 10_400, language: "C++"),
        .init(id: 2, title: "Human Interface Guidelines", url: "https://developer.apple.com/design/human-interface-guidelines/", details: "Principios oficiales para crear experiencias coherentes en las plataformas Apple.", tags: ["swift", "design", "apple"], type: .design, image: "https://developer.apple.com/news/images/og/apple-developer-og.png", favorite: true),
        .init(id: 3, title: "The Composable Architecture", url: "https://github.com/pointfreeco/swift-composable-architecture", details: "Arquitectura Swift con composición, efectos controlados y herramientas de test.", tags: ["swift", "open"], platform: .github, type: .code, image: "https://opengraph.githubassets.com/stacklume/pointfreeco/swift-composable-architecture", stars: 13_800, forks: 1_600, language: "Swift"),
        .init(id: 4, title: "SwiftUI Layout: composición y alineación", url: "https://developer.apple.com/documentation/swiftui/layout", details: "Documentación para construir interfaces adaptativas con el sistema de layout de SwiftUI.", tags: ["swift", "design"], type: .document, image: "https://developer.apple.com/news/images/og/apple-developer-og.png"),
        .init(id: 5, title: "MLX Swift", url: "https://github.com/ml-explore/mlx-swift", details: "Arrays, transformaciones y modelos eficientes sobre Apple silicon con una API nativa.", tags: ["swift", "local", "apple", "open"], platform: .github, type: .code, image: "https://opengraph.githubassets.com/stacklume/ml-explore/mlx-swift", favorite: true, stars: 2_900, forks: 320, language: "Swift"),
        .init(id: 6, title: "Swift Algorithms", url: "https://github.com/apple/swift-algorithms", details: "Colección abierta de algoritmos de secuencia listos para proyectos Swift.", tags: ["swift", "performance", "open"], platform: .github, type: .code, image: "https://opengraph.githubassets.com/stacklume/apple/swift-algorithms", read: true, stars: 6_200, forks: 560, language: "Swift"),
        .init(id: 7, title: "Swift Collections", url: "https://github.com/apple/swift-collections", details: "Estructuras de datos de alto rendimiento mantenidas por el proyecto Swift.", tags: ["swift", "performance", "open"], platform: .github, type: .code, image: "https://opengraph.githubassets.com/stacklume/apple/swift-collections", stars: 4_200, forks: 340, language: "Swift"),
        .init(id: 8, title: "Swift Testing", url: "https://github.com/swiftlang/swift-testing", details: "Framework moderno de pruebas con macros, traits y ejecución paralela.", tags: ["swift", "open"], platform: .github, type: .code, image: "https://opengraph.githubassets.com/stacklume/swiftlang/swift-testing", read: true, stars: 3_900, forks: 390, language: "Swift")
    ]

    private static let designSpecs: [MarketingBookmarkSpec] = [
        .init(id: 9, title: "Diseñar interfaces con Liquid Glass", url: "https://developer.apple.com/design/human-interface-guidelines/materials", details: "Cómo usar materiales, profundidad y jerarquía sin sacrificar legibilidad.", tags: ["design", "research"], type: .design, image: "https://images.unsplash.com/photo-1552664730-d307ca884978?auto=format&fit=crop&w=1600&q=90", favorite: true),
        .init(id: 10, title: "Sistemas de diseño que escalan", url: "https://designsystemsrepo.com/", details: "Patrones para mantener componentes y decisiones visuales coherentes.", tags: ["design", "read"], type: .design, image: "https://images.unsplash.com/photo-1497366811353-6870744d04b2?auto=format&fit=crop&w=1600&q=90"),
        .init(id: 11, title: "Microinteracciones con intención", url: "https://m3.material.io/foundations/interaction", details: "Estados, feedback y movimiento al servicio de la comprensión.", tags: ["design", "research"], type: .design, image: "https://images.unsplash.com/photo-1518005020951-eccb494ad742?auto=format&fit=crop&w=1600&q=90"),
        .init(id: 12, title: "Diseño para interfaces densas", url: "https://www.nngroup.com/articles/complex-application-design/", details: "Principios para herramientas profesionales con mucha información.", tags: ["design", "read"], type: .design, image: "https://images.unsplash.com/photo-1558655146-d09347e92766?auto=format&fit=crop&w=1600&q=90"),
        .init(id: 13, title: "A11y Project Checklist", url: "https://www.a11yproject.com/checklist/", details: "Lista práctica para revisar accesibilidad desde estructura hasta interacción.", tags: ["design", "research"], type: .design, image: "https://images.unsplash.com/photo-1545235617-9465d2a55698?auto=format&fit=crop&w=1600&q=90"),
        .init(id: 14, title: "Design Tokens Community Group", url: "https://www.w3.org/community/design-tokens/", details: "Especificación y conversaciones sobre tokens interoperables.", tags: ["design", "read"], type: .design, image: "https://images.unsplash.com/photo-1519389950473-47ba0277781c?auto=format&fit=crop&w=1600&q=90")
    ]

    private static let inspirationSpecs: [MarketingBookmarkSpec] = [
        .init(id: 15, title: "Materia y luz", url: "https://unsplash.com/s/photos/material-light", details: "Texturas minerales y reflejos para estudiar profundidad.", tags: ["design"], type: .design, image: "https://images.unsplash.com/photo-1500530855697-b586d89ba3ee?auto=format&fit=crop&w=1600&q=90"),
        .init(id: 16, title: "Arquitectura silenciosa", url: "https://unsplash.com/s/photos/minimal-architecture", details: "Volúmenes, vacío y escala con una paleta contenida.", tags: ["design"], type: .design, image: "https://images.unsplash.com/photo-1518005020951-eccb494ad742?auto=format&fit=crop&w=1600&q=90", favorite: true),
        .init(id: 17, title: "Azul nocturno", url: "https://unsplash.com/s/photos/blue-night", details: "Contraste entre superficies navy y puntos de luz cálida.", tags: ["design"], type: .design, image: "https://images.unsplash.com/photo-1500534314209-a25ddb2bd429?auto=format&fit=crop&w=1600&q=90"),
        .init(id: 18, title: "Geometría editorial", url: "https://unsplash.com/s/photos/editorial-design", details: "Ritmo, columnas y tipografía como estructura visual.", tags: ["design"], type: .design, image: "https://images.unsplash.com/photo-1497366754035-f200968a6e72?auto=format&fit=crop&w=1600&q=90"),
        .init(id: 19, title: "Paisajes de niebla", url: "https://unsplash.com/s/photos/misty-landscape", details: "Capas atmosféricas para separar planos sin líneas duras.", tags: ["design"], type: .design, image: "https://images.unsplash.com/photo-1500534623283-312aade485b7?auto=format&fit=crop&w=1600&q=90"),
        .init(id: 20, title: "Objetos en equilibrio", url: "https://unsplash.com/s/photos/still-life", details: "Composición, tensión y espacio negativo.", tags: ["design"], type: .design, image: "https://images.unsplash.com/photo-1494438639946-1ebd1d20bf85?auto=format&fit=crop&w=1600&q=90"),
        .init(id: 21, title: "Luz sobre vidrio", url: "https://unsplash.com/s/photos/glass-light", details: "Refracción y color para detalles de interfaz.", tags: ["design"], type: .design, image: "https://images.unsplash.com/photo-1486406146926-c627a92ad1ab?auto=format&fit=crop&w=1600&q=90")
    ]

    private static let readingSpecs: [MarketingBookmarkSpec] = [
        .init(id: 22, title: "Designing for understanding", url: "https://www.nngroup.com/articles/ten-usability-heuristics/", details: "Diez heurísticas para revisar cualquier producto digital.", tags: ["read", "research"], type: .article),
        .init(id: 23, title: "Swift concurrency: guía de migración", url: "https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/", details: "Cómo adoptar aislamiento y Sendable de forma gradual y verificable.", tags: ["read", "design"], type: .article),
        .init(id: 24, title: "Local-first software", url: "https://www.inkandswitch.com/local-first/", details: "Siete ideales para aplicaciones que priorizan propiedad, velocidad y trabajo sin conexión.", tags: ["read", "research"], type: .article, read: true),
        .init(id: 25, title: "The craft of product engineering", url: "https://martinfowler.com/articles/products-over-projects.html", details: "Organización del trabajo alrededor de productos duraderos.", tags: ["read", "design"], type: .article),
        .init(id: 26, title: "Optimizing SwiftUI performance", url: "https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance", details: "Herramientas para localizar actualizaciones innecesarias y mantener una interfaz fluida.", tags: ["read", "research", "swift"], type: .article),
        .init(id: 27, title: "A philosophy of software design", url: "https://web.stanford.edu/~ouster/cgi-bin/book.php", details: "Ideas para reducir complejidad y diseñar módulos profundos.", tags: ["read", "design"], type: .article),
        .init(id: 28, title: "Building accessible interactions", url: "https://www.w3.org/WAI/ARIA/apg/", details: "Patrones accesibles con ejemplos y comportamiento de teclado.", tags: ["read", "research"], type: .article, read: true)
    ]

    private static let aiSpecs: [MarketingBookmarkSpec] = [
        .init(id: 29, title: "MLX", url: "https://github.com/ml-explore/mlx", details: "Framework de arrays y aprendizaje automático optimizado para Apple silicon.", tags: ["local", "apple", "open"], platform: .github, type: .code, image: "https://opengraph.githubassets.com/stacklume/ml-explore/mlx", favorite: true, stars: 22_000, forks: 1_300, language: "C++"),
        .init(id: 30, title: "Swift Transformers", url: "https://github.com/huggingface/swift-transformers", details: "Componentes Swift para ejecutar modelos Transformer y tokenizadores de forma nativa.", tags: ["local", "swift", "open"], platform: .github, type: .code, image: "https://opengraph.githubassets.com/stacklume/huggingface/swift-transformers", stars: 1_700, forks: 160, language: "Swift"),
        .init(id: 31, title: "llama.cpp", url: "https://github.com/ggml-org/llama.cpp", details: "Inferencia eficiente y portable con múltiples backends.", tags: ["local", "performance", "open"], platform: .github, type: .code, image: "https://opengraph.githubassets.com/stacklume/ggml-org/llama.cpp", stars: 83_000, forks: 12_000, language: "C++")
    ]

    private static let toolSpecs: [MarketingBookmarkSpec] = [
        .init(id: 32, title: "Raycast", url: "https://www.raycast.com/", details: "Lanzador extensible para automatizar tareas cotidianas en macOS.", tags: ["apple"], image: "https://www.raycast.com/_next/image?url=%2Fimages%2Ftwitter-card.png&w=3840&q=90"),
        .init(id: 33, title: "Ice", url: "https://github.com/jordanbaird/Ice", details: "Gestor abierto de iconos de la barra de menús para macOS.", tags: ["swift", "open"], platform: .github, type: .code, image: "https://opengraph.githubassets.com/stacklume/jordanbaird/Ice", stars: 22_000, forks: 430, language: "Swift"),
        .init(id: 34, title: "Xcodes", url: "https://github.com/XcodesOrg/xcodes", details: "Instala y administra versiones de Xcode desde la línea de comandos.", tags: ["swift", "open"], platform: .github, type: .code, image: "https://opengraph.githubassets.com/stacklume/XcodesOrg/xcodes", read: true, stars: 4_200, forks: 330, language: "Swift")
    ]
}
