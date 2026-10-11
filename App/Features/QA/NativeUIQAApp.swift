import SwiftUI
import SwiftData
import StacklumeCore
import Darwin

/// Única persistencia permitida para el ensayo: el modelo real de preferencias, sin disco ni CloudKit.
@MainActor
enum NativeUIQAModel {
    enum Failure: Error { case nonMemoryConfiguration }

    static func makeContainer() throws -> ModelContainer {
        let schema = Schema([AppSettings.self])
        let configuration = ModelConfiguration("NativeUIQA", schema: schema, isStoredInMemoryOnly: true,
                                               groupContainer: .none, cloudKitDatabase: .none)
        guard configuration.isStoredInMemoryOnly else { throw Failure.nonMemoryConfiguration }
        let container = try ModelContainer(for: schema, configurations: [configuration])
        guard !container.configurations.isEmpty,
              container.configurations.allSatisfy(\.isStoredInMemoryOnly) else { throw Failure.nonMemoryConfiguration }
        container.mainContext.insert(AppSettings())
        try container.mainContext.save()
        return container
    }
}

@MainActor
private enum NativeUIQABootstrap {
    static var scope: NativeUIQAConfiguration.Scope?

    static func requireScope() -> NativeUIQAConfiguration.Scope {
        guard let scope else { NativeUIQAConfiguration.stop(NativeUIQAConfiguration.Failure.incompleteOptIn) }
        return scope
    }
}

/// App alternativa dentro del ejecutable canónico; no instancia el ciclo ni delegado del producto.
struct NativeUIQAApp: App {
    private let scope: NativeUIQAConfiguration.Scope
    private let container: ModelContainer
    @NSApplicationDelegateAdaptor(NativeUIQAAppDelegate.self) private var delegate

    init() {
        let scope = NativeUIQABootstrap.requireScope()
        do {
            if let environment = try NativeUIQAConfiguration.scrollEnvironment(scope, environment: ProcessInfo.processInfo.environment) {
                ScrollDiagnostics.configure(environment: environment)
                guard ScrollDiagnostics.observation?.observes(.chat) == true else {
                    throw NativeUIQAConfiguration.Failure.invalidScrollObservation
                }
            }
            let container = try NativeUIQAModel.makeContainer()
            try NativeUIQAConfiguration.writeReport(scope, phase: "ready", values: [
                "model": "AppSettings", "allConfigurationsInMemory": true,
                "normalAppCreated": false, "normalDelegateCreated": false
            ])
            self.scope = scope
            self.container = container
        } catch {
            NativeUIQAConfiguration.stop(error)
        }
    }

    @MainActor static func launch(_ scope: NativeUIQAConfiguration.Scope) {
        NativeUIQABootstrap.scope = scope
        Self.main()
    }

    var body: some Scene {
        Window("Ensayo nativo de interfaz · Stacklume", id: "native-ui-qa") {
            NativeUIQAView(scope: scope, container: container)
        }
        .restorationBehavior(.disabled)
        .defaultSize(width: 1080, height: 840)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
private final class NativeUIQAAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        do {
            try NativeUIQAConfiguration.writeReport(NativeUIQABootstrap.requireScope(), phase: "closed",
                values: ["normalServicesStarted": false, "normalStoresFlushed": false])
        } catch {
            NativeUIQAConfiguration.stop(error)
        }
        _exit(0)
    }
}
