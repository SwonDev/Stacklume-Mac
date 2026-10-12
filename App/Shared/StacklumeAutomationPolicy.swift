import Foundation

/// Capacidades externas que el usuario puede conceder o revocar de forma independiente.
/// «Capturar» solo añade enlaces; «consultar» entrega metadatos a Atajos; «organizar»
/// permite mutaciones no destructivas sobre enlaces ya existentes.
enum StacklumeAutomationCapability: String, Codable, CaseIterable, Sendable {
    case capture
    case read
    case organize
}

/// Acciones controladas que pueden aparecer en el registro local. Es un enum deliberadamente
/// cerrado: nunca se persisten consultas, títulos, URLs ni otros parámetros externos.
enum StacklumeAutomationAction: String, Codable, Sendable {
    case captureOne
    case captureBatch
    case search
    case getBookmarks
    case openRandom
    case openUnread
    case openBookmark
    case changeState
    case moveToCollection
    case editTags
}

enum StacklumeAutomationAuditOutcome: String, Codable, Sendable {
    case completed
    case blocked
}

/// Evento mínimo de auditoría. No contiene payload de la biblioteca ni texto introducido
/// en Atajos, por lo que el propio registro no se convierte en otra fuente de exposición.
struct StacklumeAutomationAuditEvent: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let capability: StacklumeAutomationCapability
    let action: StacklumeAutomationAction
    let outcome: StacklumeAutomationAuditOutcome
    let itemCount: Int
}

/// Consentimiento local para App Intents. Todas las capacidades externas parten denegadas
/// y requieren un opt-in explícito dentro de Stacklume.
enum StacklumeAutomationAccess {
    static let captureEnabledKey = "stacklume.automation.captureEnabled"
    static let readEnabledKey = "stacklume.automation.readEnabled"
    static let organizeEnabledKey = "stacklume.automation.organizeEnabled"

    static func isAllowed(
        _ capability: StacklumeAutomationCapability,
        defaults: UserDefaults = .standard
    ) -> Bool {
        switch capability {
        case .capture:
            value(forKey: captureEnabledKey, default: false, defaults: defaults)
        case .read:
            value(forKey: readEnabledKey, default: false, defaults: defaults)
        case .organize:
            value(forKey: readEnabledKey, default: false, defaults: defaults)
                && value(forKey: organizeEnabledKey, default: false, defaults: defaults)
        }
    }

    private static func value(
        forKey key: String,
        default defaultValue: Bool,
        defaults: UserDefaults
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}

/// Registro de actividad local y acotado. Todas las escrituras se realizan en el
/// `MainActor`, igual que los `perform()` que acceden a SwiftData.
@MainActor
enum StacklumeAutomationAuditLog {
    static let storageKey = "stacklume.automation.audit.v1"
    static let revisionKey = "stacklume.automation.auditRevision"
    static let maximumEventCount = 100

    static func record(
        capability: StacklumeAutomationCapability,
        action: StacklumeAutomationAction,
        outcome: StacklumeAutomationAuditOutcome,
        itemCount: Int,
        date: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        var stored = decodedEvents(defaults: defaults)
        stored.append(StacklumeAutomationAuditEvent(
            id: UUID(),
            date: date,
            capability: capability,
            action: action,
            outcome: outcome,
            itemCount: min(max(itemCount, 0), 100_000)
        ))
        if stored.count > maximumEventCount {
            stored.removeFirst(stored.count - maximumEventCount)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: storageKey)
        defaults.set(defaults.integer(forKey: revisionKey) &+ 1, forKey: revisionKey)
    }

    /// Devuelve primero lo más reciente para que la UI no tenga que reordenar.
    static func events(defaults: UserDefaults = .standard) -> [StacklumeAutomationAuditEvent] {
        decodedEvents(defaults: defaults).reversed()
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
        defaults.set(defaults.integer(forKey: revisionKey) &+ 1, forKey: revisionKey)
    }

    private static func decodedEvents(defaults: UserDefaults) -> [StacklumeAutomationAuditEvent] {
        guard let data = defaults.data(forKey: storageKey),
              let events = try? JSONDecoder().decode([StacklumeAutomationAuditEvent].self, from: data)
        else { return [] }
        return Array(events.suffix(maximumEventCount))
    }
}

/// Visibilidad de la biblioteca en el índice local del sistema. Los enlaces siguen siendo
/// descubribles por metadatos por defecto, pero notas y texto de documentos requieren opt-in.
enum StacklumeSpotlightPolicy {
    static let enabledKey = "stacklume.spotlight.enabled"
    static let privateContentEnabledKey = "stacklume.spotlight.privateContentEnabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else { return true }
        return defaults.bool(forKey: enabledKey)
    }

    static func includesPrivateContent(defaults: UserDefaults = .standard) -> Bool {
        isEnabled(defaults: defaults)
            && defaults.bool(forKey: privateContentEnabledKey)
    }

    /// Forma parte de la firma del índice: cualquier cambio de privacidad fuerza una
    /// reconstrucción que también elimina atributos sensibles indexados por versiones previas.
    static func signatureFragment(defaults: UserDefaults = .standard) -> String {
        "\(isEnabled(defaults: defaults) ? 1 : 0)-\(includesPrivateContent(defaults: defaults) ? 1 : 0)"
    }
}

/// Claves puras de los filtros que la capa App Intents presenta al sistema.
/// Se mantienen fuera de AppIntents/SwiftData para poder probar todos los bordes sin
/// compilar la aplicación ni el modelo de IA.
enum StacklumeAutomationFilterKey: String, Sendable {
    case all
    case favorites
    case unread
    case readingQueue
    case archived
    case broken
    case dueForReview
}

/// Política de seguridad y selección compartida por las automatizaciones de Stacklume.
enum StacklumeAutomationPolicy {
    static let suggestedEntityCount = 40
    static let maximumResultCount = 100
    static let maximumMutationCount = 500
    static let maximumTagCountPerAction = 50
    static let maximumQueryLength = 500
    static let maximumStoredURLLength = 16_384

    /// Normaliza y acota una consulta antes de entregarla al parser de búsqueda.
    static func sanitizedQuery(_ value: String?) -> String {
        guard let value else { return "" }
        return String(value.prefix(maximumQueryLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nunca deja que un parámetro externo solicite 0, un valor negativo o más de 100.
    static func resultLimit(_ requested: Int) -> Int {
        min(max(requested, 1), maximumResultCount)
    }

    static func allowsMutationCount(_ count: Int) -> Bool {
        count > 0 && count <= maximumMutationCount
    }

    static func allowsTagCount(_ count: Int) -> Bool {
        count > 0 && count <= maximumTagCountPerAction
    }

    /// Última frontera antes de abrir en el navegador una URL procedente del store.
    ///
    /// La ingesta ya limita los enlaces a HTTP(S), pero esta comprobación de defensa en
    /// profundidad protege bibliotecas antiguas, importaciones y backups manipulados: nunca
    /// entrega a Launch Services esquemas ejecutables (`javascript:`, `file:`, `data:`…),
    /// credenciales embebidas ni cadenas desmesuradas. A diferencia de las automatizaciones,
    /// aquí sí se permiten hosts locales porque el usuario puede guardar documentación de un
    /// servidor de desarrollo desde la propia interfaz.
    static func openableStoredURL(_ rawValue: String) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= maximumStoredURLLength,
              !containsControlAfterPercentDecoding(value),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              let url = components.url
        else { return nil }
        return url
    }

    /// Evita controles ocultos tanto en la cadena original como tras varias capas de
    /// percent-encoding (`%0A`, `%250A`), que pueden interpretarse de forma distinta al
    /// atravesar parsers, proxies o Launch Services.
    private static func containsControlAfterPercentDecoding(_ raw: String) -> Bool {
        var value = raw
        for _ in 0..<3 {
            if hasControlScalar(value) {
                return true
            }
            guard value.contains("%") else { return false }
            guard let decoded = value.removingPercentEncoding else { return true }
            if decoded == value { return false }
            value = decoded
        }
        return hasControlScalar(value)
    }

    private static func hasControlScalar(_ value: String) -> Bool {
        // Cc y Cf son las categorías de controlCharacters. La referencia enlazada al
        // método de CharacterSet produce falsos positivos en la app Release; el recorrido
        // explícito conserva la protección también para controles Unicode y bidireccionales.
        for scalar in value.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format: return true
            default: continue
            }
        }
        return false
    }

    /// Las capturas externas no pueden apuntar a servicios del propio Mac o de su red
    /// privada. La UI interna conserva soporte para servidores locales de desarrollo;
    /// esta restricción solo protege la frontera App Intents.
    static func allowsExternalCaptureURL(_ url: URL) -> Bool {
        guard openableStoredURL(url.absoluteString) != nil,
              var host = url.host?.lowercased(),
              !host.isEmpty
        else { return false }

        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return false }

        let forbiddenNames = ["localhost", "localhost.localdomain", "broadcasthost"]
        if forbiddenNames.contains(host) { return false }
        let forbiddenSuffixes = [
            ".localhost", ".local", ".internal", ".home", ".lan", ".arpa",
            ".localtest.me", ".lvh.me", ".nip.io", ".sslip.io",
        ]
        if forbiddenSuffixes.contains(where: { host.hasSuffix($0) }) { return false }
        let forbiddenPublicNames = ["localtest.me", "lvh.me", "nip.io", "sslip.io"]
        if forbiddenPublicNames.contains(host) { return false }

        // Se rechazan IPv6 literales en la frontera externa: cubre loopback, link-local,
        // unique-local e IPv4 mapeada sin depender de representaciones textuales alternativas.
        if host.contains(":") { return false }

        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        let allNumericLabels = !octets.isEmpty
            && octets.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        if octets.count == 4, allNumericLabels,
           let a = Int(octets[0]), let b = Int(octets[1]),
           let c = Int(octets[2]), let d = Int(octets[3]),
           [a, b, c, d].allSatisfy({ (0...255).contains($0) }) {
            // Evita notación octal ambigua (`0177.0.0.1`) aceptada por algunos resolvers.
            if octets.contains(where: { $0.count > 1 && $0.first == "0" }) { return false }
            if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
            if a == 100 && (64...127).contains(b) { return false }
            if a == 169 && b == 254 { return false }
            if a == 172 && (16...31).contains(b) { return false }
            if a == 192 && (b == 0 || b == 168) { return false }
            if a == 192 && b == 88 && c == 99 { return false }
            if a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100)) { return false }
            if a == 203 && b == 0 && c == 113 { return false }
            return true
        }

        // Formas abreviadas (`127.1`, `127.0.1`) y componentes hexadecimales pueden ser
        // interpretados como IPv4 por el resolver aunque no parezcan cuatro octetos decimales.
        if allNumericLabels || octets.contains(where: { $0.lowercased().hasPrefix("0x") }) {
            return false
        }

        // Nombres sin punto pueden resolverse mediante el dominio de búsqueda de una red
        // corporativa. Las notaciones numéricas alternativas también son ambiguas.
        if !host.contains(".") || host.allSatisfy(\.isNumber) {
            return false
        }
        return true
    }

    /// Las adquisiciones automáticas exigen HTTPS y un destino público.
    /// Los enlaces HTTP siguen pudiéndose guardar y abrir explícitamente.
    static func allowsAutomaticNetworkURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && allowsExternalCaptureURL(url)
            && FaviconPrivacyPolicy.allows(url)
    }

    /// Decide si un enlace satisface un filtro sin depender de SwiftData. Todo filtro salvo
    /// «Archivados» excluye los archivados para reproducir la semántica de la biblioteca.
    static func includes(
        _ filter: StacklumeAutomationFilterKey,
        isFavorite: Bool,
        isRead: Bool,
        isArchived: Bool,
        isReadingPending: Bool,
        isBroken: Bool,
        reviewAt: Date?,
        now: Date
    ) -> Bool {
        switch filter {
        case .all:
            !isArchived
        case .favorites:
            isFavorite && !isArchived
        case .unread:
            !isRead && !isArchived
        case .readingQueue:
            isReadingPending && !isArchived
        case .archived:
            isArchived
        case .broken:
            isBroken && !isArchived
        case .dueForReview:
            reviewAt.map { $0 <= now } == true && !isArchived
        }
    }
}

/// Los servicios de favicons reciben el dominio del enlace. El respaldo histórico
/// sigue activo salvo que el usuario lo desactive expresamente en Ajustes.
enum FaviconPrivacyPolicy {
    static let enabledKey = "stacklume.thirdPartyFaviconsEnabled"

    static func allows(_ url: URL, in defaults: UserDefaults = .standard) -> Bool {
        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()
        let provider = (["google.com", "www.google.com"].contains(host) && path.hasPrefix("/s2/favicons"))
            || (host == "icons.duckduckgo.com" && path.hasPrefix("/ip3/"))
            || (host.hasSuffix(".gstatic.com") && path.hasPrefix("/favicon"))
        return !provider || defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey)
    }
}
