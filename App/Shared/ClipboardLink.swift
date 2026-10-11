import AppKit
import Foundation
import StacklumeMetadata

/// Detección compartida de enlaces en el portapapeles del sistema (`NSPasteboard`),
/// reutilizada por el banner del editor y por el banner a nivel de ventana. Centraliza
/// la lectura para NO duplicar la lógica (el patrón de `NSPasteboard.general` ya estaba
/// en `DiscoverWidget.copyToPasteboard`, pero para COPIAR; aquí es para LEER).
///
/// Privacidad: solo se llama cuando la app está activa (al abrir el editor, al volver a
/// primer plano). No expone ni persiste el contenido del portapapeles más allá de la URL
/// que el usuario decida pegar/añadir.
@MainActor
enum ClipboardLink {

    /// Devuelve la URL `http(s)` que contenga el portapapeles ahora mismo, normalizada,
    /// o `nil` si no hay ninguna. Acepta tanto URLs reales como texto que sea una URL.
    static func currentURLString() -> String? {
        let pasteboard = NSPasteboard.general
        // 1) Una URL real en el portapapeles (p. ej. copiada desde Safari).
        if let url = NSURL(from: pasteboard) as URL?, isWebURL(url) {
            return url.absoluteString
        }
        // 2) Texto que sea una URL `http(s)` (el caso más común al copiar un enlace).
        guard let raw = pasteboard.string(forType: .string) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), isWebURL(url) else { return nil }
        return url.absoluteString
    }

    /// Algo «guardable» del portapapeles: una URL `http(s)` O un comando de instalación
    /// (npm i…, pip install…, brew install…). Devuelve el texto tal cual para que el alta
    /// (`LinkIngest`, command-aware) lo resuelva. `nil` si no hay nada útil. App muy
    /// enfocada a desarrolladores: copiar un comando y guardarlo debe funcionar igual que
    /// una URL.
    static func currentSaveable() -> String? {
        if let url = currentURLString() { return url }
        guard let raw = NSPasteboard.general.string(forType: .string) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return CommandDetector.detect(trimmed) != nil ? trimmed : nil
    }

    /// TODAS las cosas guardables del portapapeles (varias URLs/comandos, UNA POR LÍNEA),
    /// para «pegar varios enlaces a la vez». Deduplicado y en orden. Trocea por líneas (no
    /// por espacios) para no romper los comandos con espacios («npm install foo»).
    static func allSaveable() -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ s: String) {
            let key = s.lowercased()
            guard seen.insert(key).inserted else { return }
            out.append(s)
        }
        if let url = NSURL(from: NSPasteboard.general) as URL?, isWebURL(url) { add(url.absoluteString) }
        guard let raw = NSPasteboard.general.string(forType: .string) else { return out }
        for line in raw.split(whereSeparator: { $0.isNewline }) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if let url = URL(string: t), isWebURL(url) { add(url.absoluteString) }
            else if CommandDetector.detect(t) != nil { add(t) }
        }
        return out
    }

    /// `changeCount` actual del portapapeles: se incrementa con cada copia. Permite
    /// detectar SOLO contenido nuevo (no reprocesar lo mismo) en el banner de ventana.
    static var changeCount: Int { NSPasteboard.general.changeCount }

    private static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && (url.host?.isEmpty == false)
    }
}

extension NSPasteboard {
    /// Copia un texto al portapapeles del sistema (unifica el patrón clear+set repetido
    /// por toda la app: copiar enlace, comando, Markdown, lista de URLs…).
    static func copyString(_ string: String) {
        general.clearContents()
        general.setString(string, forType: .string)
    }
}
