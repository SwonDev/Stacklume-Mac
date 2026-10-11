import Foundation
import StacklumeCore

/// Información de un comando de instalación detectado (npm i, pnpm add, pip
/// install, brew install, cargo add, etc.). Equivalente a `detectCommand` de la
/// versión web de Stacklume.
public struct CommandInfo: Sendable, Equatable {
    /// Nombre del paquete (admite `@scope/name`).
    public let packageName: String
    /// Gestor: npm, pnpm, yarn, bun, pip, brew, cargo, go, gem, composer, dotnet.
    public let manager: String
    /// Comando original completo, tal cual lo escribió el usuario.
    public let command: String
    /// URL del registro/página del paquete (para adquirir metadatos como el resto).
    public let registryURL: String
    /// Plataforma para la insignia (npm/pypi cuando aplica; si no, genérica).
    public let platform: Platform
    /// Color de marca del gestor (para la tarjeta de comando).
    public let colorHex: String
}

/// Detecta comandos de instalación de paquetes y extrae el paquete + gestor.
public enum CommandDetector {

    /// Devuelve la info del comando si `input` es un comando de instalación; si es
    /// una URL o no coincide con ningún patrón conocido, devuelve `nil`.
    public static func detect(_ input: String) -> CommandInfo? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("http://"),
              !trimmed.hasPrefix("https://") else { return nil }

        // Reglas en orden (prefijo regex → gestor, URL de registro, plataforma, color).
        for rule in rules {
            guard let pkg = extractPackage(from: trimmed, prefix: rule.prefix) else { continue }
            return CommandInfo(
                packageName: pkg, manager: rule.manager, command: trimmed,
                registryURL: rule.registryURL(pkg), platform: rule.platform, colorHex: rule.colorHex)
        }
        return nil
    }

    /// Color de marca de un gestor (para tarjetas/insignias). Acento por defecto.
    public static func color(forManager manager: String) -> String {
        rules.first { $0.manager == manager }?.colorHex ?? "#6B7280"
    }

    // MARK: - Reglas

    private struct Rule: Sendable {
        let prefix: String          // patrón regex del prefijo (sin anclar; se ancla aquí)
        let manager: String
        let platform: Platform
        let colorHex: String
        let registryURL: @Sendable (String) -> String
    }

    private static let rules: [Rule] = [
        Rule(prefix: #"^(?:npm\s+(?:install|i|add)|npx)\s+"#, manager: "npm", platform: .npm,
             colorHex: "#CB3837", registryURL: { "https://www.npmjs.com/package/\($0)" }),
        Rule(prefix: #"^pnpm\s+(?:add|install|i|dlx)\s+"#, manager: "pnpm", platform: .npm,
             colorHex: "#F69220", registryURL: { "https://www.npmjs.com/package/\($0)" }),
        Rule(prefix: #"^yarn\s+(?:add|global\s+add)\s+"#, manager: "yarn", platform: .npm,
             colorHex: "#2C8EBB", registryURL: { "https://www.npmjs.com/package/\($0)" }),
        Rule(prefix: #"^(?:bun\s+(?:add|install|i)|bunx)\s+"#, manager: "bun", platform: .npm,
             colorHex: "#FBF0DF", registryURL: { "https://www.npmjs.com/package/\($0)" }),
        Rule(prefix: #"^pip3?\s+install\s+(?:-[UuI]\s+)*"#, manager: "pip", platform: .pypi,
             colorHex: "#3776AB", registryURL: { "https://pypi.org/project/\($0)/" }),
        Rule(prefix: #"^brew\s+(?:install|cask\s+install)\s+"#, manager: "brew", platform: .generic,
             colorHex: "#FBB040", registryURL: { "https://formulae.brew.sh/formula/\($0)" }),
        Rule(prefix: #"^cargo\s+(?:install|add)\s+"#, manager: "cargo", platform: .generic,
             colorHex: "#DEA584", registryURL: { "https://crates.io/crates/\($0)" }),
        Rule(prefix: #"^go\s+install\s+"#, manager: "go", platform: .generic,
             colorHex: "#00ADD8", registryURL: { "https://pkg.go.dev/\($0)" }),
        Rule(prefix: #"^gem\s+install\s+"#, manager: "gem", platform: .generic,
             colorHex: "#CC342D", registryURL: { "https://rubygems.org/gems/\($0)" }),
        Rule(prefix: #"^composer\s+require\s+"#, manager: "composer", platform: .generic,
             colorHex: "#885630", registryURL: { "https://packagist.org/packages/\($0)" }),
        Rule(prefix: #"^dotnet\s+add\s+package\s+"#, manager: "dotnet", platform: .generic,
             colorHex: "#512BD4", registryURL: { "https://www.nuget.org/packages/\($0)" }),
    ]

    /// Extrae el nombre del paquete tras el prefijo: primer token que no sea flag,
    /// quitando `@version` final pero conservando `@scope`.
    private static func extractPackage(from command: String, prefix: String) -> String? {
        guard let range = command.range(of: prefix, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let rest = command[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        let tokens = rest.split(whereSeparator: \.isWhitespace).map(String.init)
        guard var pkg = tokens.first(where: { !$0.hasPrefix("-") }) else { return nil }
        // Para go: el paquete puede ser una ruta; nos quedamos con el último segmento.
        // (Se gestiona en la regla; aquí solo limpiamos versiones.)
        // Quita @version final (streamdown@1.0.0, @types/node@20) sin tocar @scope.
        if let at = pkg.range(of: #"@(?:\d[\w.\-]*|latest|next|canary|beta|alpha|rc)$"#,
                              options: [.regularExpression, .caseInsensitive]) {
            pkg = String(pkg[pkg.startIndex..<at.lowerBound])
        }
        return pkg.isEmpty ? nil : pkg
    }
}
