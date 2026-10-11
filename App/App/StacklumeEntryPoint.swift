import SwiftUI

/// Selecciona la frontera de arranque antes de crear cualquiera de las dos apps o sus delegados.
@main
@MainActor
enum StacklumeEntryPoint {
    static func main() {
        do {
            if let scope = try NativeUIQAConfiguration.parse(
                environment: ProcessInfo.processInfo.environment, arguments: ProcessInfo.processInfo.arguments) {
                try NativeUIQAConfiguration.requireCanonicalBundle()
                try NativeUIQAConfiguration.writeReport(scope, phase: "before")
                NativeUIQAApp.launch(scope)
            } else {
                StacklumeApp.main()
            }
        } catch {
            NativeUIQAConfiguration.stop(error)
        }
    }
}
