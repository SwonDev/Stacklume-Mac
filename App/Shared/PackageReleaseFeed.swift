import Foundation

/// Resuelve el feed RSS/Atom de versiones de un paquete a partir de su gestor + nombre.
/// Es el análogo, para comandos de instalación (npm i…, pip install…), de «Seguir
/// lanzamientos» de un repositorio de GitHub: permite seguir las nuevas versiones de
/// las herramientas que el usuario guarda, dentro de «Tus feeds» de Descubrir.
///
/// Verificado con peticiones reales a cada registro (jun 2026):
/// - **PyPI** (pip) y **Packagist** (composer): tienen RSS nativo → URL determinista,
///   SIN red.
/// - **npm/pnpm/yarn/bun**, **cargo**, **gem**: no tienen RSS nativo, pero su API
///   expone el repositorio de origen → se sigue su `releases.atom` de GitHub (una
///   consulta de solo lectura al registro).
/// - **go**: la ruta del módulo suele ser ya un repo de GitHub → directo.
/// - **brew/dotnet** y módulos no alojados en GitHub: sin feed fiable → `nil` (no se
///   ofrece, para no prometer algo que falle).
enum PackageReleaseFeed {

    struct Resolved: Sendable, Equatable {
        let feedURL: String
        let title: String
    }

    /// `true` si para este gestor TIENE SENTIDO ofrecer «Seguir versiones» (la
    /// resolución concreta puede aún fallar para un paquete sin repo conocido).
    static func isSupported(manager: String) -> Bool {
        switch manager {
        case "pip", "composer", "npm", "pnpm", "yarn", "bun", "cargo", "gem", "go": true
        default: false
        }
    }

    /// Resuelve el feed de versiones. `async` porque npm/cargo/gem requieren una
    /// consulta al registro para localizar el repositorio de origen. Devuelve `nil`
    /// si el paquete no tiene un feed de versiones fiable.
    static func resolve(manager: String, packageName: String) async -> Resolved? {
        let pkg = packageName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pkg.isEmpty else { return nil }
        let title = "Versiones · \(pkg)"

        switch manager {
        case "pip":
            // PyPI tiene RSS nativo de versiones (determinista, sin red).
            let enc = pkg.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? pkg
            return Resolved(feedURL: "https://pypi.org/rss/project/\(enc)/releases.xml", title: title)

        case "composer":
            // Packagist tiene RSS nativo, pero necesita «vendor/paquete».
            guard pkg.contains("/") else { return nil }
            return Resolved(feedURL: "https://packagist.org/feeds/package.\(pkg).rss", title: title)

        case "go":
            // La ruta del módulo suele ser github.com/owner/repo[/sub…].
            guard let slug = githubSlug(fromModulePath: pkg) else { return nil }
            return Resolved(feedURL: releasesAtom(slug), title: title)

        case "npm", "pnpm", "yarn", "bun":
            guard let slug = await githubSlugFromNpm(pkg) else { return nil }
            return Resolved(feedURL: releasesAtom(slug), title: title)

        case "cargo":
            guard let slug = await githubSlugFromCrates(pkg) else { return nil }
            return Resolved(feedURL: releasesAtom(slug), title: title)

        case "gem":
            guard let slug = await githubSlugFromRubyGems(pkg) else { return nil }
            return Resolved(feedURL: releasesAtom(slug), title: title)

        default:
            return nil
        }
    }

    private static func releasesAtom(_ slug: String) -> String {
        "https://github.com/\(slug)/releases.atom"
    }

    // MARK: - Resolución del repo de origen (GitHub) vía API del registro

    private static func githubSlugFromNpm(_ pkg: String) async -> String? {
        // Los paquetes con scope codifican la barra (@types/node → @types%2Fnode).
        let enc = pkg.replacingOccurrences(of: "/", with: "%2F")
        guard let url = URL(string: "https://registry.npmjs.org/\(enc)"),
              let obj = await fetchJSON(url) else { return nil }
        if let repo = obj["repository"] as? [String: Any], let u = repo["url"] as? String,
           let slug = githubSlug(fromRepoURL: u) { return slug }
        if let u = obj["repository"] as? String, let slug = githubSlug(fromRepoURL: u) { return slug }
        if let u = obj["homepage"] as? String, let slug = githubSlug(fromRepoURL: u) { return slug }
        return nil
    }

    private static func githubSlugFromCrates(_ name: String) async -> String? {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        guard let url = URL(string: "https://crates.io/api/v1/crates/\(enc)"),
              let obj = await fetchJSON(url),
              let crate = obj["crate"] as? [String: Any] else { return nil }
        for key in ["repository", "homepage"] {
            if let u = crate[key] as? String, let slug = githubSlug(fromRepoURL: u) { return slug }
        }
        return nil
    }

    private static func githubSlugFromRubyGems(_ name: String) async -> String? {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        guard let url = URL(string: "https://rubygems.org/api/v1/gems/\(enc).json"),
              let obj = await fetchJSON(url) else { return nil }
        for key in ["source_code_uri", "homepage_uri", "project_uri", "bug_tracker_uri"] {
            if let u = obj[key] as? String, let slug = githubSlug(fromRepoURL: u) { return slug }
        }
        return nil
    }

    private static func fetchJSON(_ url: URL) async -> [String: Any]? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // crates.io exige un User-Agent identificable; el resto lo aceptan igual.
        req.setValue("Stacklume/1.0 (macOS; bookmark manager)", forHTTPHeaderField: "User-Agent")
        guard let result = try? await ExternalHTTPClient.shared.data(
            for: req,
            maximumBytes: 16 * 1_024 * 1_024,
            allowedMIMEPrefixes: ["application/json"]
        ),
        let obj = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    // MARK: - Extracción de «owner/repo» de GitHub

    /// `owner/repo` desde una URL de repositorio: `git+https://github.com/o/r.git`,
    /// `https://github.com/o/r/tree/v1`, `git://github.com/o/r`… `nil` si no es GitHub.
    static func githubSlug(fromRepoURL raw: String) -> String? {
        guard let r = raw.range(of: "github.com") else { return nil }
        let rest = raw[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ":/"))
        let parts = rest.split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        var repo = parts[1]
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard !repo.isEmpty else { return nil }
        return "\(parts[0])/\(repo)"
    }

    /// `owner/repo` desde una ruta de módulo Go (`github.com/owner/repo[/sub…]`).
    static func githubSlug(fromModulePath path: String) -> String? {
        guard path.lowercased().hasPrefix("github.com/") else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3 else { return nil }   // github.com / owner / repo
        return "\(parts[1])/\(parts[2])"
    }
}
