import Foundation
import Testing

@Suite("Automatización — límites y filtros seguros")
struct StacklumeAutomationPolicyTests {
    @Test("El respaldo histórico de favicons respeta la desactivación explícita")
    func thirdPartyFaviconsRespectExplicitOptOut() throws {
        let suite = "StacklumeFaviconPrivacy-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let providers = ["https://www.google.com/s2/favicons?domain=example.org", "https://icons.duckduckgo.com/ip3/example.org.ico", "https://t0.gstatic.com/faviconV2?url=example.org"]
        for raw in providers { #expect(FaviconPrivacyPolicy.allows(try #require(URL(string: raw)), in: defaults)) }
        defaults.set(false, forKey: FaviconPrivacyPolicy.enabledKey)
        for raw in providers { #expect(!FaviconPrivacyPolicy.allows(try #require(URL(string: raw)), in: defaults)) }
        #expect(FaviconPrivacyPolicy.allows(try #require(URL(string: "https://example.org/favicon.ico")), in: defaults))
        #expect(FaviconPrivacyPolicy.allows(try #require(URL(string: "https://www.google.com/images/branding/googlelogo.png")), in: defaults))
        defaults.set(true, forKey: FaviconPrivacyPolicy.enabledKey)
        for raw in providers { #expect(FaviconPrivacyPolicy.allows(try #require(URL(string: raw)), in: defaults)) }
    }

    @Test("Solo abre URLs web almacenadas y conserva servidores locales")
    func validatesStoredURLsBeforeOpening() {
        let accepted = [
            "https://example.com/ruta?q=uno#seccion",
            "http://localhost:3000/documentacion",
            "http://192.168.1.20:8080/panel",
            "  https://ejemplo.es/área  ",
            "https://github.com/lightningpixel/modly",
            "https://opengraph.githubassets.com/1/lightningpixel/modly",
        ]
        for raw in accepted {
            #expect(StacklumeAutomationPolicy.openableStoredURL(raw) != nil)
        }

        let rejected = [
            "javascript:alert(1)",
            "file:///Users/persona/.ssh/id_ed25519",
            "data:text/html,peligro",
            "stacklume://open?id=00000000-0000-0000-0000-000000000000",
            "https://usuario:contraseña@example.com/privado",
            "https://example.com/\ninyectado",
            "https://example.com/%0Ainyectado",
            "https://example.com/%250Dinyectado",
            "https:///sin-host",
            "",
        ]
        for raw in rejected {
            #expect(StacklumeAutomationPolicy.openableStoredURL(raw) == nil)
        }

        let oversized = "https://example.com/" + String(repeating: "a", count: 20_000)
        #expect(StacklumeAutomationPolicy.openableStoredURL(oversized) == nil)
    }

    @Test("Rechaza controles Unicode y controles codificados sin bloquear ASCII público")
    func rejectsHiddenUnicodeControls() {
        let controls = ["\u{0}", "\r", "\n", "\u{7F}", "\u{85}", "\u{AD}", "\u{202E}", "\u{E0001}",
                        "%0A", "%250A", "%25250A"]
        for control in controls {
            #expect(StacklumeAutomationPolicy.openableStoredURL("https://example.com/" + control + "ruta") == nil)
        }
        #expect(StacklumeAutomationPolicy.allowsExternalCaptureURL(
            URL(string: "https://opengraph.githubassets.com/1/lightningpixel/modly")!
        ))
    }

    @Test("Acota consultas y conserva Unicode completo")
    func sanitizesQueries() {
        #expect(StacklumeAutomationPolicy.sanitizedQuery("  diseño y visión  ") == "diseño y visión")
        #expect(StacklumeAutomationPolicy.sanitizedQuery(nil).isEmpty)

        let oversized = String(repeating: "ñ", count: 700)
        #expect(StacklumeAutomationPolicy.sanitizedQuery(oversized).count == 500)
    }

    @Test("Acota el número de resultados")
    func boundsResultLimit() {
        #expect(StacklumeAutomationPolicy.resultLimit(-8) == 1)
        #expect(StacklumeAutomationPolicy.resultLimit(20) == 20)
        #expect(StacklumeAutomationPolicy.resultLimit(5_000) == 100)
    }

    @Test("Rechaza mutaciones y lotes de etiquetas desmesurados")
    func boundsMutations() {
        #expect(!StacklumeAutomationPolicy.allowsMutationCount(0))
        #expect(StacklumeAutomationPolicy.allowsMutationCount(500))
        #expect(!StacklumeAutomationPolicy.allowsMutationCount(501))
        #expect(StacklumeAutomationPolicy.allowsTagCount(50))
        #expect(!StacklumeAutomationPolicy.allowsTagCount(51))
    }

    @Test("La captura externa solo admite destinos públicos")
    func rejectsPrivateExternalTargets() {
        let allowed = [
            "https://stacklume.app/guía",
            "https://example.com",
            "https://1.1.1.1/dns-query",
        ]
        for raw in allowed {
            #expect(StacklumeAutomationPolicy.allowsExternalCaptureURL(URL(string: raw)!))
        }

        let rejected = [
            "http://localhost:8080",
            "http://servidor.local",
            "http://intranet",
            "http://127.0.0.1",
            "http://10.0.0.8",
            "http://100.64.0.1",
            "http://169.254.169.254/latest/meta-data",
            "http://172.16.0.1",
            "http://192.168.1.1",
            "http://127.1",
            "http://127.0.1",
            "http://0177.0.0.1",
            "http://127.0.0.1.nip.io",
            "http://localtest.me",
            "http://[::1]",
            "http://2130706433",
            "https://usuario:secreto@example.com",
        ]
        for raw in rejected {
            #expect(!StacklumeAutomationPolicy.allowsExternalCaptureURL(URL(string: raw)!))
        }
    }

    @Test("La red automática exige TLS además de un host público")
    func requiresTLSForAutomaticNetworkAccess() {
        #expect(StacklumeAutomationPolicy.allowsAutomaticNetworkURL(
            URL(string: "https://example.com/feed")!
        ))
        #expect(!StacklumeAutomationPolicy.allowsAutomaticNetworkURL(
            URL(string: "http://example.com/feed")!
        ))
        #expect(!StacklumeAutomationPolicy.allowsAutomaticNetworkURL(
            URL(string: "https://127.0.0.1/feed")!
        ))
    }

    @Test("Aplica mínimo privilegio y exige lectura antes de organizar")
    func appliesLeastPrivilegeDefaults() {
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }

        #expect(!StacklumeAutomationAccess.isAllowed(.capture, defaults: defaults))
        #expect(!StacklumeAutomationAccess.isAllowed(.read, defaults: defaults))
        #expect(!StacklumeAutomationAccess.isAllowed(.organize, defaults: defaults))

        defaults.set(true, forKey: StacklumeAutomationAccess.organizeEnabledKey)
        #expect(!StacklumeAutomationAccess.isAllowed(.organize, defaults: defaults))

        defaults.set(true, forKey: StacklumeAutomationAccess.readEnabledKey)
        #expect(StacklumeAutomationAccess.isAllowed(.organize, defaults: defaults))

        defaults.set(true, forKey: StacklumeAutomationAccess.captureEnabledKey)
        #expect(StacklumeAutomationAccess.isAllowed(.capture, defaults: defaults))
    }

    @Test("Spotlight usa solo metadatos por defecto")
    func appliesSpotlightPrivacyDefaults() {
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }

        #expect(StacklumeSpotlightPolicy.isEnabled(defaults: defaults))
        #expect(!StacklumeSpotlightPolicy.includesPrivateContent(defaults: defaults))
        #expect(StacklumeSpotlightPolicy.signatureFragment(defaults: defaults) == "1-0")

        defaults.set(true, forKey: StacklumeSpotlightPolicy.privateContentEnabledKey)
        #expect(StacklumeSpotlightPolicy.includesPrivateContent(defaults: defaults))
        #expect(StacklumeSpotlightPolicy.signatureFragment(defaults: defaults) == "1-1")

        defaults.set(false, forKey: StacklumeSpotlightPolicy.enabledKey)
        #expect(!StacklumeSpotlightPolicy.includesPrivateContent(defaults: defaults))
        #expect(StacklumeSpotlightPolicy.signatureFragment(defaults: defaults) == "0-0")
    }

    @Test("El registro es acotado y no admite payload libre")
    @MainActor
    func boundsAuditLog() {
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        for index in 0..<125 {
            StacklumeAutomationAuditLog.record(
                capability: .read,
                action: .search,
                outcome: .completed,
                itemCount: index,
                date: Date(timeIntervalSince1970: TimeInterval(index)),
                defaults: defaults
            )
        }

        let events = StacklumeAutomationAuditLog.events(defaults: defaults)
        #expect(events.count == StacklumeAutomationAuditLog.maximumEventCount)
        #expect(events.first?.itemCount == 124)
        #expect(events.last?.itemCount == 25)

        StacklumeAutomationAuditLog.clear(defaults: defaults)
        #expect(StacklumeAutomationAuditLog.events(defaults: defaults).isEmpty)
    }

    @Test("Todos los filtros normales excluyen archivados")
    func excludesArchivedFromNormalFilters() {
        let now = Date()
        for filter in [StacklumeAutomationFilterKey.all, .favorites, .unread,
                       .readingQueue, .broken, .dueForReview] {
            #expect(!StacklumeAutomationPolicy.includes(
                filter,
                isFavorite: true,
                isRead: false,
                isArchived: true,
                isReadingPending: true,
                isBroken: true,
                reviewAt: now,
                now: now
            ))
        }
        #expect(StacklumeAutomationPolicy.includes(
            .archived,
            isFavorite: false,
            isRead: true,
            isArchived: true,
            isReadingPending: false,
            isBroken: false,
            reviewAt: nil,
            now: now
        ))
    }

    @Test("El repaso solo incluye fechas vencidas o actuales")
    func filtersReviewDates() {
        let now = Date(timeIntervalSince1970: 10_000)
        let base = (
            isFavorite: false,
            isRead: false,
            isArchived: false,
            isReadingPending: true,
            isBroken: false
        )
        #expect(StacklumeAutomationPolicy.includes(
            .dueForReview,
            isFavorite: base.isFavorite,
            isRead: base.isRead,
            isArchived: base.isArchived,
            isReadingPending: base.isReadingPending,
            isBroken: base.isBroken,
            reviewAt: now,
            now: now
        ))
        #expect(!StacklumeAutomationPolicy.includes(
            .dueForReview,
            isFavorite: base.isFavorite,
            isRead: base.isRead,
            isArchived: base.isArchived,
            isReadingPending: base.isReadingPending,
            isBroken: base.isBroken,
            reviewAt: now.addingTimeInterval(1),
            now: now
        ))
        #expect(!StacklumeAutomationPolicy.includes(
            .dueForReview,
            isFavorite: base.isFavorite,
            isRead: base.isRead,
            isArchived: base.isArchived,
            isReadingPending: base.isReadingPending,
            isBroken: base.isBroken,
            reviewAt: nil,
            now: now
        ))
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let name = "StacklumeAutomationPolicyTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }
}
