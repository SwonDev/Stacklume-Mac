import AppKit
import UniformTypeIdentifiers

/// Extensión de compartir de macOS: recibe una URL (de Safari u otra app) y abre
/// Stacklume mediante el deep link `stacklume://add?url=<URL_CODIFICADA>`. La app
/// procesa ese enlace (`onOpenURL`) y crea el marcador en su propio store.
///
/// Sin App Group: la extensión no toca SwiftData; solo construye el deep link y
/// pide al sistema que abra la app. Versión deliberadamente mínima (sin UI).
final class ShareViewController: NSViewController {

    override func loadView() {
        // No necesita interfaz: usamos una vista vacía y resolvemos en `viewDidLoad`.
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { @MainActor in
            if let url = await extractURL() {
                openApp(with: url)
            }
            finish()
        }
    }

    /// Construye `stacklume://add?url=<encoded>` y abre la app con `NSWorkspace`.
    @MainActor
    private func openApp(with url: URL) {
        var components = URLComponents()
        components.scheme = "stacklume"
        components.host = "add"
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        guard let deepLink = components.url else { return }
        NSWorkspace.shared.open(deepLink)
    }

    /// Completa la extensión sin devolver elementos.
    private func finish() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    // MARK: - Extracción de la URL compartida

    @MainActor
    private func extractURL() async -> URL? {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }

        // 1) URL directa (Safari y la mayoría de apps comparten public.url).
        let urlType = UTType.url.identifier
        for provider in providers where provider.hasItemConformingToTypeIdentifier(urlType) {
            let loaded = try? await provider.loadItem(forTypeIdentifier: urlType)
            if let url = loaded as? URL, url.scheme?.hasPrefix("http") == true { return url }
            if let nsurl = loaded as? NSURL, (nsurl as URL).scheme?.hasPrefix("http") == true {
                return nsurl as URL
            }
        }

        // 2) Texto plano: extrae la primera URL incrustada.
        for textType in [UTType.plainText.identifier, UTType.text.identifier] {
            for provider in providers where provider.hasItemConformingToTypeIdentifier(textType) {
                let loaded = try? await provider.loadItem(forTypeIdentifier: textType)
                let text = (loaded as? String) ?? (loaded as? NSAttributedString)?.string
                if let text, let url = firstURL(in: text) { return url }
            }
        }
        return nil
    }

    /// Encuentra la primera URL http(s) dentro de un texto.
    private func firstURL(in text: String) -> URL? {
        if let direct = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           direct.scheme?.hasPrefix("http") == true {
            return direct
        }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        if let url = detector?.firstMatch(in: text, range: range)?.url,
           url.scheme?.hasPrefix("http") == true {
            return url
        }
        return nil
    }
}
