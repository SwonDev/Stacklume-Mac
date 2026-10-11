import AppKit
import Foundation

/// Navegadores con diccionario AppleScript capaz de exponer ventanas y pestañas.
/// Firefox y Arc no ofrecen una API pública equivalente y se omiten deliberadamente.
enum ScriptableBrowser: String, CaseIterable, Identifiable, Sendable {
    case safari
    case brave
    case chrome
    case edge
    case vivaldi
    case opera

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .safari: "Safari"
        case .brave: "Brave"
        case .chrome: "Google Chrome"
        case .edge: "Microsoft Edge"
        case .vivaldi: "Vivaldi"
        case .opera: "Opera"
        }
    }

    var applicationName: String {
        switch self {
        case .safari: "Safari"
        case .brave: "Brave Browser"
        case .chrome: "Google Chrome"
        case .edge: "Microsoft Edge"
        case .vivaldi: "Vivaldi"
        case .opera: "Opera"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .brave: "com.brave.Browser"
        case .chrome: "com.google.Chrome"
        case .edge: "com.microsoft.edgemac"
        case .vivaldi: "com.vivaldi.Vivaldi"
        case .opera: "com.operasoftware.Opera"
        }
    }

    var icon: String { self == .safari ? "safari.fill" : "globe" }

    fileprivate var javaScript: String {
        if self == .safari {
            return """
            const app = Application(\"Safari\");
            const rows = [];
            const maxTabs = \(OpenBrowserTabParser.maximumTabCount);
            const windows = app.windows();
            outer:
            for (let wi = 0; wi < windows.length; wi++) {
                const tabs = windows[wi].tabs();
                for (let ti = 0; ti < tabs.length; ti++) {
                    if (rows.length >= maxTabs) break outer;
                    const tab = tabs[ti];
                    rows.push({
                        title: String(tab.name()).slice(0, \(OpenBrowserTabParser.maximumTitleLength)),
                        url: String(tab.url()).slice(0, \(OpenBrowserTabParser.maximumURLLength)),
                        windowIndex: wi + 1,
                        tabIndex: ti + 1,
                        isActive: Boolean(tab.visible())
                    });
                }
            }
            JSON.stringify(rows);
            """
        }

        return """
        const app = Application(\"\(applicationName)\");
        const rows = [];
        const maxTabs = \(OpenBrowserTabParser.maximumTabCount);
        const windows = app.windows();
        outer:
        for (let wi = 0; wi < windows.length; wi++) {
            const tabs = windows[wi].tabs();
            const activeIndex = Number(windows[wi].activeTabIndex());
            for (let ti = 0; ti < tabs.length; ti++) {
                if (rows.length >= maxTabs) break outer;
                const tab = tabs[ti];
                rows.push({
                    title: String(tab.title()).slice(0, \(OpenBrowserTabParser.maximumTitleLength)),
                    url: String(tab.url()).slice(0, \(OpenBrowserTabParser.maximumURLLength)),
                    windowIndex: wi + 1,
                    tabIndex: ti + 1,
                    isActive: activeIndex === ti + 1
                });
            }
        }
        JSON.stringify(rows);
        """
    }
}

struct BrowserTabLoadFailure: Identifiable, Sendable {
    let browserName: String
    let message: String
    var id: String { browserName }
}

struct BrowserTabLoadReport: Sendable {
    let tabs: [OpenBrowserTab]
    let failures: [BrowserTabLoadFailure]
    let runningBrowserNames: [String]
}

/// Carga pestañas sin activar ni lanzar navegadores. La consulta se ejecuta fuera del actor
/// principal porque `osascript` puede esperar a que el usuario responda al permiso de macOS.
enum OpenBrowserTabsLoader {
    private enum ScriptResult: Sendable {
        case success(Data)
        case failure(String)
    }

    @MainActor
    static func load() async -> BrowserTabLoadReport {
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let browsers = ScriptableBrowser.allCases.filter { runningIDs.contains($0.bundleIdentifier) }
        var tabs: [OpenBrowserTab] = []
        var failures: [BrowserTabLoadFailure] = []

        for browser in browsers {
            let result = await Task.detached(priority: .userInitiated) {
                runScript(for: browser)
            }.value
            switch result {
            case .success(let data):
                do {
                    tabs.append(contentsOf: try OpenBrowserTabParser.decode(
                        data,
                        browserID: browser.id,
                        browserName: browser.displayName,
                        browserIcon: browser.icon
                    ))
                } catch {
                    failures.append(BrowserTabLoadFailure(
                        browserName: browser.displayName,
                        message: "El navegador devolvió una respuesta que no se pudo leer."
                    ))
                }
            case .failure(let message):
                failures.append(BrowserTabLoadFailure(
                    browserName: browser.displayName,
                    message: message
                ))
            }
        }

        return BrowserTabLoadReport(
            tabs: OpenBrowserTabParser.deduplicated(tabs),
            failures: failures,
            runningBrowserNames: browsers.map(\.displayName)
        )
    }

    nonisolated private static func runScript(for browser: ScriptableBrowser) -> ScriptResult {
        let process = Process()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Stacklume-BrowserTabs-\(UUID().uuidString)", isDirectory: true)
        let outputURL = directory.appendingPathComponent("output.json")
        let errorURL = directory.appendingPathComponent("error.txt")

        let outputHandle: FileHandle
        let errorHandle: FileHandle
        do {
            try PrivateFileIO.ensureDirectory(directory)
            try PrivateFileIO.write(Data(), to: outputURL)
            try PrivateFileIO.write(Data(), to: errorURL)
            outputHandle = try FileHandle(forWritingTo: outputURL)
            errorHandle = try FileHandle(forWritingTo: errorURL)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return .failure("No se pudo preparar la automatización del navegador.")
        }
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
            try? FileManager.default.removeItem(at: directory)
        }

        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", browser.javaScript]
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        do {
            try process.run()
        } catch {
            return .failure("No se pudo iniciar la automatización del navegador.")
        }

        process.waitUntilExit()
        try? outputHandle.synchronize()
        try? errorHandle.synchronize()

        let data: Data
        let errorData: Data
        do {
            data = try BoundedFileReader.read(
                outputURL,
                maximumBytes: OpenBrowserTabParser.maximumPayloadBytes
            )
            errorData = try BoundedFileReader.read(errorURL, maximumBytes: 256 * 1_024)
        } catch BoundedFileReadError.tooLarge {
            return .failure("El navegador devolvió demasiadas pestañas o datos para importarlos con seguridad.")
        } catch {
            return .failure("No se pudo leer la respuesta del navegador.")
        }

        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errorData, as: UTF8.self).lowercased()
            if detail.contains("not authorized") || detail.contains("no autorizado")
                || detail.contains("-1743") {
                return .failure("Autoriza Stacklume en Ajustes del Sistema › Privacidad y seguridad › Automatización.")
            }
            return .failure("No se pudieron leer sus pestañas. Comprueba que el navegador siga abierto.")
        }
        return .success(data)
    }
}
