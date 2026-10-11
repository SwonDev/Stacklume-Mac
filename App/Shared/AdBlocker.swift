import Foundation
import WebKit

/// Bloqueador de anuncios y rastreadores para el navegador interno (WKWebView), al estilo
/// de los «escudos» de Brave. Compila un `WKContentRuleList` (el mismo motor que usan los
/// bloqueadores de contenido de Safari) a partir de las LISTAS DE FILTROS reales que usan
/// uBlock Origin / Brave (EasyList + EasyPrivacy): se descargan una vez, se convierten al
/// formato de WebKit y WebKit deja la lista compilada PERSISTIDA en disco (no se vuelve a
/// descargar). Si no hay red en el primer arranque, cae a una lista curada embebida.
///
/// La conversión es conservadora: convierte las reglas de red de dominio (`||dominio^`,
/// con sus opciones `third-party`/tipo de recurso) y las excepciones (`@@||dominio^`), que
/// son las que más pesan en el bloqueo, y omite las reglas con regex/opciones complejas
/// para no invalidar la compilación entera. El filtro cosmético usa un set curado seguro.
@MainActor
final class AdBlocker {
    static let shared = AdBlocker()
    private init() {}

    /// Lista compilada y cacheada en memoria.
    private var compiled: WKContentRuleList?
    /// Compilación/descarga en curso, para no duplicarla si varias vistas la piden a la vez.
    private var inFlight: Task<WKContentRuleList?, Never>?

    /// Devuelve la lista de reglas compilada (o `nil` si WebKit no puede compilarla).
    func ruleList() async -> WKContentRuleList? {
        if let compiled { return compiled }
        if let inFlight { return await inFlight.value }
        let task = Task { await self.build() }
        inFlight = task
        let result = await task.value
        compiled = result
        inFlight = nil
        return result
    }

    /// Fuerza descargar las listas de nuevo y recompilar (para un botón «actualizar»).
    @discardableResult
    func refresh() async -> WKContentRuleList? {
        compiled = nil
        if let store = WKContentRuleListStore.default() {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                store.removeContentRuleList(forIdentifier: Self.identifier) { _ in cont.resume() }
            }
        }
        return await ruleList()
    }

    /// Busca una lista compilada ya persistida (envuelve la API de completion handler).
    private func lookUp(_ store: WKContentRuleListStore, _ id: String) async -> WKContentRuleList? {
        await withCheckedContinuation { cont in
            store.lookUpContentRuleList(forIdentifier: id) { list, _ in cont.resume(returning: list) }
        }
    }

    // MARK: - Construcción

    /// Identificador de la lista grande (descargada). Súbelo si cambia la conversión.
    private static let identifier = "stacklume-adblock-easylist-v4"
    /// Identificador de la lista de respaldo embebida.
    private static let fallbackIdentifier = "stacklume-adblock-fallback-v2"
    /// Tope prudente de reglas para no exceder el límite del compilador de WebKit
    /// (macOS moderno admite >100k; 50k cubre ads + trackers de sobra).
    nonisolated private static let maxRules = 75_000

    /// Listas de filtros base (las que usan uBlock Origin y Brave por defecto). EasyPrivacy
    /// (rastreadores) va PRIMERO: es lo que más pesa en los tests de bloqueo y así nunca lo
    /// recorta el tope de reglas.
    nonisolated private static let filterListURLs = [
        "https://easylist.to/easylist/easyprivacy.txt",
        "https://easylist.to/easylist/easylist.txt",
    ]

    private func build() async -> WKContentRuleList? {
        guard let store = WKContentRuleListStore.default() else { return nil }
        // 1) Reutiliza la lista grande ya compilada y persistida por WebKit.
        if let existing = await lookUp(store, Self.identifier) {
            UserDefaults.standard.set("cached", forKey: "stacklume.adblock.status")
            return existing
        }
        // 2) Descarga y convierte las listas reales; compílalas (WebKit las persiste).
        if let json = await Self.downloadAndConvert() {
            do {
                if let list = try await store.compileContentRuleList(
                    forIdentifier: Self.identifier, encodedContentRuleList: json) {
                    UserDefaults.standard.set("easylist", forKey: "stacklume.adblock.status")
                    return list
                }
            } catch {
                UserDefaults.standard.set("compile-error: \(error.localizedDescription)", forKey: "stacklume.adblock.status")
            }
        } else {
            UserDefaults.standard.set("download-failed", forKey: "stacklume.adblock.status")
        }
        // 3) Sin red o si falla: lista curada embebida (no contamina el id principal, así
        //    el próximo arranque reintenta la descarga completa).
        let existingStatus = UserDefaults.standard.string(forKey: "stacklume.adblock.status") ?? ""
        if existingStatus.isEmpty { UserDefaults.standard.set("fallback", forKey: "stacklume.adblock.status") }
        return (try? await store.compileContentRuleList(
            forIdentifier: Self.fallbackIdentifier, encodedContentRuleList: Self.fallbackJSON())) ?? nil
    }

    /// Descarga las listas y las convierte a JSON de reglas de WebKit, FUERA del hilo
    /// principal (la descarga y el parseo de decenas de miles de líneas son pesados).
    private static func downloadAndConvert() async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            var blocks: [[String: Any]] = []
            var exceptions: [[String: Any]] = []
            var seen = Set<String>()
            for urlString in filterListURLs {
                guard let url = URL(string: urlString),
                      let result = try? await ExternalHTTPClient.shared.data(
                          for: URLRequest(url: url),
                          maximumBytes: 16 * 1_024 * 1_024,
                          allowedMIMEPrefixes: ["text/plain"]
                      ),
                      let text = String(data: result.data, encoding: .utf8) else { continue }
                for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard let rule = parseNetworkRule(String(rawLine)) else { continue }
                    // dedup por url-filter para no repetir entre listas.
                    guard let trig = rule.dict["trigger"] as? [String: Any],
                          let filter = trig["url-filter"] as? String,
                          seen.insert(filter + (rule.isException ? "@" : "")).inserted else { continue }
                    if rule.isException { exceptions.append(rule.dict) } else { blocks.append(rule.dict) }
                    if blocks.count >= maxRules { break }
                }
                if blocks.count >= maxRules { break }
            }
            guard blocks.count > 100 else { return nil }   // descarga insuficiente
            // Orden: primero bloqueos, luego excepciones (ignore-previous-rules), luego cosmético.
            var rules = blocks
            rules.append(contentsOf: exceptions)
            rules.append(cosmeticRule())
            // Diagnóstico: cuántas reglas se generaron (legible con `defaults read`).
            UserDefaults.standard.set(rules.count, forKey: "stacklume.adblock.ruleCount")
            guard let out = try? JSONSerialization.data(withJSONObject: rules),
                  let json = String(data: out, encoding: .utf8) else { return nil }
            return json
        }.value
    }

    /// Resultado de convertir una línea de filtro: la regla + si es excepción.
    private struct ParsedRule { let dict: [String: Any]; let isException: Bool }

    /// Convierte una línea `||dominio^[$opciones]` (o `@@||...`) a una regla de WebKit.
    /// Devuelve `nil` para comentarios, cosméticos, reglas con path/regex/comodines o con
    /// opciones no soportadas (se omiten para no invalidar la compilación entera).
    nonisolated private static func parseNetworkRule(_ line: String) -> ParsedRule? {
        var s = line.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !s.hasPrefix("!"), !s.hasPrefix("[") else { return nil }
        // Cosméticos y otras formas no-red: las maneja `cosmeticRule()`.
        if s.contains("##") || s.contains("#@#") || s.contains("#?#") || s.contains("#$#") { return nil }
        // Las excepciones (@@) de EasyList suelen estar ACOTADAS por opciones; convertirlas a
        // un «desbloqueo» de dominio completo levantaba el bloqueo de rastreadores enteros.
        // Como solo bloqueamos dominios dedicados de ads/tracking, las descartamos (bloqueo
        // agresivo, estilo Brave con «anuncios aceptables» desactivados).
        if s.hasPrefix("@@") { return nil }
        guard s.hasPrefix("||") else { return nil }
        s.removeFirst(2)
        // Separa las opciones ($...).
        var options = ""
        if let dollar = s.firstIndex(of: "$") {
            options = String(s[s.index(after: dollar)...])
            s = String(s[..<dollar])
        }
        if s.hasSuffix("^") { s.removeLast() }
        // Separa host y path: `||dominio.com/ads/*` → host=dominio.com, path=/ads/*.
        var host = s, path = ""
        if let slash = s.firstIndex(of: "/") {
            host = String(s[..<slash]); path = String(s[slash...])
        }
        host = host.lowercased()
        // El host debe ser un dominio ASCII limpio (una regla inválida tumba TODA la
        // compilación de WebKit, así que somos estrictos).
        guard !host.isEmpty, host.contains("."),
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") })
        else { return nil }

        // Solo nos quedamos con la señal `third-party`; si la regla trae opciones complejas
        // (csp, redirect, document, dominio…) la omitimos (no se convierten con fidelidad).
        var loadType: [String]?
        if !options.isEmpty {
            let opts = options.split(separator: ",").map { String($0).lowercased() }
            let unsupported: Set<String> = [
                "popup", "csp", "redirect", "redirect-rule", "removeparam", "genericblock",
                "generichide", "elemhide", "specifichide", "inline-script", "inline-font",
                "cookie", "empty", "webrtc", "important", "badfilter", "all", "header",
                "method", "stealth", "replace", "permissions", "~third-party", "document",
            ]
            for o in opts where unsupported.contains(o) || o.contains("=") || o.hasPrefix("~") || o.hasPrefix("domain") {
                return nil
            }
            if opts.contains("third-party") || opts.contains("3p") { loadType = ["third-party"] }
        }
        let escHost = host.replacingOccurrences(of: ".", with: "\\.")
        // Sin `resource-type`: bloqueamos TODO el tráfico que case (como un bloqueador por
        // hosts), más efectivo y con menos reglas inválidas.
        var urlFilter = "^https?://([^/]+\\.)?\(escHost)"
        if !path.isEmpty {
            urlFilter += abpPathToRegex(path)
            // Las reglas con path son las que pueden generar regex inválido → valídalo y
            // omítelas si no compila (NSRegularExpression es superconjunto del regex de WebKit).
            guard isValidRegex(urlFilter) else { return nil }
        }
        var trigger: [String: Any] = ["url-filter": urlFilter]
        if let loadType { trigger["load-type"] = loadType }
        return ParsedRule(dict: ["trigger": trigger, "action": ["type": "block"]], isException: false)
    }

    /// Convierte la parte de PATH de una regla ABP a regex de WebKit: `*`→`.*`, separador
    /// `^` se ignora (amplía un poco), y se escapan los metacaracteres regex.
    nonisolated private static func abpPathToRegex(_ p: String) -> String {
        var out = ""
        for ch in p {
            switch ch {
            case "*": out += ".*"
            case "^": break   // separador ABP → omitido
            case ".", "?", "+", "(", ")", "[", "]", "{", "}", "$", "|", "\\": out += "\\\(ch)"
            default: out.append(ch)
            }
        }
        return out
    }

    /// ¿Es un regex válido? (filtra los patrones de path que generarían un regex erróneo).
    nonisolated private static func isValidRegex(_ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern)) != nil
    }

    /// Regla cosmética única (oculta contenedores de anuncios) con selectores seguros.
    nonisolated private static func cosmeticRule() -> [String: Any] {
        ["trigger": ["url-filter": ".*"],
         "action": ["type": "css-display-none", "selector": cosmeticSelectors.joined(separator: ", ")]]
    }

    // MARK: - Respaldo embebido (offline / si falla la descarga)

    /// Dominios de publicidad/rastreo más extendidos (respaldo cuando no hay red).
    nonisolated static let blockedDomains: [String] = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "google-analytics.com", "googletagmanager.com", "googletagservices.com",
        "adservice.google.com", "2mdn.net", "app-measurement.com", "amazon-adsystem.com",
        "scorecardresearch.com", "quantserve.com", "quantcount.com", "hotjar.com",
        "mouseflow.com", "fullstory.com", "mixpanel.com", "segment.com", "segment.io",
        "amplitude.com", "chartbeat.com", "nr-data.net", "criteo.com", "criteo.net",
        "adnxs.com", "rubiconproject.com", "pubmatic.com", "openx.net", "casalemedia.com",
        "advertising.com", "adform.net", "smartadserver.com", "moatads.com", "adsrvr.org",
        "bidswitch.net", "sharethrough.com", "teads.tv", "yieldmo.com", "indexww.com",
        "3lift.com", "gumgum.com", "media.net", "adcolony.com", "applovin.com", "inmobi.com",
        "taboola.com", "outbrain.com", "mgid.com", "revcontent.com", "zergnet.com",
        "branch.io", "adjust.com", "appsflyer.com", "kochava.com", "bluekai.com",
        "demdex.net", "krxd.net", "agkn.com", "rlcdn.com", "crwdcntrl.net",
    ]

    /// Selectores CSS de contenedores de anuncios habituales (filtro cosmético seguro).
    nonisolated static let cosmeticSelectors: [String] = [
        ".adsbygoogle", "ins.adsbygoogle",
        "[id^=\"div-gpt-ad\"]", "[id^=\"google_ads_\"]", "[id^=\"google_ads_iframe\"]",
        "iframe[src*=\"doubleclick.net\"]", "iframe[src*=\"googlesyndication\"]",
        "iframe[src*=\"adnxs.com\"]", "[data-ad-slot]", "[data-ad-client]",
        ".advertisement", ".ad-banner", ".ad-container", ".ads-container", ".banner-ad",
        "[aria-label=\"Advertisement\"]", "[aria-label=\"Ad\"]",
        ".taboola", ".outbrain", "#taboola-below-article-thumbnails",
    ]

    /// JSON de respaldo (lista curada embebida) en formato de WebKit.
    nonisolated private static func fallbackJSON() -> String {
        var rules: [[String: Any]] = blockedDomains.map { domain in
            let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
            return ["trigger": ["url-filter": "^https?://([^/]+\\.)?\(escaped)", "load-type": ["third-party"]],
                    "action": ["type": "block"]]
        }
        rules.append(cosmeticRule())
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }
}
