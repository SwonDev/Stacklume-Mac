import Foundation
import StacklumeCore

/// Genera etiquetas automáticas de forma heurística (fiel al fallback sin IA del
/// Stacklume original): plataforma + tipo de contenido + palabras clave del
/// título + dominio. Máximo 5 etiquetas, sin duplicados.
public enum AutoTagger {

    public static func tags(platform: Platform, contentType: ContentType, title: String, url: String) -> [String] {
        var result: [String] = []
        let limit = 5

        func add(_ tag: String) {
            guard result.count < limit else { return }
            guard !result.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return }
            result.append(tag)
        }

        // 1. Plataforma
        if platform != .generic { add(platform.displayName) }
        // 2. Tipo de contenido
        if contentType != .website { add(contentType.displayName) }

        // 3. Palabras clave del título
        let lowerTitle = title.lowercased()
        for (key, tag) in keywordMap {
            guard result.count < limit else { break }
            if matches(keyword: key, in: lowerTitle) { add(tag) }
        }

        // 4. Dominio
        let host = hostname(of: url)
        for (domain, tag) in domainTags where host == domain || host.hasSuffix("." + domain) {
            add(tag)
        }

        return result
    }

    // MARK: - Tablas (literales del original)

    private static let keywordMap: [(String, String)] = [
        ("react", "React"), ("vue", "Vue"), ("angular", "Angular"), ("svelte", "Svelte"),
        ("next.js", "Next.js"), ("nextjs", "Next.js"), ("nuxt", "Nuxt"),
        ("typescript", "TypeScript"), ("javascript", "JavaScript"), ("python", "Python"),
        ("rust", "Rust"), ("go", "Go"), ("java", "Java"), ("kotlin", "Kotlin"), ("swift", "Swift"),
        ("docker", "Docker"), ("kubernetes", "Kubernetes"), ("aws", "AWS"), ("azure", "Azure"),
        ("tailwind", "TailwindCSS"), ("css", "CSS"), ("html", "HTML"),
        ("api", "API"), ("graphql", "GraphQL"), ("rest", "REST"),
        ("tutorial", "Tutorial"), ("documentation", "Documentación"), ("docs", "Documentación"),
        ("guía", "Guía"), ("guide", "Guía"), ("curso", "Curso"), ("course", "Curso"),
        ("tool", "Herramienta"), ("herramienta", "Herramienta"),
        ("library", "Librería"), ("librería", "Librería"), ("framework", "Framework"),
        ("game", "Videojuegos"), ("juego", "Videojuegos"),
        ("design", "Diseño"), ("diseño", "Diseño"), ("figma", "Figma"),
        ("ai", "IA"), ("ia", "IA"), ("machine learning", "ML"), ("llm", "LLM"),
        ("open source", "Open Source"), ("github", "GitHub")
    ]

    private static let domainTags: [(String, String)] = [
        ("github.com", "GitHub"), ("youtube.com", "YouTube"), ("dev.to", "Dev.to"),
        ("medium.com", "Medium"), ("stackoverflow.com", "StackOverflow"),
        ("npmjs.com", "npm"), ("pypi.org", "PyPI"), ("crates.io", "Crates.io"),
        ("figma.com", "Figma"), ("dribbble.com", "Dribbble")
    ]

    // MARK: - Utilidades

    /// Coincidencia por palabra completa (evita que "go" coincida en "google").
    /// Para claves con punto o espacio usa contención directa.
    private static func matches(keyword: String, in text: String) -> Bool {
        if keyword.contains(".") || keyword.contains(" ") {
            return text.contains(keyword)
        }
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text.contains(keyword)
        }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func hostname(of urlString: String) -> String {
        let value = urlString.contains("://") ? urlString : "https://" + urlString
        let host = URL(string: value)?.host()?.lowercased() ?? urlString.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
