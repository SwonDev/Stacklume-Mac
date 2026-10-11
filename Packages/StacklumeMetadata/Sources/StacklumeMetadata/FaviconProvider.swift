import Foundation

/// Proveedor de favicon garantizado. El servicio s2 de Google siempre devuelve
/// un icono (el del sitio o uno genérico), por lo que sirve de fallback fiable.
public enum FaviconProvider {
    public static func googleFavicon(forURL urlString: String, size: Int = 128) -> String {
        let value = urlString.contains("://") ? urlString : "https://" + urlString
        let host = URL(string: value)?.host()?.lowercased()
            ?? urlString.lowercased()
        return "https://www.google.com/s2/favicons?domain=\(host)&sz=\(size)"
    }
}
