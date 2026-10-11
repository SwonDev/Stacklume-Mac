import SwiftUI
import AppKit
import StacklumeCore
import StacklumeDesignSystem

/// Menús de barra de Stacklume. Cada acción se comunica mediante
/// `NotificationCenter` para desacoplar la barra de menús de la ventana.
struct StacklumeCommands: Commands {
    /// Acción del sistema para abrir escenas por id (la ventana de Ayuda).
    @Environment(\.openWindow) private var openWindow

    /// Destinos fijos del menú «Ir» (título visible + destino + atajo opcional). Las
    /// colecciones y etiquetas, al ser dinámicas, no se listan aquí: se navegan desde el
    /// sidebar o la paleta de comandos (⌘K). Los atajos (⌘1–⌘7, ⌘0) cubren los destinos
    /// más usados sin pisar ⌘N/⌘⇧N.
    static let goToTargets: [(title: String, target: NavTarget, shortcut: Character?)] = [
        ("Todos", .all, "1"),
        ("Favoritos", .favorites, "2"),
        ("Cola de lectura", .readingQueue, "3"),
        ("Sin clasificar", .unsorted, "4"),
        ("Resaltados", .highlights, "5"),
        ("X", .x, "6"),
        ("Bandeja", .inbox, "7"),
        ("Asistente IA", .ai, "8"),
        ("Conexiones", .connections, "9"),
        ("Descubrir", .discover, "0"),
        ("Hugging Face", .huggingFace, nil),
        ("Civitai", .civitai, nil),
        ("Sesiones", .sessions, nil),
        ("Proyectos", .projects, nil),
        ("Reglas", .rules, nil),
        ("Estadísticas", .stats, nil),
        ("Papelera", .trash, nil),
    ]

    var body: some Commands {
        // Deshacer / Rehacer (⌘Z / ⇧⌘Z) en el menú Edición. Si el foco es un campo de texto,
        // deshace SU edición (comportamiento estándar de macOS); si no, la ventana deshace la
        // última operación del modelo (borrar/mover/editar enlaces).
        CommandGroup(replacing: .undoRedo) {
            Button("Deshacer") { performUndo() }
                .keyboardShortcut("z", modifiers: .command)
            Button("Rehacer") { performRedo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .newItem) {
            Button("Nuevo enlace") {
                NotificationCenter.default.post(name: .stacklumeNewLink, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
            Button("Nueva colección") {
                NotificationCenter.default.post(name: .stacklumeNewCollection, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Pegar enlaces") {
                NotificationCenter.default.post(name: .stacklumePasteLinks, object: nil)
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Guardado rápido en la barra") {
                MenuBarController.shared.showQuickSave()
            }
            Button("Continuar en la barra") {
                MenuBarController.shared.continueInMenuBar()
            }
            Divider()
            Button("Importar pestañas abiertas…") {
                NotificationCenter.default.post(name: .stacklumeImportOpenTabs, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
        CommandGroup(after: .appInfo) {
            Button("Buscar actualizaciones…") {
                StacklumeUpdater.shared.checkForUpdates()
            }
        }
        // Paleta de comandos ⌘K (búsqueda global + navegación rápida + acciones).
        // Se coloca junto a las acciones de barra lateral para que aparezca como una
        // entrada de menú estándar de macOS sin pisar otros grupos.
        CommandGroup(after: .sidebar) {
            Button("Buscar") {
                NotificationCenter.default.post(name: .stacklumeOpenCommandPalette, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)
            Divider()
            // Modos de vista en el menú «Visualización» del sistema (convención macOS,
            // como Finder ⌘1/2/3). ⌃⌘1–⌃⌘4 para no pisar ⌘1–⌘4 del menú «Ir».
            ForEach(Array(LibraryViewMode.allCases.enumerated()), id: \.element.id) { index, mode in
                Button(mode.label) { setViewMode(mode) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")),
                                      modifiers: [.command, .control])
            }
        }
        CommandMenu("Ir") {
            // Acceso rápido a la paleta también desde el menú «Ir» (descubribilidad). El
            // atajo ⌘K vive en el grupo `.sidebar`; aquí se muestra solo como entrada.
            Button("Buscar…") {
                NotificationCenter.default.post(name: .stacklumeOpenCommandPalette, object: nil)
            }
            Divider()
            // Lista fija de destinos direccionables (los dinámicos —colecciones y
            // etiquetas— no se listan aquí; se navegan desde el sidebar o la paleta).
            ForEach(StacklumeCommands.goToTargets, id: \.target.key) { item in
                let button = Button(item.title) {
                    NotificationCenter.default.post(
                        name: .stacklumeGoToSection,
                        object: item.target.key
                    )
                }
                if let shortcut = item.shortcut {
                    button.keyboardShortcut(KeyEquivalent(shortcut), modifiers: .command)
                } else {
                    button
                }
            }
        }
        // Enlace: acciones sobre el/los enlace(s) seleccionado(s) en la biblioteca. Se
        // comunican por NotificationCenter; la ventana actúa sobre su selección actual.
        CommandMenu("Enlace") {
            Button("Abrir original") { post(.stacklumeOpenSelected) }
                .keyboardShortcut("o", modifiers: .command)
            Button("Vista rápida") { post(.stacklumeQuickLookSelected) }
                .keyboardShortcut("y", modifiers: .command)
            Button("Editar") { post(.stacklumeEditSelected) }
                .keyboardShortcut("e", modifiers: .command)
            Divider()
            Button("Favorito") { post(.stacklumeFavoriteSelected) }
                .keyboardShortcut("d", modifiers: .command)
            Button("Marcar como leído / pendiente") { post(.stacklumeToggleReadSelected) }
                .keyboardShortcut("u", modifiers: .command)
            Button("Archivar / Desarchivar") { post(.stacklumeArchiveSelected) }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
            // «Copiar enlace» con ⌘⇧C (⌘C se reserva para copiar texto en los campos).
            Button("Copiar enlace") { post(.stacklumeCopySelected) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Copiar como Markdown") { post(.stacklumeCopyMarkdownSelected) }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Divider()
            Button("Mover a la papelera") { post(.stacklumeTrashSelected) }
                .keyboardShortcut(.delete, modifiers: .command)
        }
        CommandMenu("Tema") {
            ForEach(Theme.allCases) { theme in
                Button(theme.displayName) {
                    NotificationCenter.default.post(
                        name: .stacklumeSetTheme,
                        object: theme.id
                    )
                }
            }
        }
        // Menú Ayuda nativo: sustituye la entrada por defecto por nuestra ventana de
        // Ayuda (guía de uso + atajos), con el atajo estándar ⌘?.
        CommandGroup(replacing: .help) {
            Button("Ayuda de Stacklume") {
                openWindow(id: HelpView.windowID)
            }
            .keyboardShortcut("?", modifiers: .command)
            if CanonicalXAuditEntry.isArmed {
                Divider()
                Button("Contrastar X91 con el modelo local") {
                    Task { @MainActor in
                        await CanonicalXAuditEntry.runIfArmed()
                    }
                }
                .disabled(!CanonicalXAuditEntry.canRun)
            }
        }
    }

    /// Cambia el modo de vista de la SECCIÓN activa. Escribe la clave global (base por
    /// defecto para secciones aún sin preferencia propia) Y notifica a la lista activa,
    /// que lo aplica a su preferencia por sección (vista recordada por colección).
    private func setViewMode(_ mode: LibraryViewMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: "stacklume.libraryViewMode")
        NotificationCenter.default.post(name: .stacklumeSetViewMode, object: mode.rawValue)
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    /// Deshacer: si hay un campo de texto enfocado, deshace su edición; si no, el modelo.
    private func performUndo() {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView,
           let um = tv.undoManager, um.canUndo {
            um.undo()
        } else {
            post(.stacklumeUndo)
        }
    }

    private func performRedo() {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView,
           let um = tv.undoManager, um.canRedo {
            um.redo()
        } else {
            post(.stacklumeRedo)
        }
    }
}
