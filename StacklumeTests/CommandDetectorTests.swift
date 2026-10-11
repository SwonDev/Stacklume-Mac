import Testing
import StacklumeMetadata

// `CommandDetector` es API pública de StacklumeMetadata (paquete dependencia del target
// de tests). Cubre la detección de comandos de instalación y la limpieza de versiones.

@Suite("CommandDetector — comandos de instalación")
struct CommandDetectorTests {

    @Test("npm i ⇒ paquete + gestor")
    func npm() {
        let info = CommandDetector.detect("npm i zod")
        #expect(info?.packageName == "zod")
        #expect(info?.manager == "npm")
    }

    @Test("pip install (con flags) ⇒ requests")
    func pip() {
        #expect(CommandDetector.detect("pip install requests")?.manager == "pip")
        #expect(CommandDetector.detect("pip3 install -U requests")?.packageName == "requests")
    }

    @Test("Quita @version final pero conserva @scope")
    func stripsVersionKeepsScope() {
        #expect(CommandDetector.detect("npm i streamdown@1.0.0")?.packageName == "streamdown")
        #expect(CommandDetector.detect("npm i @types/node@20")?.packageName == "@types/node")
    }

    @Test("brew y cargo")
    func brewCargo() {
        #expect(CommandDetector.detect("brew install wget")?.manager == "brew")
        #expect(CommandDetector.detect("cargo add serde")?.packageName == "serde")
    }

    @Test("Una URL o texto cualquiera NO es un comando ⇒ nil")
    func urlIsNil() {
        #expect(CommandDetector.detect("https://github.com/x/y") == nil)
        #expect(CommandDetector.detect("texto cualquiera") == nil)
    }
}
