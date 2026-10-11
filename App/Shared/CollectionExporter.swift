import AppKit
import SwiftData
import UniformTypeIdentifiers
import StacklumeCore
import StacklumePersistence

/// Exporta una colección concreta a un archivo elegido por el usuario, reutilizando
/// las funciones ya existentes del paquete compartido (`BackupService.exportCollection`
/// para JSON y `NetscapeBookmarks.export` para HTML de marcadores). Diferenciador frente
/// a Raindrop en el escritorio: exportar/compartir una colección suelta (no solo toda la
/// biblioteca, que ya está en Ajustes › Datos). Usa `NSSavePanel` (AppKit) para no tener
/// que arrastrar estado de `fileExporter` hasta el menú contextual del sidebar.
@MainActor
enum CollectionExporter {
    /// Exporta la colección a JSON (re-importable desde Ajustes › Datos › «Importar desde JSON»).
    static func exportJSON(_ category: BookmarkCategory, in context: ModelContext) {
        let panel = makePanel(suggested: "\(safeName(category.name)).json", types: [.json])
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try BackupService.exportCollection(category.id, from: context)
            try data.write(to: url, options: .atomic)
        } catch {
            presentError(error, action: "exportar la colección a JSON")
        }
    }

    /// Exporta los enlaces de la colección a un archivo HTML de marcadores (formato
    /// Netscape), importable por cualquier navegador.
    static func exportHTML(_ category: BookmarkCategory) {
        let panel = makePanel(suggested: "\(safeName(category.name)).html", types: [.html])
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let links = category.links.filter { $0.deletedAt == nil }
            .sorted { $0.createdAt < $1.createdAt }
        let html = NetscapeBookmarks.export(links)
        do {
            try Data(html.utf8).write(to: url, options: .atomic)
        } catch {
            presentError(error, action: "exportar la colección a HTML")
        }
    }

    /// Exporta un conjunto ARBITRARIO de enlaces (p. ej. la selección de la barra de lote)
    /// a HTML de marcadores Netscape, importable en cualquier navegador o gestor.
    static func exportHTML(_ links: [Bookmark], suggestedName: String) {
        let panel = makePanel(suggested: "\(safeName(suggestedName)).html", types: [.html])
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let active = links.filter { $0.deletedAt == nil }.sorted { $0.createdAt < $1.createdAt }
        do {
            try Data(NetscapeBookmarks.export(active).utf8).write(to: url, options: .atomic)
        } catch {
            presentError(error, action: "exportar la selección a HTML")
        }
    }

    // MARK: - Privado

    private static func makePanel(suggested: String, types: [UTType]) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = "Exportar colección"
        panel.nameFieldStringValue = suggested
        panel.allowedContentTypes = types
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return panel
    }

    /// Nombre de archivo seguro: sin separadores de ruta ni caracteres problemáticos.
    private static func safeName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Colección" : cleaned
    }

    private static func presentError(_ error: Error, action: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "No se pudo \(action)"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Aceptar")
        alert.runModal()
    }
}
