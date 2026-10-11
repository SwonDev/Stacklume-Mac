import Testing
import StacklumeCore
import StacklumeMetadata

// `AutoCategorizer` es API pública de StacklumeMetadata. Verifica la organización
// automática «out of the box» por tipo de contenido / plataforma.

@Suite("AutoCategorizer — sugerencia de categoría")
struct AutoCategorizerTests {

    @Test("Código ⇒ «Desarrollo»")
    func codeIsDevelopment() {
        #expect(AutoCategorizer.suggestion(contentType: .code, platform: .github)?.name == "Desarrollo")
    }

    @Test("Vídeo ⇒ «Vídeos»")
    func videoIsVideos() {
        #expect(AutoCategorizer.suggestion(contentType: .video, platform: .youtube)?.name == "Vídeos")
    }

    @Test("App Store afina a «Apps» aunque el tipo sea genérico")
    func appStoreOverrides() {
        #expect(AutoCategorizer.suggestion(contentType: .website, platform: .appStore)?.name == "Apps")
    }

    @Test("Web genérica ⇒ sin sugerencia (nil)")
    func genericWebsiteIsNil() {
        #expect(AutoCategorizer.suggestion(contentType: .website, platform: .generic) == nil)
    }
}
