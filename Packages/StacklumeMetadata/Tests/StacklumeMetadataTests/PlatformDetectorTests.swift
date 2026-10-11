import Testing
import StacklumeCore
@testable import StacklumeMetadata

@Test func detectsYouTube() {
    let result = PlatformDetector.detect("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    #expect(result.platform == .youtube)
    #expect(result.contentType == .video)
    #expect(result.directThumbnailURL?.contains("dQw4w9WgXcQ") == true)
}

@Test func detectsGitHub() {
    let result = PlatformDetector.detect("https://github.com/SwonDev/Stacklume")
    #expect(result.platform == .github)
    #expect(result.contentType == .code)
}

@Test func fallsBackToGeneric() {
    let result = PlatformDetector.detect("https://example.com/page")
    #expect(result.platform == .generic)
}

@Test func parsesOpenGraph() {
    let html = """
    <html><head>
    <title>Página de prueba</title>
    <meta property="og:title" content="Título OG">
    <meta property="og:description" content="Descripción OG">
    <meta property="og:image" content="https://example.com/img.png">
    <meta property="og:site_name" content="Ejemplo">
    </head></html>
    """
    let og = OpenGraphParser.parse(html: html, baseURL: URL(string: "https://example.com"))
    #expect(og.title == "Título OG")
    #expect(og.description == "Descripción OG")
    #expect(og.imageURL == "https://example.com/img.png")
    #expect(og.siteName == "Ejemplo")
}
