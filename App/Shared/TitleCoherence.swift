import Foundation

/// Detección DETERMINISTA de un título que NO corresponde al enlace (alucinación). Sin
/// contenido real de la página, el modelo llegó a inventar títulos completamente AJENOS
/// («Wild Sky Guardians en Steam» para `github.com/siddharthvaddem/openscreen»). Esto los
/// detecta para CORREGIRLOS (refrescar el `og:title` real + regenerar la descripción que
/// quedó contaminada) y, junto con el blindaje `grounded` del título en el enriquecido,
/// que no vuelvan a colarse.
///
/// CONSERVADOR a propósito: solo juzga sitios cuyo SLUG es canónico y cuyo título correcto
/// SIEMPRE lo contiene (hoy: la HOME de un repo de GitHub `owner/repo`). Ante cualquier duda
/// NO marca (devuelve `false`/`nil`) para no tocar títulos legítimos.
enum TitleCoherence {

    /// ¿El `title` parece NO tener relación con la `url`? Solo `true` en casos clarísimos:
    /// es la home de un repo de GitHub y el título no menciona ni el `owner`, ni el `repo`,
    /// ni ninguno de sus sub-tokens (p. ej. «open-screen» → «open»/«screen»).
    static func titleLikelyUnrelated(title: String, url: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Vacío o «=host» se gestionan aparte (esos SÍ se reescriben siempre).
        guard t.count >= 3 else { return false }
        guard let slug = githubRepoTokens(url) else { return false }
        let folded = normalize(t)
        guard !folded.isEmpty else { return false }
        // Coherente si menciona CUALQUIER token significativo del recurso; si no menciona
        // NINGUNO → el título es ajeno al enlace (alucinación).
        return !slug.contains { folded.contains($0) }
    }

    /// «owner/repo» con el casing ORIGINAL de la URL (p. ej. «AlexandrosGounis/pdfx»), o `nil`
    /// si la URL no es la HOME de un repo de GitHub. Sirve como título DETERMINISTA de respaldo:
    /// el modelo local pequeño inventa la parte descriptiva del título de un repo («owner/repo:
    /// Guardias de cielo…»), así que para GitHub el título lo fija la red (og:title) o, en su
    /// defecto, este «owner/repo» real — nunca el modelo.
    static func githubOwnerRepo(_ url: String) -> String? {
        guard let u = URL(string: url), let host = u.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let reserved: Set<String> = [
            "orgs", "sponsors", "topics", "collections", "marketplace", "settings",
            "notifications", "explore", "search", "about", "features", "pricing",
            "login", "join", "new", "apps", "codespaces", "dashboard", "stars",
        ]
        guard !reserved.contains(parts[0].lowercased()) else { return nil }
        if parts.count > 2 {
            let subpages: Set<String> = [
                "issues", "pull", "pulls", "blob", "tree", "wiki", "releases", "actions",
                "discussions", "commits", "commit", "branches", "tags", "projects",
                "security", "pulse", "graphs", "compare", "raw", "settings", "milestones",
            ]
            if subpages.contains(parts[2].lowercased()) { return nil }
        }
        return "\(parts[0])/\(parts[1])"
    }

    /// Tokens significativos (≥3 chars, normalizados) del recurso de GitHub: `owner`, `repo`
    /// y los sub-tokens del repo partido por `-_.`. `nil` si la URL NO es la HOME de un repo
    /// `github.com/owner/repo` (perfiles, sub-páginas tipo issues/pull/tree, gists, etc.).
    private static func githubRepoTokens(_ url: String) -> [String]? {
        guard let u = URL(string: url), let host = u.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }            // perfil/raíz → no juzgar
        // Rutas reservadas de GitHub que NO son «owner/repo».
        let reserved: Set<String> = [
            "orgs", "sponsors", "topics", "collections", "marketplace", "settings",
            "notifications", "explore", "search", "about", "features", "pricing",
            "login", "join", "new", "apps", "codespaces", "dashboard", "stars",
        ]
        let owner = parts[0].lowercased(), repo = parts[1].lowercased()
        guard !reserved.contains(owner) else { return nil }
        // Sub-páginas del repo (issues, pull, tree…): el título legítimo es el de la
        // sub-página, no el del repo → NO juzgar (evita falsos positivos).
        if parts.count > 2 {
            let subpages: Set<String> = [
                "issues", "pull", "pulls", "blob", "tree", "wiki", "releases", "actions",
                "discussions", "commits", "commit", "branches", "tags", "projects",
                "security", "pulse", "graphs", "compare", "raw", "settings", "milestones",
            ]
            if subpages.contains(parts[2].lowercased()) { return nil }
        }
        var tokens = [normalize(owner), normalize(repo)]
        for piece in repo.split(whereSeparator: { "-_.".contains($0) }) {
            let n = normalize(String(piece))
            if n.count >= 3 { tokens.append(n) }
        }
        return tokens.filter { $0.count >= 3 }
    }

    /// Minúsculas, sin tildes, solo alfanuméricos (comparación robusta, igual que TitleCleaner).
    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}
