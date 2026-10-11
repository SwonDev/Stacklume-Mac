import Foundation

/// Una apertura manual siempre muestra la biblioteca; el login solo inicia la barra.
enum StacklumeLaunchPolicy {
    /// Códigos Apple Event del SDK: oapp, prdt y lgit. Foundation mantiene esta
    /// frontera autocontenida para probar el evento sin ejecutar la aplicación.
    static func isLoginEvent(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventID == 0x6F617070 else { return false }
        return event.paramDescriptor(forKeyword: 0x70726474)?.enumCodeValue == 0x6C676974
            || event.paramDescriptor(forKeyword: 0x6C676974) != nil
    }
    static func startsInMenuBar(arguments: [String], loginEvent: Bool) -> Bool {
        loginEvent || arguments.contains("--menu-bar")
    }
}
