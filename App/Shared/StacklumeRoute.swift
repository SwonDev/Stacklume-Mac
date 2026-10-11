import Foundation

/// Rutas internas admitidas por Stacklume. El parser es deliberadamente cerrado:
/// nunca reenvía esquemas arbitrarios ni interpreta una ruta desconocida.
enum StacklumeRoute: Sendable, Equatable {
    case add(URL)
    case bookmark(UUID)
    case section(String)
    case favorites

    static func parse(_ url: URL) -> StacklumeRoute? {
        guard url.scheme?.lowercased() == "stacklume" else { return nil }
        let host = url.host?.lowercased()
        switch host {
        case "add":
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let raw = components.queryItems?.first(where: { $0.name == "url" })?.value,
                  let webURL = StacklumeAutomationPolicy.openableStoredURL(raw),
                  StacklumeAutomationPolicy.allowsExternalCaptureURL(webURL) else { return nil }
            return .add(webURL)
        case "bookmark":
            guard let rawID = url.pathComponents.dropFirst().first,
                  let id = UUID(uuidString: rawID) else { return nil }
            return .bookmark(id)
        case "section":
            guard let key = url.pathComponents.dropFirst().first,
                  !key.isEmpty else { return nil }
            return .section(key)
        case "open":
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let rawID = components?.queryItems?.first(where: { $0.name == "id" })?.value,
               let id = UUID(uuidString: rawID) {
                return .bookmark(id)
            }
            return .favorites
        default:
            return nil
        }
    }
}
