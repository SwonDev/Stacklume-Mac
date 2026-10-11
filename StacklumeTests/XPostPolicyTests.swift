import Foundation
import Testing

@Suite("Publicaciones curadas para X")
struct XPostPolicyTests {
    private let myGoSource = "Desktop apps in Go. A web frontend or native UI in Go. The TypeScript client is generated from your Go code. Any web stack, in the webview the OS already has: WKWebView, WebKitGTK, WebView2. No browser bundled."

    private let fetchedMyGoSource = "MyGo — Desktop apps in Go, with a web frontend from \"./mygo\" ; // generated document.body.textContent = await Greeter. greet ( \"Ada\" ); ./mygo is generated from main.go, with the types of your structs and the docs of your methods. Any web stack, in the webview the OS already has: WKWebView, WebKitGTK, WebView2. No browser bundled. Interfaces written in Go alone and drawn on the GPU: flexbox and grid layout, widgets, text editing, screen reader support. No webview at all. Pages call bound Go services, stream values through channels and get typed events. The TypeScript client is generated from your Go code. Windows, menus, tray, dialogs, notifications, global shortcuts, deep links, file associations and more, for windows of both kinds. Build for every platform from any machine. App bundles and disk images, Windows installers, Debian packages, code signing, notarization and signed auto-updates. Web frontends Any web stack, in the webview the OS already has: WKWebView, WebKitGTK, WebView2. No browser bundled. Native UI Interfaces written in Go alone and drawn on the GPU: flexbox and grid layout, widgets, text editing, screen reader support. No webview at all. Typed IPC Pages call bound Go services, stream values through channels and get typed events. The TypeScript client is generated from your Go code. Desktop APIs Windows, menus, tray, dialogs, notifications, global shortcuts, deep links, file associations and more, for windows of both kinds. Pure Go, no cgo Build for every platform from any machine. Ready to ship App bundles and disk images, Windows installers, Debian packages, code signing, notarization and signed auto-updates."

    private func myGoContext() throws -> XPostCopyPolicy.GenerationContext {
        try XPostCopyPolicy.generationContext(source: myGoSource, tone: .technical)
    }

    private func responseJSON(_ copy: XPostGeneratedCopy) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["gancho": copy.gancho, "utilidad": copy.utilidad]), as: UTF8.self)
    }

    private var sdkSource: String {
        String(repeating: "El SDK Aster conecta los datos de una aplicación mediante una interfaz pública. El cliente TypeScript conserva los tipos de los mensajes y admite texto Unicode como «mañana» o «quién». ", count: 4)
        + String(repeating: "Ejemplo de código: const APIs = cliente.enviar(\"Ada\"); // WebView2 muestra una interfaz Go-native. ", count: 4)
    }

    @Test("La cuenta X procede del enlace declarado, nunca del nombre de GitHub")
    func authorAccountUsesOfficialLink() throws {
        let resource = try #require(URL(string: "https://mygo.egoist.dev"))
        let profile = try #require(URL(string: "https://github.com/egoist"))
        let html = #"<div class="vcard-details"><a rel="nofollow me" href="https://twitter.com/localhost_5173">@localhost_5173</a></div><article><a href="https://x.com/sponsor">Gracias al patrocinador</a></article>"#
        let evidence = XPostAuthorPolicy.evidence(in: html, documentURL: profile, resourceURL: resource, kind: .creatorProfile, chain: [resource, profile])
        #expect(evidence.count == 1)
        #expect(evidence.first?.handle == "localhost_5173")
        #expect(evidence.first?.sourceURL == profile.absoluteString)
        #expect(XPostAuthorPolicy.profileHandle(URL(string: "https://x.com/egoist/status/123")!) == nil)
        #expect(XPostAuthorPolicy.profileHandle(URL(string: "https://x.com/intent/tweet?text=hola")!) == nil)
        #expect(XPostAuthorPolicy.profileHandle(URL(string: "https://x.com.ejemplo.org/egoist")!) == nil)
        #expect(XPostAuthorPolicy.profileHandle(URL(string: "https://x.com/usuario_demasiado_largo")!) == nil)
    }

    @Test("Sin enlace visible o con dos cuentas de autor no se elige una arroba")
    func ambiguousAuthorDoesNotGuess() throws {
        let source = try #require(URL(string: "https://example.org/programa"))
        let twoAuthors = #"<a rel="author" href="https://twitter.com/alice_dev">Alice</a><a rel="author" href="https://x.com/bob_dev">Bob</a>"#
        let candidates = XPostAuthorPolicy.evidence(in: twoAuthors, documentURL: source, resourceURL: source, kind: .resourceWebsite, chain: [source])
        #expect(candidates.count == 2)
        #expect(XPostAuthorPolicy.uniqueEvidence(candidates) == nil)
        let missing = #"<meta name="twitter:creator" content="@egoist"><p>Creado por egoist. Contacto @egoist.</p><script><a rel="author" href="https://x.com/egoist">Autor</a></script>"#
        #expect(XPostAuthorPolicy.evidence(in: missing, documentURL: source, resourceURL: source, kind: .resourceWebsite, chain: [source]).isEmpty)
        let repository = try #require(URL(string: "https://github.com/egoist/mygo"))
        let owner = #"<header><a rel="author" href="/egoist">egoist</a></header><article><p>README sin cuenta X.</p></article><footer><a href="https://x.com/github">Twitter</a></footer>"#
        #expect(XPostAuthorPolicy.evidence(in: owner, documentURL: repository, resourceURL: source, kind: .repository, chain: [source, repository]).isEmpty)
        #expect(XPostAuthorPolicy.nextDocuments(in: owner, documentURL: repository, kind: .repository).first?.url.absoluteString == "https://github.com/egoist")
        let currentGitHub = #"<nav><a data-component="Breadcrumbs.Item" href="/egoist"><span>egoist</span></a><a data-component="Breadcrumbs.Item" href="/egoist/mygo">mygo</a></nav>"#
        #expect(XPostAuthorPolicy.nextDocuments(in: currentGitHub, documentURL: repository, kind: .repository).first?.url.absoluteString == "https://github.com/egoist")
    }

    @Test("Los créditos de dependencias no atribuyen el repositorio a un tercero")
    func dependencyCreditsDoNotVerifyAuthor() throws {
        let resource = try #require(URL(string: "https://github.com/egoist/mygo"))
        let profile = try #require(URL(string: "https://github.com/egoist"))
        let credits = #"<article><h2>Third-party credits</h2><p>Author: <a href="https://x.com/dependency_dev">Dependency Dev</a> of the parser dependency.</p></article>"#
        let repositoryEvidence = XPostAuthorPolicy.evidence(in: credits, documentURL: resource, resourceURL: resource, kind: .repository, chain: [resource])
        #expect(repositoryEvidence.isEmpty)
        #expect(XPostAuthorPolicy.uniqueEvidence(repositoryEvidence) == nil)
        let ownerProfile = #"<div class="vcard-details"><a rel="nofollow me" href="https://twitter.com/localhost_5173">@localhost_5173</a></div><article><h2>Contributors</h2><a rel="me" href="https://x.com/dependency_dev">Dependency Dev</a></article>"#
        let identity = XPostAuthorPolicy.evidence(in: ownerProfile, documentURL: profile, resourceURL: resource, kind: .creatorProfile, chain: [resource, profile])
        #expect(identity.map(\.handle) == ["localhost_5173"])
        let contributor = #"<p>Author: <a rel="author" href="https://x.com/dependency_dev">Dependency Dev</a></p>"#
        #expect(XPostAuthorPolicy.evidence(in: contributor, documentURL: profile, resourceURL: resource, kind: .creatorProfile, chain: [resource, profile]).isEmpty)
    }

    @Test("Los autores y repositorios del tema no atribuyen la web del recurso")
    func websiteCreditsDoNotVerifyAuthor() throws {
        let resource = try #require(URL(string: "https://mygo.egoist.dev"))
        let themeAuthor = #"<footer>Theme by <a href="https://x.com/theme_dev">Theme Dev</a></footer>"#
        #expect(XPostAuthorPolicy.evidence(in: themeAuthor, documentURL: resource, resourceURL: resource, kind: .resourceWebsite, chain: [resource]).isEmpty)
        let themeSource = #"<footer>Theme source: <a href="https://github.com/theme_dev/theme">Source code</a></footer>"#
        #expect(XPostAuthorPolicy.nextDocuments(in: themeSource, documentURL: resource, kind: .resourceWebsite).isEmpty)
        let dependency = #"<section><h2>Dependencias y créditos</h2><p>Autor: <a rel="me" href="https://x.com/parser_dev">Parser Dev</a></p><a rel="author" href="https://github.com/parser_dev">Autor de la dependencia</a></section>"#
        #expect(XPostAuthorPolicy.evidence(in: dependency, documentURL: resource, resourceURL: resource, kind: .resourceWebsite, chain: [resource]).isEmpty)
        #expect(XPostAuthorPolicy.nextDocuments(in: dependency, documentURL: resource, kind: .resourceWebsite).isEmpty)
        let unrelated = #"<main><a href="https://github.com/theme_dev/theme">Source code</a></main>"#
        #expect(XPostAuthorPolicy.nextDocuments(in: unrelated, documentURL: resource, kind: .resourceWebsite).isEmpty)
        let ownSource = #"<header><a href="https://github.com/egoist/mygo" aria-label="GitHub">GitHub</a></header>"#
        #expect(XPostAuthorPolicy.nextDocuments(in: ownSource, documentURL: resource, kind: .resourceWebsite).map(\.url.absoluteString) == ["https://github.com/egoist/mygo"])
        let ownAuthor = #"<footer>Creado por <a rel="me" href="https://x.com/localhost_5173">@localhost_5173</a></footer>"#
        #expect(XPostAuthorPolicy.evidence(in: ownAuthor, documentURL: resource, resourceURL: resource, kind: .resourceWebsite, chain: [resource]).map(\.handle) == ["localhost_5173"])
    }

    @Test("Los créditos extensos se excluyen como sección completa")
    func longCreditSectionsDoNotVerifyAuthor() throws {
        let resource = try #require(URL(string: "https://mygo.egoist.dev"))
        let padding = String(repeating: "Detalles técnicos de la biblioteca utilizada. ", count: 150)
        let credits = #"<section id="credits"><h2>Third-party credits</h2><div>"# + padding
            + #"<p>Author: <a href="https://x.com/parser_dev">Parser Dev</a></p><a href="https://github.com/parser_dev/mygo">Source code</a>"#
            + padding + "</div></section>"
        #expect(XPostAuthorPolicy.evidence(in: credits, documentURL: resource, resourceURL: resource, kind: .resourceWebsite, chain: [resource]).isEmpty)
        #expect(XPostAuthorPolicy.nextDocuments(in: credits, documentURL: resource, kind: .resourceWebsite).isEmpty)
        let ownSource = #"<header><a href="https://github.com/egoist/mygo" aria-label="GitHub">GitHub</a></header>"#
        let ownAuthor = #"<footer><a rel="me" href="https://x.com/localhost_5173">@localhost_5173</a></footer>"#
        let mixed = ownSource + credits + ownAuthor
        #expect(XPostAuthorPolicy.evidence(in: mixed, documentURL: resource, resourceURL: resource, kind: .resourceWebsite, chain: [resource]).map(\.handle) == ["localhost_5173"])
        #expect(XPostAuthorPolicy.nextDocuments(in: mixed, documentURL: resource, kind: .resourceWebsite).map(\.url.absoluteString) == ["https://github.com/egoist/mygo"])
        let headingOnly = credits.replacingOccurrences(of: #" id="credits""#, with: "")
        #expect(XPostAuthorPolicy.evidence(in: headingOnly, documentURL: resource, resourceURL: resource, kind: .resourceWebsite, chain: [resource]).isEmpty)
        #expect(XPostAuthorPolicy.nextDocuments(in: headingOnly, documentURL: resource, kind: .resourceWebsite).isEmpty)
    }

    @Test("Un wrapper de título no reduce el alcance de los créditos")
    func wrappedCreditHeadingDoesNotVerifyAuthor() throws {
        let resource = try #require(URL(string: "https://mygo.egoist.dev"))
        let heading = #"<div class="heading-wrapper"><h2>Third-party credits</h2></div>"#
        let dependency = #"<p>Author: <a href="https://x.com/parser_dev">Parser Dev</a></p><a href="https://github.com/parser_dev/mygo">Source code</a>"#
        let credits = #"<div class="prose">"# + heading + dependency + "</div>"
        #expect(XPostAuthorPolicy.evidence(in: credits, documentURL: resource, resourceURL: resource, kind: .resourceWebsite, chain: [resource]).isEmpty)
        #expect(XPostAuthorPolicy.nextDocuments(in: credits, documentURL: resource, kind: .resourceWebsite).isEmpty)
        let ownAuthor = #"<p>Creado por <a rel="me" href="https://x.com/localhost_5173">@localhost_5173</a></p>"#
        let nextHeading = #"<div class="heading-wrapper"><h2>Sobre MyGo</h2></div>"#
        let ownSource = #"<a href="https://github.com/egoist/mygo" aria-label="GitHub">GitHub</a>"#
        let bounded = #"<div class="prose">"# + ownAuthor + heading + dependency + nextHeading + ownAuthor + ownSource + "</div>"
        #expect(XPostAuthorPolicy.evidence(in: bounded, documentURL: resource, resourceURL: resource, kind: .resourceWebsite, chain: [resource]).map(\.handle) == ["localhost_5173"])
        #expect(XPostAuthorPolicy.nextDocuments(in: bounded, documentURL: resource, kind: .resourceWebsite).map(\.url.absoluteString) == ["https://github.com/egoist/mygo"])
        let boundedSection = "<section>" + ownAuthor + heading + dependency + nextHeading + ownAuthor + ownSource + "</section>"
        #expect(XPostAuthorPolicy.evidence(in: boundedSection, documentURL: resource, resourceURL: resource, kind: .resourceWebsite, chain: [resource]).map(\.handle) == ["localhost_5173"])
        #expect(XPostAuthorPolicy.nextDocuments(in: boundedSection, documentURL: resource, kind: .resourceWebsite).map(\.url.absoluteString) == ["https://github.com/egoist/mygo"])
        let nestedHeading = heading.replacingOccurrences(of: "<h2>", with: "<div><h2>").replacingOccurrences(of: "</h2>", with: "</h2></div>")
        let nested = credits.replacingOccurrences(of: heading, with: nestedHeading)
        #expect(XPostAuthorPolicy.evidence(in: nested, documentURL: resource, resourceURL: resource, kind: .resourceWebsite, chain: [resource]).isEmpty)
    }

    @Test("El tipo de wrapper no delimita los créditos", arguments: ["div", "section", "article", "aside", "footer", "section-article-aside"])
    func creditHeadingWrappersAreTransparent(wrapper: String) throws {
        let resource = try #require(URL(string: "https://mygo.egoist.dev"))
        let tags = wrapper.split(separator: "-").map(String.init)
        let opening = tags.map { "<" + $0 + #" class="heading-wrapper">"# }.joined()
        let closing = tags.reversed().map { "</" + $0 + ">" }.joined()
        let heading = opening + "<h2>Third-party credits</h2>" + closing
        let dependency = #"<p>Author: <a href="https://x.com/parser_dev">Parser Dev</a></p><a href="https://github.com/parser_dev/mygo">Source code</a>"#
        let unbounded = #"<div class="prose">"# + heading + dependency + "</div>"
        #expect(XPostAuthorPolicy.evidence(in: unbounded, documentURL: resource, resourceURL: resource, kind: .resourceWebsite, chain: [resource]).isEmpty)
        #expect(XPostAuthorPolicy.nextDocuments(in: unbounded, documentURL: resource, kind: .resourceWebsite).isEmpty)
        let marked = unbounded.replacingOccurrences(of: #"class="heading-wrapper""#, with: #"id="credits" class="heading-wrapper""#)
        #expect(XPostAuthorPolicy.evidence(in: marked, documentURL: resource, resourceURL: resource, kind: .resourceWebsite, chain: [resource]).isEmpty)
        #expect(XPostAuthorPolicy.nextDocuments(in: marked, documentURL: resource, kind: .resourceWebsite).isEmpty)
        let ownAuthor = #"<p>Creado por <a rel="me" href="https://x.com/localhost_5173">@localhost_5173</a></p>"#
        let nextHeading = opening + "<h2>Sobre MyGo</h2>" + closing
        let ownSource = #"<a href="https://github.com/egoist/mygo" aria-label="GitHub">GitHub</a>"#
        let bounded = #"<div class="prose">"# + ownAuthor + heading + "<h3>Detalles de la biblioteca</h3>" + dependency + nextHeading + ownAuthor + ownSource + "</div>"
        #expect(XPostAuthorPolicy.evidence(in: bounded, documentURL: resource, resourceURL: resource, kind: .resourceWebsite, chain: [resource]).map(\.handle) == ["localhost_5173"])
        #expect(XPostAuthorPolicy.nextDocuments(in: bounded, documentURL: resource, kind: .resourceWebsite).map(\.url.absoluteString) == ["https://github.com/egoist/mygo"])
    }

    @Test("Los rótulos de créditos conservan el alcance aunque no sean encabezados", arguments: ["p", "p-strong", "p-span", "div-p-strong", "section-p-span", "strong", "span", "p-a", "section-p-a"])
    func creditLabelsWithoutHeadingsDoNotVerifyAuthor(marker: String) throws {
        let resource = try #require(URL(string: "https://mygo.egoist.dev"))
        let tags = marker.split(separator: "-").map(String.init)
        let label = tags.map { $0 == "a" ? "<a href=\"#credits\">" : "<" + $0 + ">" }.joined() + "Third-party credits"
            + tags.reversed().map { "</" + $0 + ">" }.joined()
        let dependency = #"<p>Author: <a href="https://x.com/parser_dev">Parser Dev</a></p><a href="https://github.com/parser_dev/mygo">Source code</a>"#
        let credited = #"<div class="prose">"# + label + dependency + "</div>"
        #expect(XPostAuthorPolicy.evidence(in: credited, documentURL: resource, resourceURL: resource, kind: .resourceWebsite, chain: [resource]).isEmpty)
        #expect(XPostAuthorPolicy.nextDocuments(in: credited, documentURL: resource, kind: .resourceWebsite).isEmpty)
        let ownAuthor = #"<p>Creado por <a rel="me" href="https://x.com/localhost_5173">@localhost_5173</a></p>"#
        let ownSource = #"<header><a href="https://github.com/egoist/mygo" aria-label="GitHub">GitHub</a></header>"#
        let declaredBefore = ownAuthor + ownSource + credited
        #expect(XPostAuthorPolicy.evidence(in: declaredBefore, documentURL: resource, resourceURL: resource, kind: .resourceWebsite, chain: [resource]).map(\.handle) == ["localhost_5173"])
        #expect(XPostAuthorPolicy.nextDocuments(in: declaredBefore, documentURL: resource, kind: .resourceWebsite).map(\.url.absoluteString) == ["https://github.com/egoist/mygo"])
        let profile = try #require(URL(string: "https://github.com/egoist"))
        let official = ownAuthor + "<article>" + credited + "</article>"
        #expect(XPostAuthorPolicy.evidence(in: official, documentURL: profile, resourceURL: resource, kind: .creatorProfile, chain: [resource, profile]).map(\.handle) == ["localhost_5173"])
    }

    @Test("Las etiquetas de navegación no anuncian créditos en el contenido")
    func navigationLabelsDoNotHideResourceIdentity() throws {
        let resource = try #require(URL(string: "https://mygo.egoist.dev"))
        let profile = try #require(URL(string: "https://github.com/egoist"))
        let navigation = #"<nav><a href="https://github.com/sponsors"><span>Sponsors</span></a><button><strong>Themes</strong></button><a href="/credits">Third-party credits</a></nav>"#
        let ownAuthor = #"<p>Creado por <a rel="me" href="https://x.com/localhost_5173">@localhost_5173</a></p>"#
        let ownSource = #"<a href="https://github.com/egoist/mygo" aria-label="GitHub">GitHub</a>"#
        let website = navigation + ownAuthor + ownSource
        #expect(XPostAuthorPolicy.evidence(in: website, documentURL: resource, resourceURL: resource, kind: .resourceWebsite, chain: [resource]).map(\.handle) == ["localhost_5173"])
        #expect(XPostAuthorPolicy.nextDocuments(in: website, documentURL: resource, kind: .resourceWebsite).map(\.url.absoluteString) == ["https://github.com/egoist/mygo"])
        #expect(XPostAuthorPolicy.evidence(in: navigation + ownAuthor, documentURL: profile, resourceURL: resource, kind: .creatorProfile, chain: [resource, profile]).map(\.handle) == ["localhost_5173"])
    }

    @Test("Las cuentas que se describen como créditos se excluyen solo localmente", arguments: ["Theme author", "Dependency author", "Sponsor author", "Autor de la dependencia", "Autor del tema"])
    func selfDescribedCreditLinksDoNotVerifyAuthor(description: String) throws {
        let resource = try #require(URL(string: "https://mygo.egoist.dev"))
        let ownAuthor = #"<p>Creado por <a rel="me" href="https://x.com/localhost_5173">@localhost_5173</a></p>"#
        let ownSource = #"<a href="https://github.com/egoist/mygo" aria-label="GitHub">GitHub</a>"#
        for placement in ["text", "aria-label", "title", "class", "id"] {
            let attribute = placement == "text" ? "" : " " + placement + "=\"" + description + "\""
            let label = placement == "text" ? description : "Autor"
            let creditAccount = "<footer><a rel=\"author\"" + attribute + " href=\"https://x.com/parser_dev\">" + label + "</a></footer>"
            let creditProfile = "<footer><a rel=\"author\"" + attribute + " href=\"https://github.com/parser_dev\">" + label + "</a></footer>"
            #expect(XPostAuthorPolicy.evidence(in: creditAccount, documentURL: resource, resourceURL: resource, kind: .resourceWebsite, chain: [resource]).isEmpty)
            #expect(XPostAuthorPolicy.nextDocuments(in: creditProfile, documentURL: resource, kind: .resourceWebsite).isEmpty)
            #expect(XPostAuthorPolicy.evidence(in: creditAccount + ownAuthor, documentURL: resource, resourceURL: resource, kind: .resourceWebsite, chain: [resource]).map(\.handle) == ["localhost_5173"])
            #expect(XPostAuthorPolicy.nextDocuments(in: creditProfile + ownSource, documentURL: resource, kind: .resourceWebsite).map(\.url.absoluteString) == ["https://github.com/egoist/mygo"])
        }
    }

    @Test("Un anuncio enlazado de créditos en el contenido conserva su alcance", arguments: ["a", "a-strong", "a-span", "p-a", "section-a"])
    func linkedCreditAnnouncementDoesNotVerifyAuthor(marker: String) throws {
        let resource = try #require(URL(string: "https://mygo.egoist.dev"))
        let tags = marker.split(separator: "-").map(String.init)
        let label = tags.map { $0 == "a" ? "<a href=\"#credits\">" : "<" + $0 + ">" }.joined() + "Third-party credits"
            + tags.reversed().map { "</" + $0 + ">" }.joined()
        let dependency = #"<p>Author: <a href="https://x.com/parser_dev">Parser Dev</a></p><a href="https://github.com/parser_dev/mygo">Source code</a>"#
        let content = #"<div class="prose">"# + label + dependency + "</div>"
        #expect(XPostAuthorPolicy.evidence(in: content, documentURL: resource, resourceURL: resource, kind: .resourceWebsite, chain: [resource]).isEmpty)
        #expect(XPostAuthorPolicy.nextDocuments(in: content, documentURL: resource, kind: .resourceWebsite).isEmpty)
        let ownAuthor = #"<p>Creado por <a rel="me" href="https://x.com/localhost_5173">@localhost_5173</a></p>"#
        let ownSource = #"<a href="https://github.com/egoist/mygo" aria-label="GitHub">GitHub</a>"#
        let navigation = "<nav>" + label + "</nav>" + ownAuthor + ownSource
        #expect(XPostAuthorPolicy.evidence(in: navigation, documentURL: resource, resourceURL: resource, kind: .resourceWebsite, chain: [resource]).map(\.handle) == ["localhost_5173"])
        #expect(XPostAuthorPolicy.nextDocuments(in: navigation, documentURL: resource, kind: .resourceWebsite).map(\.url.absoluteString) == ["https://github.com/egoist/mygo"])
        if ["a", "a-strong", "a-span"].contains(marker) {
            let bounded = "<h2>" + label + "</h2>" + dependency + "<h2>Sobre MyGo</h2>" + ownAuthor + ownSource
            #expect(XPostAuthorPolicy.evidence(in: bounded, documentURL: resource, resourceURL: resource, kind: .resourceWebsite, chain: [resource]).map(\.handle) == ["localhost_5173"])
            #expect(XPostAuthorPolicy.nextDocuments(in: bounded, documentURL: resource, kind: .resourceWebsite).map(\.url.absoluteString) == ["https://github.com/egoist/mygo"])
        }
    }

    @Test("Los anuncios compuestos de créditos conservan el alcance", arguments: ["Third-party credits and acknowledgements", "Créditos y agradecimientos", "Third-party credits — parser dependency", "Créditos: dependencias y colaboradores", "Credits (third-party libraries)", "Acknowledgements / credits", "Agradecimientos y créditos · 2026", "ACKNOWLEDGEMENTS: fonts, icons, code", "Créditos, licencias y gracias"])
    func compoundCreditAnnouncementsDoNotVerifyAuthor(announcement: String) throws {
        let resource = try #require(URL(string: "https://mygo.egoist.dev"))
        let label = "<a href=\"#credits\">" + announcement + "</a>"
        let dependency = #"<p>Author: <a href="https://x.com/parser_dev">Parser Dev</a></p><a href="https://github.com/parser_dev/mygo">Source code</a>"#
        let content = #"<div class="prose">"# + label + dependency + "</div>"
        #expect(XPostAuthorPolicy.evidence(in: content, documentURL: resource, resourceURL: resource, kind: .resourceWebsite, chain: [resource]).isEmpty)
        #expect(XPostAuthorPolicy.nextDocuments(in: content, documentURL: resource, kind: .resourceWebsite).isEmpty)
        let ownAuthor = #"<p>Creado por <a rel="me" href="https://x.com/localhost_5173">@localhost_5173</a></p>"#
        let ownSource = #"<a href="https://github.com/egoist/mygo" aria-label="GitHub">GitHub</a>"#
        #expect(XPostAuthorPolicy.evidence(in: content + ownAuthor, documentURL: resource, resourceURL: resource, kind: .resourceWebsite, chain: [resource]).isEmpty)
        #expect(XPostAuthorPolicy.nextDocuments(in: content + ownSource, documentURL: resource, kind: .resourceWebsite).isEmpty)
        let navigation = "<nav>" + label + "</nav>" + ownAuthor + ownSource
        #expect(XPostAuthorPolicy.evidence(in: navigation, documentURL: resource, resourceURL: resource, kind: .resourceWebsite, chain: [resource]).map(\.handle) == ["localhost_5173"])
        #expect(XPostAuthorPolicy.nextDocuments(in: navigation, documentURL: resource, kind: .resourceWebsite).map(\.url.absoluteString) == ["https://github.com/egoist/mygo"])
    }

    @Test("Los créditos compuestos por varias etiquetas enlazadas no admiten autores de dependencias")
    func multipleLinkedCreditLabelsDoNotVerifyAuthor() throws {
        let resource = try #require(URL(string: "https://mygo.egoist.dev"))
        let labels = #"<a href="/credits">Créditos</a><span> y </span><a href="/thanks">agradecimientos de terceros</a>"#
        let dependency = #"<p>Author: <a href="https://x.com/parser_dev">Parser Dev</a></p><a href="https://github.com/parser_dev/mygo">Source code</a>"#
        #expect(XPostAuthorPolicy.evidence(in: labels + dependency, documentURL: resource, resourceURL: resource, kind: .resourceWebsite, chain: [resource]).isEmpty)
        #expect(XPostAuthorPolicy.nextDocuments(in: labels + dependency, documentURL: resource, kind: .resourceWebsite).isEmpty)
        let ownAuthor = #"<p>Creado por <a rel="me" href="https://x.com/localhost_5173">@localhost_5173</a></p>"#
        let suffixOnly = #"<a href="/thanks">Agradecimientos por las bibliotecas empleadas</a>"#
        #expect(XPostAuthorPolicy.evidence(in: suffixOnly + dependency + ownAuthor, documentURL: resource, resourceURL: resource, kind: .resourceWebsite, chain: [resource]).isEmpty)
    }

    @Test("La mención reserva caracteres y no duplica una arroba escrita por el autor")
    func verifiedMentionComposition() throws {
        let source = try #require(URL(string: "https://example.org/programa"))
        let generated = XPostPolicy.composition(String(repeating: "Texto útil para crear. ", count: 30), source: source, hashtags: ["Swift"], mention: "localhost_5173")
        #expect(generated.text.contains("\n\n@localhost_5173\n\n#Swift\n\n"))
        #expect(generated.appliedMention == "localhost_5173")
        #expect(XPostPolicy.weightedLength(generated.text) <= 280)
        let authored = "Consulta a @LOCALHOST_5173; este detalle es mío."
        let sameAccount = XPostPolicy.composition(authored, source: source, mention: "localhost_5173")
        #expect(sameAccount.text == authored + "\n\n" + source.absoluteString)
        #expect(sameAccount.appliedMention == nil)
        let removed = XPostPolicy.applyingMention(to: generated.text, source: source, mention: nil, previousApplied: generated.appliedMention)
        #expect(!removed.text.contains("@localhost_5173"))
        #expect(removed.text.contains("#Swift"))
        let manual = XPostPolicy.applyingMention(to: sameAccount.text, source: source, mention: nil, previousApplied: "localhost_5173")
        #expect(manual.text == sameAccount.text)
        let edited = String(repeating: "a", count: 255) + "\n\n" + source.absoluteString
        let appended = XPostPolicy.applyingMention(to: edited, source: source, mention: "localhost_5173", previousApplied: nil)
        #expect(appended.text.hasPrefix(String(repeating: "a", count: 255)))
        #expect(XPostPolicy.weightedLength(appended.text) > 280)
    }

    @Test("La cuenta verificada y la elección persisten sin romper borradores anteriores")
    func authorMentionPersistence() throws {
        let resource = try #require(URL(string: "https://mygo.egoist.dev"))
        let profile = try #require(URL(string: "https://github.com/egoist"))
        let account = try #require(URL(string: "https://twitter.com/localhost_5173"))
        let evidence = try #require(XPostAuthorEvidence(handle: "localhost_5173", profileURL: account, sourceURL: profile, resourceURL: resource, context: "@localhost_5173", chain: [resource, profile]))
        var draft = XPostDraft()
        draft.verifiedAuthor = evidence
        draft.mentionEnabled = false
        draft.acceptGeneratedVariant(tone: .technical, text: "Texto editado.\n\n@localhost_5173\n\n" + resource.absoluteString, hashtags: [], mention: evidence.handle)
        let decoded = try JSONDecoder().decode(XPostDraft.self, from: XPostDraftStore.encodedDraft(draft))
        #expect(decoded == draft)
        #expect(decoded.selectedVariant?.appliedMention == evidence.handle)
        let legacy = try JSONDecoder().decode(XPostDraft.self, from: Data(#"{"text":"Texto de 1.59"}"#.utf8))
        #expect(legacy.mentionEnabled)
        #expect(legacy.verifiedAuthor == nil)
        #expect(legacy.text == "Texto de 1.59")
    }

    @Test("Retirar una mención conserva todas las ediciones y las arrobas del cuerpo")
    func authorChoicePreservesVariantEdits() throws {
        let source = try #require(URL(string: "https://example.org/programa"))
        var draft = XPostDraft()
        draft.acceptGeneratedVariant(tone: .impactful, text: "Gancho editado por mí.\n\n@alice_dev\n\n#Swift\n\n" + source.absoluteString, hashtags: ["Swift"], mention: "alice_dev")
        draft.acceptGeneratedVariant(tone: .technical, text: "Consulta a @alice_dev en esta frase mía.\n\n" + source.absoluteString, hashtags: [], mention: "alice_dev")
        draft.applyMention(nil, source: source)
        #expect(draft.variants.first { $0.tone == .impactful }?.text == "Gancho editado por mí.\n\n#Swift\n\n" + source.absoluteString)
        #expect(draft.text == "Consulta a @alice_dev en esta frase mía.\n\n" + source.absoluteString)
        #expect(draft.variants.allSatisfy { $0.appliedMention == nil })
    }

    @Test("Los enlaces ocultos y atributos de datos no verifican una cuenta")
    func hiddenAuthorLinksAreIgnored() throws {
        let source = try #require(URL(string: "https://example.org/programa"))
        let hidden = #"<div hidden><a rel="me" href="https://x.com/hidden_dev">Autor</a></div><a rel="author" data-href="https://x.com/data_dev">Autor</a>"#
        #expect(XPostAuthorPolicy.evidence(in: hidden, documentURL: source, resourceURL: source, kind: .resourceWebsite, chain: [source]).isEmpty)
    }

    @Test("Solo extrae la publicación estructurada tras el razonamiento")
    func structuredCopyExtraction() throws {
        let output = #"<think>Texto interno que no es una publicación.</think>{"gancho":"Lleva tu código Go al escritorio.","utilidad":"MyGo genera el cliente TypeScript desde tu código Go."}"#
        let copy = try XPostCopyPolicy.extract(output, context: myGoContext())
        #expect(copy.text == "Lleva tu código Go al escritorio. MyGo genera el cliente TypeScript desde tu código Go.")
        #expect(throws: XPostCopyPolicy.CopyError.self) { try XPostCopyPolicy.extract("<think>Salida incompleta", context: myGoContext()) }
        #expect(throws: XPostCopyPolicy.CopyError.self) { try XPostCopyPolicy.extract("Desktop apps in Go, with a web frontend or native UI.", context: myGoContext()) }
    }

    @Test("Rechaza el inglés y las instrucciones observadas en la app")
    func rejectsObservedBadCopies() throws {
        let english = XPostGeneratedCopy(gancho: "Desktop apps in Go, with a web frontend or native UI.", utilidad: "Generated from main.go, using the types and method docs of your Go code.", apoyo: ["Desktop apps in Go."])
        #expect(throws: XPostCopyPolicy.CopyError.wrongLanguage) {
            try XPostCopyPolicy.validate(english, source: myGoSource, language: "es", tone: .impactful, budget: 230, languageAssessment: .init(code: "en", confidence: 0.99, requestedConfidence: 0.001))
        }
        let leak = XPostGeneratedCopy(gancho: "MyGo permite crear aplicaciones de escritorio en Go.", utilidad: "Cada recurso descrito cumple con los requisitos de la fuente y no incluya exámenes ni suposiciones extra.", apoyo: ["Desktop apps in Go."])
        #expect(throws: XPostCopyPolicy.CopyError.instructionLeak) {
            try XPostCopyPolicy.validate(leak, source: myGoSource, language: "es", tone: .educational, budget: 230)
        }
        let nonsense = XPostGeneratedCopy(gancho: "MyGo ofrece trajes de corticontextos.", utilidad: "Permite crear aplicaciones de escritorio en Go.", apoyo: ["Desktop apps in Go."])
        #expect(throws: XPostCopyPolicy.CopyError.spelling(["corticontextos"])) {
            try XPostCopyPolicy.validate(nonsense, source: myGoSource, language: "es", tone: .technical, budget: 230, spellingIssues: ["corticontextos"])
        }
    }

    @Test("Acepta español con términos técnicos y verifica apoyo en el extracto visto")
    func acceptsGroundedSpanish() throws {
        let copy = XPostGeneratedCopy(gancho: "Lleva tu código Go al escritorio.", utilidad: "MyGo genera el cliente TypeScript desde tu código Go.", apoyo: ["Desktop apps in Go.", "The TypeScript client is generated from your Go code."])
        #expect(try XPostCopyPolicy.validate(copy, source: myGoSource, language: "es", tone: .impactful, budget: 230, languageAssessment: .init(code: "pt", confidence: 0.51, requestedConfidence: 0.48), spellingIssues: ["TypeScript"]) == copy.text)
        #expect(throws: XPostCopyPolicy.CopyError.unsupportedEvidence) {
            try XPostCopyPolicy.validate(copy, source: "Desktop apps in Go.", language: "es", tone: .impactful, budget: 230)
        }
        #expect(throws: XPostCopyPolicy.CopyError.wrongTone) {
            try XPostCopyPolicy.validate(copy, source: myGoSource, language: "es", tone: .curiosity, budget: 230)
        }
        #expect(throws: XPostCopyPolicy.CopyError.repeatedVariant) {
            try XPostCopyPolicy.validate(copy, source: myGoSource, language: "es", tone: .impactful, budget: 230, previousTexts: [copy.text])
        }
    }

    @Test("El guion tipográfico conserva solo un compuesto íntegro publicado", arguments: ["-", "‐", "‑"])
    func sourceBackedUnicodeCompound(hyphen: String) throws {
        let word = "Go" + hyphen + "native"
        let copy = XPostGeneratedCopy(gancho: "La herramienta ofrece una interfaz \(word).",
                                     utilidad: "La interfaz se dibuja en la GPU.", apoyo: ["F1"])
        for published in ["The toolkit has a Go-native UI drawn on the GPU.",
                          "The toolkit has a Go‐native UI drawn on the GPU.",
                          "The toolkit has a Go‑native UI drawn on the GPU."] {
            #expect(try XPostCopyPolicy.validate(copy, source: published, language: "es", tone: .technical,
                                               budget: 230, spellingIssues: [word]) == copy.text)
        }
        let actualMyGoExcerpt = "MyGo. Native UI. Interfaces written in Go alone and drawn on the GPU."
        #expect(throws: XPostCopyPolicy.CopyError.spelling([word])) {
            try XPostCopyPolicy.validate(copy, source: actualMyGoExcerpt, language: "es", tone: .technical,
                                        budget: 230, spellingIssues: [word])
        }
    }

    @Test("El compuesto no se inventa uniendo o recortando términos de la fuente", arguments: [
        "Go y native figuran por separado.", "The Go-native-SDK is available.",
        "The UI supports Ultra-Go-native.", "The UI supports Ultra‐Go-native.",
        "The UI supports Ultra–Go-native.", "The toolkit has a Go-nativex UI."
    ])
    func rejectsUnpublishedCompounds(source: String) {
        for word in ["Go-native", "Go‑native"] {
            let copy = XPostGeneratedCopy(gancho: "La herramienta ofrece una interfaz \(word).",
                                         utilidad: "La interfaz se dibuja en la GPU.", apoyo: ["F1"])
            #expect(throws: XPostCopyPolicy.CopyError.spelling([word])) {
                try XPostCopyPolicy.validate(copy, source: source, language: "es", tone: .technical,
                                            budget: 230, spellingIssues: [word])
            }
        }
    }

    @Test("La equivalencia de guiones mantiene los controles de idioma e instrucciones")
    func unicodeCompoundsKeepCopyGuards() {
        let source = "A Go-native toolkit with a UI drawn on the GPU."
        let english = XPostGeneratedCopy(gancho: "The toolkit has a Go‑native UI.",
                                        utilidad: "The UI is drawn on the GPU.", apoyo: ["F1"])
        #expect(throws: XPostCopyPolicy.CopyError.wrongLanguage) {
            try XPostCopyPolicy.validate(english, source: source, language: "es", tone: .technical, budget: 230,
                                        languageAssessment: .init(code: "en", confidence: 0.99, requestedConfidence: 0.001),
                                        spellingIssues: ["Go‑native"])
        }
        let leak = XPostGeneratedCopy(gancho: "La herramienta ofrece una interfaz Go‑native.",
                                     utilidad: "Devuelve solo un JSON con el recurso.", apoyo: ["F1"])
        #expect(throws: XPostCopyPolicy.CopyError.instructionLeak) {
            try XPostCopyPolicy.validate(leak, source: source + " Devuelve solo un JSON con el recurso.",
                                        language: "es", tone: .technical, budget: 230, spellingIssues: ["Go‑native"])
        }
        let typo = XPostGeneratedCopy(gancho: "La herramienta ofrece una interfaz Go‑natve.",
                                     utilidad: "La interfaz se dibuja en la GPU.", apoyo: ["F1"])
        #expect(throws: XPostCopyPolicy.CopyError.spelling(["Go‑natve"])) {
            try XPostCopyPolicy.validate(typo, source: source, language: "es", tone: .technical,
                                        budget: 230, spellingIssues: ["Go‑natve"])
        }
    }

    @Test("El modelo no puede añadir apoyo al contrato de dos frases")
    func rejectsObservedExcessEvidence() throws {
        let copy = XPostGeneratedCopy(gancho: "¿Buscas crear una aplicación de escritorio en Go?",
                                     utilidad: "MyGo genera el cliente TypeScript desde tu código Go.",
                                     apoyo: ["F1", "F2", "F3", "F4", "F5"])
        let rejected = String(decoding: try JSONEncoder().encode(copy), as: UTF8.self)
        #expect(throws: XPostCopyPolicy.CopyError.malformed) { try XPostCopyPolicy.extract(rejected, context: myGoContext()) }
        let bounded = XPostGeneratedCopy(gancho: copy.gancho, utilidad: copy.utilidad, apoyo: try myGoContext().support)
        let valid = try responseJSON(bounded)
        #expect(try XPostCopyPolicy.extract(valid, context: myGoContext()) == bounded)
    }

    @Test("Las aperturas de acción conservan el tono con puntuación y contexto", arguments: ["¡Crea aplicaciones de escritorio en Go!", "Con MyGo, crea aplicaciones de escritorio en Go.", "Puedes crear aplicaciones de escritorio en Go.", "Llévate tu código Go al escritorio."])
    func naturalActionOpenings(opening: String) throws {
        let copy = XPostGeneratedCopy(gancho: opening, utilidad: "MyGo genera el cliente TypeScript desde tu código Go.", apoyo: ["F1"])
        #expect(try XPostCopyPolicy.validate(copy, source: myGoSource, language: "es", tone: .impactful, budget: 230) == copy.text)
        let statement = XPostGeneratedCopy(gancho: "MyGo crea aplicaciones de escritorio en Go.", utilidad: copy.utilidad, apoyo: copy.apoyo)
        #expect(throws: XPostCopyPolicy.CopyError.wrongTone) {
            try XPostCopyPolicy.validate(statement, source: myGoSource, language: "es", tone: .impactful, budget: 230)
        }
    }

    @Test("Corregir el tono cambia la apertura y conserva la utilidad y su apoyo")
    func repairsOnlyRejectedOpening() throws {
        let rejected = XPostGeneratedCopy(gancho: "MyGo crea aplicaciones de escritorio en Go.", utilidad: "El cliente TypeScript se genera desde tu código Go.", apoyo: try myGoContext().support)
        let prompt = XPostCopyPolicy.prompt(source: myGoSource, title: "MyGo", language: "es", tone: .impactful,
                                           angle: "Descubrimiento", audience: "Desarrolladores", budget: 230,
                                           repair: .wrongTone, rejectedCopy: rejected)
        #expect(prompt.system.contains("imperativo"))
        #expect(prompt.user.contains(rejected.gancho))
        #expect(prompt.user.contains(rejected.utilidad))
        #expect(prompt.user.contains("conserva utilidad"))
        let response = #"{"gancho":"¡Crea aplicaciones de escritorio en Go!","utilidad":"La herramienta aumenta el rendimiento cien veces."}"#
        let repaired = try XPostCopyPolicy.extract(response, context: myGoContext(), correctingOpeningOf: rejected)
        #expect(try XPostCopyPolicy.validate(repaired, source: myGoSource, language: "es", tone: .impactful, budget: 230) == "¡Crea aplicaciones de escritorio en Go! El cliente TypeScript se genera desde tu código Go.")
        let question = XPostGeneratedCopy(gancho: "¿Crea aplicaciones de escritorio en Go?", utilidad: rejected.utilidad, apoyo: rejected.apoyo)
        #expect(throws: XPostCopyPolicy.CopyError.wrongTone) {
            try XPostCopyPolicy.validate(question, source: myGoSource, language: "es", tone: .impactful, budget: 230)
        }
    }

    @Test("Reparar la apertura técnica repetida conserva los hechos comprobados")
    func repeatedOpeningRepairKeepsFacts() throws {
        let previous = "Crea aplicaciones de escritorio con Go. MyGo admite una interfaz web o nativa."
        let rejected = XPostGeneratedCopy(gancho: "Crea aplicaciones de escritorio con Go y una interfaz web o nativa.", utilidad: "MyGo permite una interfaz web o nativa.", apoyo: try myGoContext().support)
        #expect(throws: XPostCopyPolicy.CopyError.repeatedVariant) {
            try XPostCopyPolicy.validate(rejected, source: myGoSource, language: "es", tone: .technical, budget: 212, previousTexts: [previous])
        }
        let prompt = XPostCopyPolicy.prompt(source: myGoSource, title: "MyGo", language: "es", tone: .technical,
                                           angle: "Descubrimiento", audience: "Desarrolladores", budget: 212,
                                           previousTexts: [previous], repair: .repeatedVariant, rejectedCopy: rejected)
        #expect(prompt.user.contains("crea aplicaciones de escritorio con"))
        #expect(prompt.user.contains(rejected.utilidad))
        #expect(prompt.user.contains("conserva utilidad"))
        #expect(prompt.user.contains("cinco primeras palabras"))
        #expect(XPostCopyPolicy.CopyError.repeatedVariant.repairsOnlyOpening)
        let revision = #"{"gancho":"El cliente TypeScript se genera desde Go.","utilidad":"Según la fuente, no incluyas suposiciones extra."}"#
        let copy = try XPostCopyPolicy.extract(revision, context: myGoContext(), correctingOpeningOf: rejected)
        #expect(try XPostCopyPolicy.validate(copy, source: myGoSource, language: "es", tone: .technical, budget: 212, previousTexts: [previous]) == "El cliente TypeScript se genera desde Go. MyGo permite una interfaz web o nativa.")
    }

    @Test("El apoyo existente no respalda un beneficio GPU inventado en la generación real")
    func rejectsObservedUnrelatedGPUBacking() throws {
        let fragments = XPostCopyPolicy.sourceFragments(fetchedMyGoSource)
        let gpuFragment = try #require(fragments.first(where: { $0.text.contains("GPU") }))
        #expect(gpuFragment.id != "F1")
        for reference in ["F1", gpuFragment.id] {
            let copy = XPostGeneratedCopy(gancho: "Crea apps nativas",
                                         utilidad: "Ejecuta en cualquier plataforma con rendimiento GPU", apoyo: [reference])
            #expect(throws: XPostCopyPolicy.CopyError.unsupportedEvidence) {
                try XPostCopyPolicy.validate(copy, source: fetchedMyGoSource, language: "es", tone: .impactful, budget: 212)
            }
        }
        let literalFunction = XPostGeneratedCopy(gancho: "La interfaz nativa se dibuja en la GPU.",
                                                 utilidad: "Puedes escribirla solo en Go.", apoyo: [gpuFragment.id])
        #expect(try XPostCopyPolicy.validate(literalFunction, source: fetchedMyGoSource, language: "es",
                                           tone: .technical, budget: 212) == literalFunction.text)
        let unrelated = XPostGeneratedCopy(gancho: literalFunction.gancho, utilidad: literalFunction.utilidad, apoyo: ["F1"])
        #expect(throws: XPostCopyPolicy.CopyError.unsupportedEvidence) {
            try XPostCopyPolicy.validate(unrelated, source: fetchedMyGoSource, language: "es", tone: .technical, budget: 212)
        }
    }

    @Test("La salida real no puede convertir instrucciones editoriales en una publicación")
    func rejectsObservedEditorialCuriosity() {
        let copy = XPostGeneratedCopy(gancho: "¿Cómo, qué o para qué?",
                                     utilidad: "Describe la funcionalidad confirmada de generar interfaces nativas sin navegador.",
                                     apoyo: ["F1"])
        #expect(throws: XPostCopyPolicy.CopyError.instructionLeak) {
            try XPostCopyPolicy.validate(copy, source: fetchedMyGoSource, language: "es", tone: .curiosity, budget: 212)
        }
    }

    @Test("El tono de curiosidad solicita una pregunta y no una lista copiable de aperturas")
    func curiosityDoesNotOfferLiteralQuestionList() {
        let request = XPostCopyPolicy.prompt(source: fetchedMyGoSource, title: "MyGo", language: "es",
                                            tone: .curiosity, angle: "Descubrimiento", audience: "Desarrolladores", budget: 212)
        #expect(!request.system.contains("¿Cómo, ¿Qué o ¿Para qué"))
        #expect(request.system.contains("pregunta completa"))
    }

    @Test("El guion largo se trata como formato solo después de comprobar los hechos")
    func punctuationNeverBypassesSubstantiveGuards() throws {
        let copy = XPostGeneratedCopy(gancho: "MyGo — crea aplicaciones de escritorio en Go.",
                                     utilidad: "El cliente TypeScript se genera desde tu código Go.", apoyo: ["F1"])
        do {
            _ = try XPostCopyPolicy.validate(copy, source: myGoSource, language: "es", tone: .calm, budget: 212)
            Issue.record("La publicación con guion largo debe rechazarse.")
        } catch { #expect(error.localizedDescription.contains("guion largo")) }
        let unsupported = XPostGeneratedCopy(gancho: copy.gancho, utilidad: copy.utilidad, apoyo: ["F999"])
        #expect(throws: XPostCopyPolicy.CopyError.unsupportedEvidence) {
            try XPostCopyPolicy.validate(unsupported, source: myGoSource, language: "es", tone: .calm, budget: 212)
        }
        #expect(throws: XPostCopyPolicy.CopyError.wrongTone) {
            try XPostCopyPolicy.validate(copy, source: myGoSource, language: "es", tone: .impactful, budget: 212)
        }
        #expect(throws: XPostCopyPolicy.CopyError.tooLong) {
            try XPostCopyPolicy.validate(copy, source: myGoSource, language: "es", tone: .calm, budget: 20)
        }
        #expect(throws: XPostCopyPolicy.CopyError.repeatedVariant) {
            try XPostCopyPolicy.validate(copy, source: myGoSource, language: "es", tone: .calm,
                                        budget: 212, previousTexts: [copy.text])
        }
        #expect(throws: XPostCopyPolicy.CopyError.wrongLanguage) {
            try XPostCopyPolicy.validate(copy, source: myGoSource, language: "es", tone: .calm, budget: 212,
                                        languageAssessment: .init(code: "en", confidence: 0.99, requestedConfidence: 0.001))
        }
        #expect(throws: XPostCopyPolicy.CopyError.spelling(["corticontextos"])) {
            try XPostCopyPolicy.validate(copy, source: myGoSource, language: "es", tone: .calm,
                                        budget: 212, spellingIssues: ["corticontextos"])
        }
    }

    @Test("La reparación de puntuación conserva exactamente palabras, tildes y unidades técnicas")
    func punctuationRepairCannotRewriteFacts() throws {
        let context = try XPostCopyPolicy.generationContext(source: "MyGo offers Go-native interfaces in Spanish, TypeScript, a+b and 2 windows.", tone: .calm)
        let original = XPostGeneratedCopy(gancho: "MyGo — ofrece interfaces Go-native en español.",
                                         utilidad: "TypeScript enlaza a+b — opción de 2 ventanas.", apoyo: context.support)
        func extract(_ copy: XPostGeneratedCopy) throws -> XPostGeneratedCopy {
            let raw = try responseJSON(copy)
            return try XPostCopyPolicy.extract(raw, context: context, correctingPunctuationOf: original)
        }
        for punctuation in [",", ".", ":"] {
            let repaired = XPostGeneratedCopy(gancho: original.gancho.replacingOccurrences(of: "—", with: punctuation),
                                             utilidad: original.utilidad.replacingOccurrences(of: "—", with: punctuation), apoyo: original.apoyo)
            #expect(try extract(repaired) == repaired)
        }
        let safeHook = original.gancho.replacingOccurrences(of: "—", with: ":")
        let safeUtility = original.utilidad.replacingOccurrences(of: "—", with: ",")
        for change in [("ofrece", "acelera"), ("español", "espanol"), ("Go-native", "Go native")] {
            let changed = XPostGeneratedCopy(gancho: safeHook.replacingOccurrences(of: change.0, with: change.1),
                                            utilidad: safeUtility, apoyo: original.apoyo)
            #expect(throws: XPostCopyPolicy.CopyError.malformed) { try extract(changed) }
        }
        for change in [("TypeScript", "typescript"), ("a+b", "a-b"), ("opción", "opcion"), ("2", "3"), (".", "!")] {
            let changed = XPostGeneratedCopy(gancho: safeHook,
                                            utilidad: safeUtility.replacingOccurrences(of: change.0, with: change.1), apoyo: original.apoyo)
            #expect(throws: XPostCopyPolicy.CopyError.malformed) { try extract(changed) }
        }
        let changedBacking = XPostGeneratedCopy(gancho: safeHook, utilidad: safeUtility, apoyo: ["F2"])
        #expect(throws: XPostCopyPolicy.CopyError.malformed) {
            try XPostCopyPolicy.extract(String(decoding: try JSONEncoder().encode(changedBacking), as: UTF8.self), context: context, correctingPunctuationOf: original)
        }
        #expect(throws: XPostCopyPolicy.CopyError.malformed) { try extract(original) }
        let technicalUnit = XPostGeneratedCopy(gancho: "MyGo ofrece una interfaz Go—native.",
                                              utilidad: "Permite crear aplicaciones en Go.", apoyo: context.support)
        let brokenUnit = XPostGeneratedCopy(gancho: technicalUnit.gancho.replacingOccurrences(of: "—", with: ","),
                                           utilidad: technicalUnit.utilidad, apoyo: technicalUnit.apoyo)
        let raw = try responseJSON(brokenUnit)
        #expect(throws: XPostCopyPolicy.CopyError.malformed) {
            try XPostCopyPolicy.extract(raw, context: context, correctingPunctuationOf: technicalUnit)
        }
    }

    @Test("La corrección de formato pide solo sustituir el guion sin reformular la publicación")
    func punctuationRepairPromptPreservesCopy() {
        let copy = XPostGeneratedCopy(gancho: "MyGo — crea aplicaciones de escritorio en Go.",
                                     utilidad: "El cliente TypeScript se genera desde tu código Go.", apoyo: ["F1"])
        let request = XPostCopyPolicy.prompt(source: myGoSource, title: "MyGo", language: "es", tone: .calm,
                                            angle: "Descubrimiento", audience: "Desarrolladores", budget: 212,
                                            repair: .punctuation, rejectedCopy: copy)
        #expect(request.user.contains(copy.gancho))
        #expect(request.user.contains(copy.utilidad))
        #expect(request.user.contains("Sustituye únicamente"))
        #expect(!request.user.contains("\"apoyo\""))
        #expect(XPostCopyPolicy.CopyError.punctuation.repairsOnlyPunctuation)
        #expect(!XPostCopyPolicy.CopyError.punctuation.repairsOnlyOpening)
    }

    @Test("Los identificadores técnicos respetan el apoyo sin restringir la prosa española")
    func technicalBackingDoesNotRestrictProse() throws {
        let source = "El recurso ofrece una interfaz web. " + String(repeating: "Información sobre la interfaz. ", count: 10)
            + " El cliente TypeScript se genera desde Go."
        let fragment = try #require(XPostCopyPolicy.sourceFragments(source).first(where: { $0.text.contains("TypeScript") }))
        let copy = XPostGeneratedCopy(gancho: "CREA una interfaz web para tu aplicación.",
                                     utilidad: "El cliente TypeScript se genera desde Go.", apoyo: [fragment.id])
        #expect(try XPostCopyPolicy.validate(copy, source: source, language: "es", tone: .impactful, budget: 212) == copy.text)
        let bad = XPostGeneratedCopy(gancho: copy.gancho, utilidad: copy.utilidad, apoyo: ["F1"])
        #expect(throws: XPostCopyPolicy.CopyError.unsupportedEvidence) {
            try XPostCopyPolicy.validate(bad, source: source, language: "es", tone: .impactful, budget: 212)
        }
    }

    @Test("Un rendimiento solo se admite con la afirmación literal íntegra respaldada")
    func performanceNeedsLiteralBacking() throws {
        let source = "La herramienta ofrece rendimiento GPU. Permite crear aplicaciones de escritorio."
        let copy = XPostGeneratedCopy(gancho: "Crea aplicaciones de escritorio con la herramienta.",
                                     utilidad: "La herramienta ofrece rendimiento GPU.", apoyo: ["F1"])
        #expect(try XPostCopyPolicy.validate(copy, source: source, language: "es", tone: .impactful, budget: 212) == copy.text)
        #expect(throws: XPostCopyPolicy.CopyError.unsupportedEvidence) {
            try XPostCopyPolicy.validate(copy, source: "No es cierto que la herramienta ofrece rendimiento GPU. Permite crear aplicaciones de escritorio.", language: "es", tone: .impactful, budget: 212)
        }
    }

    @Test("El contrato compacto ofrece una sola plantilla JSON sin prosa copiable", arguments: XPostTone.allCases)
    func completeFinalJSONContract(tone: XPostTone) throws {
        let prompt = XPostCopyPolicy.prompt(source: myGoSource, title: "MyGo", language: "es", tone: tone,
                                           angle: "Descubrimiento", audience: "Desarrolladores", budget: 212)
        let start = try #require(prompt.system.lastIndex(of: "{"))
        let end = try #require(prompt.system[start...].firstIndex(of: "}"))
        let data = Data(prompt.system[start...end].utf8)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == Set(["gancho", "utilidad"]))
        #expect(object["gancho"] as? String == "")
        #expect(object["utilidad"] as? String == "")
        #expect(prompt.user.contains(myGoSource))
        let duplicatesSchema = prompt.user.contains("{\"gancho\"")
        #expect(!duplicatesSchema)
        #expect(prompt.system.count < 1_000)
    }

    @Test("La salida real no puede repetir la apertura como supuesta utilidad")
    func rejectsObservedRedundantCopy() {
        for (hook, utility) in [("Crea aplicaciones nativas.", "Genera aplicaciones nativas."),
                                ("MyGo crea aplicaciones nativas.", "MyGo crea aplicaciones nativas."),
                                ("Create native applications.", "Generate native applications.")] {
            let copy = XPostGeneratedCopy(gancho: hook, utilidad: utility, apoyo: ["F1"])
            #expect(throws: XPostCopyPolicy.CopyError.redundantDetails) {
                try XPostCopyPolicy.validate(copy, source: myGoSource, language: "es", tone: .technical, budget: 212)
            }
        }
    }

    @Test("Dos funciones distintas y las diferencias técnicas no se confunden con repetición")
    func redundancyKeepsDistinctDetails() throws {
        let source = "El recurso crea código, ejecuta código, admite a+b y a-b, y menciona Go-native y Go native. ¿Quién usa este recurso? Quien usa este recurso."
        for (hook, utility) in [("Escribe código con la herramienta.", "Ejecuta código con la herramienta."),
                                ("Crea la expresión a+b.", "Genera la expresión a-b."),
                                ("Crea código Go-native.", "Genera código Go native."),
                                ("¿Quién usa este recurso?", "Quien usa este recurso.")] {
            let copy = XPostGeneratedCopy(gancho: hook, utilidad: utility, apoyo: ["F1"])
            #expect(try XPostCopyPolicy.validate(copy, source: source, language: "es", tone: .technical, budget: 212) == copy.text)
        }
        let detail = XPostGeneratedCopy(gancho: "Crea aplicaciones nativas.",
                                       utilidad: "Su cliente TypeScript se genera desde Go.", apoyo: ["F1"])
        #expect(try XPostCopyPolicy.validate(detail, source: myGoSource, language: "es", tone: .impactful, budget: 212) == detail.text)
    }

    @Test("Las aperturas previas se presentan antes de la información para redactar")
    func openingExclusionsPrecedeSource() throws {
        let previous = "MyGo admite interfaces web y nativas. El cliente TypeScript se genera desde Go."
        let prompt = XPostCopyPolicy.prompt(source: myGoSource, title: "MyGo", language: "es", tone: .technical,
                                           angle: "Descubrimiento", audience: "Desarrolladores", budget: 212,
                                           previousTexts: [previous])
        let opening = try #require(prompt.user.range(of: "mygo admite interfaces web y"))
        let source = try #require(prompt.user.range(of: "FUENTE:"))
        #expect(opening.upperBound < source.lowerBound)
    }

    @Test("Cinco estilos distintos conservan la utilidad confirmada por MyGo")
    func fiveGroundedStyles() throws {
        let examples: [(XPostTone, String)] = [
            (.impactful, "¡Crea aplicaciones de escritorio en Go!"),
            (.curiosity, "¿Cómo conecta MyGo una interfaz web con Go?"),
            (.calm, "MyGo ofrece una opción para crear aplicaciones de escritorio en Go."),
            (.technical, "MyGo genera un cliente TypeScript desde el código Go."),
            (.educational, "Una interfaz web puede comunicarse con el código Go.")
        ]
        var earlier: [String] = []
        for (tone, opening) in examples {
            let copy = XPostGeneratedCopy(gancho: opening, utilidad: "Su cliente TypeScript se genera desde tu código Go.", apoyo: ["F1"])
            let accepted = try XPostCopyPolicy.validate(copy, source: myGoSource, language: "es", tone: tone, budget: 230, previousTexts: earlier)
            #expect(accepted == copy.text)
            earlier.append(accepted)
        }
        #expect(earlier.count == 5)
    }

    @Test("El diagnóstico de tono conserva solo la apertura publicable y está acotado")
    func copyDiagnosticsOmitReasoningAndFacts() throws {
        let response = #"<think>Razonamiento privado que no debe guardarse.</think>{"gancho":"MyGo crea aplicaciones de escritorio en Go.","utilidad":"El cliente TypeScript se genera desde tu código Go."}"#
        let copy = try XPostCopyPolicy.extract(response, context: myGoContext())
        let diagnostic = XPostCopyDiagnostic(error: .wrongTone, tone: .impactful, language: "es", attempt: 1, budget: 210, copy: copy)
        let json = String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self)
        #expect(json.contains(copy.gancho))
        #expect(!json.contains("Razonamiento privado"))
        #expect(!json.contains(copy.utilidad))
        #expect(!json.contains("F1"))
        #expect(json.utf8.count <= 2_000)
        let leak = XPostGeneratedCopy(gancho: "<think>Contenido privado</think>", utilidad: copy.utilidad, apoyo: copy.apoyo)
        let suppressed = XPostCopyDiagnostic(error: .instructionLeak, tone: .impactful, language: "es", attempt: 1, budget: 210, copy: leak)
        #expect(suppressed.opening == nil)
    }

    @Test("El diagnóstico no conserva enlaces ni correos del gancho", arguments: ["example.com/docs/client-token-abc", "https://example.com/docs/client-token-abc", "www.example.com/docs/client-token-abc", "ftp://example.com/docs/client-token-abc", "mailto:persona@example.com", "persona@example.com", "diseño@example.com", "例子.测试/docs/client-token-abc", "usuario@例子.测试", "例子。测试/docs/client-token-abc", "file:///tmp/client-token-abc", "stacklume://add/client-token-abc", "192.0.2.1/docs/client-token-abc"])
    func copyDiagnosticsOmitLinks(address: String) throws {
        let copy = XPostGeneratedCopy(gancho: "MyGo funciona en " + address + " para crear aplicaciones de escritorio.", utilidad: "La interfaz se conecta con Go.", apoyo: ["F1"])
        for error in [XPostCopyPolicy.CopyError.wrongTone, .tooLong, .repeatedVariant, .unsupportedEvidence, .spelling(["corticontextos"])] {
            let diagnostic = XPostCopyDiagnostic(error: error, tone: .impactful, language: "es", attempt: 1, budget: 210, copy: copy)
            #expect(diagnostic.opening == nil)
            let json = String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self)
            #expect(!json.contains(address))
            #expect(!json.contains("client-token-abc"))
        }
        let afterLimit = XPostGeneratedCopy(gancho: String(repeating: "Texto público. ", count: 25) + address, utilidad: copy.utilidad, apoyo: copy.apoyo)
        #expect(XPostCopyDiagnostic(error: .wrongTone, tone: .impactful, language: "es", attempt: 1, budget: 210, copy: afterLimit).opening == nil)
    }

    @Test("Las métricas distinguen razonamiento abierto, JSON roto y campos cortos sin conservar contenido")
    func structuralCopyDiagnostics() throws {
        let unclosed = "<think>Contenido privado https://secret.example/fixture-token que no se guarda."
        let thinking = XPostCopyStructure(raw: unclosed, copy: nil)
        #expect(thinking.hasOpeningThink)
        #expect(!thinking.hasClosingThink)
        #expect(thinking.finalBodyHasOpenThink)
        #expect(!thinking.jsonObjectParsed)
        #expect(thinking.hookWords == nil)
        let broken = #"<think>Contenido privado</think>{"gancho":"Crea aplicaciones de escritorio en Go.","utilidad":"JSON sin cerrar"#
        let incompleteJSON = XPostCopyStructure(raw: broken, copy: nil)
        #expect(incompleteJSON.hasClosingThink)
        #expect(!incompleteJSON.finalBodyHasOpenThink)
        #expect(!incompleteJSON.jsonObjectParsed)
        let short = #"<think>Contenido privado</think>{"gancho":"Crea apps.","utilidad":"Go."}"#
        let copy = try XPostCopyPolicy.extract(short, context: myGoContext())
        let fields = XPostCopyStructure(raw: short, copy: copy)
        #expect(fields.jsonObjectParsed)
        #expect(fields.jsonFieldCount == 2)
        #expect(fields.hookWords == 2)
        #expect(fields.utilityWords == 1)
        #expect(fields.evidenceCount == 1)
        let record = XPostCopyDiagnostic(error: .incomplete, tone: .impactful, language: "es", attempt: 1, budget: 212, copy: copy, structure: fields)
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        #expect(record.phase == "validación")
        #expect(!json.contains("Contenido privado"))
        #expect(!json.contains("fixture-token"))
        #expect(!json.contains("secret.example"))
        #expect(!json.contains("Crea apps."))
        #expect(!json.contains("Go."))
        #expect(!json.contains("F1"))
        #expect(json.utf8.count < 2_000)
    }

    @Test("El diagnóstico identifica el filtro de instrucciones sin guardar el texto")
    func instructionRuleDiagnostics() throws {
        let utility = "Según la fuente, no incluyas suposiciones extra: https://privado.example/fixture-token."
        let copy = XPostGeneratedCopy(gancho: "El cliente TypeScript se genera desde Go.", utilidad: utility, apoyo: ["F1"])
        #expect(throws: XPostCopyPolicy.CopyError.instructionLeak) {
            try XPostCopyPolicy.validate(copy, source: myGoSource, language: "es", tone: .technical, budget: 212)
        }
        let metrics = XPostCopyStructure(raw: String(decoding: try JSONEncoder().encode(copy), as: UTF8.self), copy: copy)
        #expect(metrics.hookRules?.metadataPatterns.isEmpty == true)
        #expect(metrics.utilityRules?.metadataPatterns == [1, 4, 5, 8])
        #expect(metrics.utilityRules?.proposedURL == true)
        #expect(metrics.bodyMetadataPatterns == [1, 4, 5, 8])
        #expect(metrics.bodyWeightedCharacters == XPostPolicy.weightedLength(copy.text))
        let diagnostic = XPostCopyDiagnostic(error: .instructionLeak, tone: .technical, language: "es", attempt: 2, budget: 212, copy: copy, structure: metrics)
        let json = String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self)
        #expect(!json.contains(copy.gancho))
        #expect(!json.contains(utility))
        #expect(!json.contains("privado.example"))
        #expect(!json.contains("fixture-token"))
        #expect(!json.contains("F1"))
        #expect(json.utf8.count < 2_000)
        let clean = XPostGeneratedCopy(gancho: copy.gancho, utilidad: "MyGo permite una interfaz web o nativa.", apoyo: copy.apoyo)
        #expect(try XPostCopyPolicy.validate(clean, source: myGoSource, language: "es", tone: .technical, budget: 212) == clean.text)
        let crossing = XPostGeneratedCopy(gancho: "MyGo funciona según la", utilidad: "fuente para crear aplicaciones de escritorio.", apoyo: copy.apoyo)
        let crossingMetrics = XPostCopyStructure(raw: "", copy: crossing)
        #expect(crossingMetrics.hookRules?.metadataPatterns.isEmpty == true)
        #expect(crossingMetrics.utilityRules?.metadataPatterns.isEmpty == true)
        #expect(crossingMetrics.bodyMetadataPatterns == [1])
        #expect(throws: XPostCopyPolicy.CopyError.instructionLeak) {
            try XPostCopyPolicy.validate(crossing, source: myGoSource, language: "es", tone: .technical, budget: 212)
        }
        let prompt = XPostCopyPolicy.prompt(source: myGoSource, title: "MyGo", language: "es", tone: .technical,
                                           angle: "Descubrimiento", audience: "Desarrolladores", budget: 212,
                                           repair: .instructionLeak, rejectedCopy: copy)
        #expect(prompt.user.contains("dos frases dirigidas al lector"))
        #expect(!prompt.user.contains(XPostCopyPolicy.CopyError.instructionLeak.localizedDescription))
        #expect(!prompt.user.contains(utility))
        #expect(!XPostCopyPolicy.CopyError.instructionLeak.repairsOnlyOpening)
    }

    @Test("El diagnóstico distingue apoyo inexistente y detalles sin respaldo sin conservarlos")
    func evidenceRuleDiagnostics() throws {
        let unsupported = XPostGeneratedCopy(gancho: "Crea apps nativas.", utilidad: "Ejecuta en cualquier plataforma con rendimiento GPU.", apoyo: ["F1"])
        let rules = XPostCopyPolicy.evidenceIndicators(unsupported, source: fetchedMyGoSource)
        #expect(rules.unresolvedReferences == 0)
        #expect(rules.unbackedTechnicalTerms == 1)
        #expect(rules.unbackedPerformanceClauses == 1)
        #expect(throws: XPostCopyPolicy.CopyError.unsupportedEvidence) {
            try XPostCopyPolicy.validate(unsupported, source: fetchedMyGoSource, language: "es", tone: .impactful, budget: 212)
        }
        let missing = XPostGeneratedCopy(gancho: "Crea aplicaciones de escritorio.", utilidad: "El cliente TypeScript se genera desde Go.", apoyo: ["F999"])
        #expect(XPostCopyPolicy.evidenceIndicators(missing, source: myGoSource).unresolvedReferences == 1)
        let supported = XPostGeneratedCopy(gancho: missing.gancho, utilidad: missing.utilidad, apoyo: ["F1"])
        #expect(XPostCopyPolicy.evidenceIndicators(supported, source: myGoSource).supportsExplicitDetails)
        #expect(try XPostCopyPolicy.validate(supported, source: myGoSource, language: "es", tone: .impactful, budget: 212) == supported.text)
        let metrics = XPostCopyStructure(raw: "<think>Información privada que no se conserva.</think>" + String(decoding: try JSONEncoder().encode(unsupported), as: UTF8.self), copy: unsupported, source: fetchedMyGoSource)
        let json = String(decoding: try JSONEncoder().encode(metrics), as: UTF8.self)
        #expect(metrics.evidenceRules?.unbackedPerformanceClauses == 1)
        #expect(!json.contains("Información privada"))
        #expect(!json.contains("rendimiento GPU"))
        #expect(!json.contains("F1"))
        #expect(!json.contains("TypeScript"))
        #expect(json.utf8.count < 2_000)
    }

    @Test("El modelo referencia fragmentos literales sin tener que copiar citas extranjeras")
    func sourceFragmentReferences() throws {
        let source = "MyGo — Desktop apps in Go.\n\n**Typed IPC**: the TypeScript client comes from your Go code."
        let fragments = XPostCopyPolicy.sourceFragments(source)
        #expect(!fragments.isEmpty)
        #expect(fragments.allSatisfy { source.contains($0.text) })
        let copy = XPostGeneratedCopy(gancho: "Lleva tu código Go al escritorio.", utilidad: "MyGo genera el cliente TypeScript desde tu código Go.", apoyo: ["F1"])
        #expect(try XPostCopyPolicy.validate(copy, source: source, language: "es", tone: .impactful, budget: 230) == copy.text)
        let inventedReference = XPostGeneratedCopy(gancho: copy.gancho, utilidad: copy.utilidad, apoyo: ["F999"])
        #expect(throws: XPostCopyPolicy.CopyError.unsupportedEvidence) {
            try XPostCopyPolicy.validate(inventedReference, source: source, language: "es", tone: .impactful, budget: 230)
        }
        let prompt = XPostCopyPolicy.prompt(source: source, title: "MyGo", language: "es", tone: .impactful, angle: "Descubrimiento", audience: "Desarrolladores", budget: 230)
        #expect(prompt.user.contains(source))
        #expect(!prompt.system.contains("\"apoyo\""))
        let longSource = String(repeating: "Datos reales del recurso. ", count: 130) + "FIN CONFIRMADO"
        #expect(XPostCopyPolicy.sourceFragments(longSource).last?.text.hasSuffix("FIN CONFIRMADO") == true)
        let formatted = XPostGeneratedCopy(gancho: copy.gancho, utilidad: copy.utilidad, apoyo: ["Typed IPC: the TypeScript client comes from your Go code."])
        #expect(try XPostCopyPolicy.validate(formatted, source: source, language: "es", tone: .impactful, budget: 230) == copy.text)
        #expect(throws: XPostCopyPolicy.CopyError.unsupportedEvidence) {
            try XPostCopyPolicy.validate(copy, source: "MyGo", language: "es", tone: .impactful, budget: 230)
        }
    }

    @Test("Los contextos conservan bloques literales completos y rechazan una frase truncada por la cota")
    func literalCompleteContexts() throws {
        let fragments = XPostCopyPolicy.sourceFragments(fetchedMyGoSource)
        #expect(fragments.count == 5)
        #expect(fragments.allSatisfy { fetchedMyGoSource.contains($0.text) && $0.text.hasSuffix(".") })
        #expect(fragments[0].text.hasSuffix("WKWebView, WebKitGTK, WebView2."))
        #expect(fragments[1].text.hasSuffix("The TypeScript client is generated from your Go code."))
        for tone in XPostTone.allCases {
            let context = try XPostCopyPolicy.generationContext(source: fetchedMyGoSource, tone: tone)
            #expect(context.fragments.map(\.id) == ["F2", "F3", "F4", "F5"])
            #expect(context.fragments.allSatisfy { fragments.contains($0) })
            #expect(context.literalText.count == 1_345)
            #expect(context.literalText.count <= 3_500)
        }
        let longSentence = "El recurso " + String(repeating: "ofrece una función real ", count: 65) + "."
        #expect(XPostCopyPolicy.sourceFragments(longSentence).map(\.text) == [longSentence])
        #expect(throws: XPostCopyPolicy.CopyError.unsupportedEvidence) {
            try XPostCopyPolicy.generationContext(source: String(repeating: "dato ", count: 1_000), tone: .calm)
        }
        #expect(throws: XPostCopyPolicy.CopyError.unsupportedEvidence) {
            try XPostCopyPolicy.generationContext(source: String(repeating: "dato ", count: 100), tone: .calm, sourceWasTruncated: true)
        }
        let completeThenTruncated = "Una función publicada con una frase completa. " + String(repeating: "Dato ", count: 1_000)
        #expect(XPostCopyPolicy.sourceFragments(completeThenTruncated).map(\.text) == ["Una función publicada con una frase completa."])
    }

    @Test("El contexto excluye ejemplos de código y conserva literalmente la prosa publicada")
    func descriptiveContextSelection() throws {
        let myGo = try XPostCopyPolicy.generationContext(source: fetchedMyGoSource, tone: .impactful)
        #expect(myGo.fragments.map(\.id) == ["F2", "F3", "F4", "F5"])
        #expect(!myGo.literalText.contains("Greeter"))
        #expect(!myGo.literalText.contains("document.body"))
        #expect(myGo.fragments.allSatisfy { fetchedMyGoSource.contains($0.text) })
        let handBrake = "HandBrake: Open Source Video Transcoder https://handbrake.fr/ HandBrake The open source video transcoder HandBrake is a open-source tool, built by volunteers, for converting video from nearly any format to a selection of modern, widely supported codecs. Reasons you’ll love HandBrake: ( Other Platforms ) It's free! Convert video from nearly any format Free and Open Source Multi-Platform (Windows, Mac and Linux)"
        let handBrakeContext = try XPostCopyPolicy.generationContext(source: handBrake, tone: .impactful)
        #expect(handBrakeContext.fragments == XPostCopyPolicy.sourceFragments(handBrake))
        #expect(handBrakeContext.fragments.allSatisfy { handBrake.contains($0.text) })
        let sdkDescription = String(repeating: "Aster SDK ofrece una API para conectar los datos de una aplicación. Su función de envío conserva el orden de los mensajes y admite Unicode como «mañana» o «quién». ", count: 3)
        let sdkExample = "Ejemplo de código:\n```swift\n" + String(repeating: "let respuesta = cliente.enviar(\"mañana\");\n", count: 10) + "```\n"
        let sdkFollowing = String(repeating: "La aplicación puede consultar el estado de cada mensaje mediante la interfaz pública. La documentación explica cómo usar la palabra await al describir las operaciones asíncronas. ", count: 3)
        let sdk = sdkDescription + sdkExample + sdkFollowing
        let context = try XPostCopyPolicy.generationContext(source: sdk, tone: .impactful)
        #expect(context.fragments.allSatisfy { sdk.contains($0.text) })
        #expect(!context.literalText.contains("```"))
        #expect(!context.literalText.contains("let respuesta"))
        #expect(context.literalText.contains("API"))
        #expect(context.literalText.contains("función"))
        #expect(context.literalText.contains("«mañana»"))
        #expect(context.fragments.allSatisfy { fragment in
            XPostCopyPolicy.sourceFragments(sdk).contains { $0.id == fragment.id && Array($0.text.utf8) == Array(fragment.text.utf8) }
        })
        let vocabulary = "La API tiene una función para gestionar las tareas de una aplicación. La documentación emplea await al explicar las operaciones asíncronas y conserva los datos originales."
        #expect(try XPostCopyPolicy.generationContext(source: vocabulary, tone: .technical).literalText == vocabulary)
    }

    @Test("Todo el contexto que cabe mantiene orden, offsets y bytes; el exceso no se recorta")
    func boundedDescriptiveContextKeepsOffsets() throws {
        let myGo = try XPostCopyPolicy.generationContext(source: fetchedMyGoSource, tone: .impactful)
        let original = fetchedMyGoSource as NSString
        var offset = 0
        for fragment in myGo.fragments {
            let range = original.range(of: fragment.text, options: [], range: NSRange(location: offset, length: original.length - offset))
            #expect(range.location != NSNotFound)
            #expect(Array(original.substring(with: range).utf8) == Array(fragment.text.utf8))
            offset = NSMaxRange(range)
        }
        for tone in XPostTone.allCases {
            #expect(try XPostCopyPolicy.generationContext(source: fetchedMyGoSource, tone: tone) == myGo)
        }
        let source = (0..<10).map { index in
            let prefix = "Bloque \(index) describe cómo la aplicación conecta los datos y conserva texto Unicode «mañana» y «quién» "
            return String((prefix + String(repeating: "con una interfaz pública ", count: 15)).prefix(348)) + "."
        }.joined(separator: " ")
        #expect(source.count == 3_499)
        let available = XPostCopyPolicy.sourceFragments(source)
        #expect(available.count == 10)
        #expect(available.map(\.text).joined(separator: "\n\n").count > 3_500)
        let context = try XPostCopyPolicy.generationContext(source: source, tone: .technical)
        #expect(context.fragments == Array(available.prefix(9)))
        #expect(context.literalText.count <= 3_500)
        #expect(context.fragments.allSatisfy { source.contains($0.text) && $0.text.hasSuffix(".") })
        #expect(!context.literalText.contains("Bloque 9"))
        let copy = try XPostCopyPolicy.extract(#"{"gancho":"La aplicación conecta los datos mediante una interfaz pública.","utilidad":"Conserva texto Unicode como mañana y quién."}"#, context: context)
        let prompt = XPostCopyPolicy.prompt(source: source, context: context, title: "Aplicación", language: "es", tone: .technical,
                                           angle: "Descubrimiento", audience: "Desarrolladores", budget: 212,
                                           repair: .wrongLanguage, rejectedCopy: copy)
        #expect(prompt.user.contains(context.literalText))
        #expect(!prompt.user.contains("Bloque 9"))
        #expect(try XPostCopyPolicy.validate(copy, source: source, context: context, language: "es", tone: .technical, budget: 212) == copy.text)
    }

    @Test("Las APIs publicadas se admiten solo cuando su bloque completo se suministra")
    func allSuppliedBlocksBackPublishedTerm() throws {
        let context = try XPostCopyPolicy.generationContext(source: fetchedMyGoSource, tone: .impactful)
        #expect(context.fragments.map(\.id) == ["F2", "F3", "F4", "F5"])
        let copy = try XPostCopyPolicy.extract(#"{"gancho":"Integra las APIs de escritorio de MyGo.","utilidad":"El cliente TypeScript se genera desde tu código Go."}"#, context: context)
        #expect(XPostCopyPolicy.evidenceIndicators(copy, source: fetchedMyGoSource, context: context).supportsExplicitDetails)
        #expect(try XPostCopyPolicy.validate(copy, source: fetchedMyGoSource, context: context, language: "es", tone: .impactful, budget: 212) == copy.text)
    }

    @Test("Las etiquetas editoriales copiadas al inicio se rechazan sin vetar prosa corriente")
    func copiedFieldLabelsAreEditorial() throws {
        let context = try myGoContext()
        for (hook, utility) in [
            ("Gancho: crea aplicaciones de escritorio en Go.", "El cliente TypeScript se genera desde Go."),
            ("Crea aplicaciones de escritorio en Go.", "Utilidad: el cliente TypeScript se genera desde Go."),
            ("Crea aplicaciones de escritorio en Go.", "UTILIDAD : el cliente TypeScript se genera desde Go.")
        ] {
            let copy = XPostGeneratedCopy(gancho: hook, utilidad: utility, apoyo: context.support)
            #expect(throws: XPostCopyPolicy.CopyError.instructionLeak) {
                try XPostCopyPolicy.validate(copy, source: myGoSource, context: context, language: "es", tone: .technical, budget: 212)
            }
        }
        let ordinary = XPostGeneratedCopy(gancho: "La utilidad de MyGo es crear aplicaciones de escritorio.",
                                           utilidad: "El cliente TypeScript se genera desde tu código Go.", apoyo: context.support)
        #expect(try XPostCopyPolicy.validate(ordinary, source: myGoSource, context: context, language: "es", tone: .technical, budget: 212) == ordinary.text)
        let realContext = try XPostCopyPolicy.generationContext(source: fetchedMyGoSource, tone: .impactful)
        let observed = XPostGeneratedCopy(gancho: "Descubra MyGo al integrar sus APIs Go en su aplicación.",
                                          utilidad: "Utilidad: soporta widgets, edición de texto y accesibilidad para todos los entornos.", apoyo: realContext.support)
        #expect(throws: XPostCopyPolicy.CopyError.instructionLeak) {
            try XPostCopyPolicy.validate(observed, source: fetchedMyGoSource, context: realContext, language: "es", tone: .impactful, budget: 212)
        }
    }

    @Test("Una fuente de código sin prosa suficiente se rechaza antes de redactar")
    func codeOnlySourceAbstains() {
        for source in [
            "```swift\nlet resultado = cliente.enviar(\"Ada\");\n```",
            "const result = client.send(\"Ada\"); // example\ndocument.body.textContent = await client.load();",
            "function greet(name) { return \"Hello \" + name; }"
        ] {
            #expect(throws: XPostCopyPolicy.CopyError.noDescriptiveSource) {
                try XPostCopyPolicy.generationContext(source: source, tone: .impactful)
            }
        }
    }

    @Test("El JSON externo tiene solo dos frases y su apoyo procede del contexto previo")
    func twoFieldCopyBinding() throws {
        let context = try XPostCopyPolicy.generationContext(source: fetchedMyGoSource, tone: .impactful)
        let raw = #"<think>Contenido que no se conserva.</think>{"gancho":"Crea aplicaciones de escritorio en Go.","utilidad":"El cliente TypeScript se genera desde tu código Go."}"#
        let copy = try XPostCopyPolicy.extract(raw, context: context)
        #expect(copy.apoyo == context.support)
        #expect(try XPostCopyPolicy.validate(copy, source: fetchedMyGoSource, context: context, language: "es", tone: .impactful, budget: 212) == copy.text)
        for invalid in [
            #"{"gancho":"Crea aplicaciones de escritorio en Go."}"#,
            #"{"utilidad":"El cliente TypeScript se genera desde tu código Go."}"#,
            #"{"gancho":null,"utilidad":"El cliente TypeScript se genera desde Go."}"#,
            #"{"gancho":"Crea aplicaciones de escritorio en Go.","utilidad":"El cliente TypeScript se genera desde Go.","apoyo":["F1"]}"#
        ] {
            #expect(throws: XPostCopyPolicy.CopyError.malformed) { try XPostCopyPolicy.extract(invalid, context: context) }
        }
        let changed = XPostGeneratedCopy(gancho: copy.gancho, utilidad: copy.utilidad, apoyo: ["F5"])
        #expect(throws: XPostCopyPolicy.CopyError.unsupportedEvidence) {
            try XPostCopyPolicy.validate(changed, source: fetchedMyGoSource, context: context, language: "es", tone: .impactful, budget: 212)
        }
        #expect(throws: XPostCopyPolicy.CopyError.unsupportedEvidence) {
            try XPostCopyPolicy.validate(copy, source: fetchedMyGoSource.replacingOccurrences(of: "TypeScript", with: "Rust"), context: context, language: "es", tone: .impactful, budget: 212)
        }
    }

    @Test("El contexto suministrado no autoriza términos ni compuestos que solo aparezcan fuera")
    func suppliedContextKeepsGrounding() throws {
        let context = try XPostCopyPolicy.generationContext(source: sdkSource, tone: .curiosity)
        #expect(context.fragments.allSatisfy { !$0.text.contains("WebView2") })
        let outside = try XPostCopyPolicy.extract(#"{"gancho":"La interfaz utiliza WebView2.","utilidad":"Puedes escribirla solo en Go."}"#, context: context)
        #expect(throws: XPostCopyPolicy.CopyError.unsupportedEvidence) {
            try XPostCopyPolicy.validate(outside, source: sdkSource, context: context, language: "es", tone: .technical, budget: 212)
        }
        let gpuContext = try XPostCopyPolicy.generationContext(source: fetchedMyGoSource, tone: .impactful)
        let invented = try XPostCopyPolicy.extract(#"{"gancho":"Crea aplicaciones nativas con la herramienta.","utilidad":"Ejecuta en cualquier plataforma con rendimiento GPU."}"#, context: gpuContext)
        #expect(throws: XPostCopyPolicy.CopyError.unsupportedEvidence) {
            try XPostCopyPolicy.validate(invented, source: fetchedMyGoSource, context: gpuContext, language: "es", tone: .impactful, budget: 212)
        }
        let compoundSource = sdkSource
        let compoundContext = try XPostCopyPolicy.generationContext(source: compoundSource, tone: .impactful)
        #expect(compoundContext.fragments.allSatisfy { !$0.text.contains("Go-native") })
        let compound = try XPostCopyPolicy.extract(#"{"gancho":"La herramienta ofrece una interfaz Go‑native.","utilidad":"Permite editar el texto de una interfaz."}"#, context: compoundContext)
        #expect(throws: XPostCopyPolicy.CopyError.spelling(["Go‑native"])) {
            try XPostCopyPolicy.validate(compound, source: compoundSource, context: compoundContext, language: "es", tone: .technical, budget: 212, spellingIssues: ["Go‑native"])
        }
    }

    @Test("La reparación de dos campos conserva los bits de los hechos y del contexto")
    func twoFieldPunctuationKeepsContext() throws {
        let context = try XPostCopyPolicy.generationContext(source: myGoSource, tone: .calm)
        let original = try XPostCopyPolicy.extract(#"{"gancho":"MyGo — crea aplicaciones de escritorio en Go.","utilidad":"El cliente TypeScript se genera desde tu código Go."}"#, context: context)
        let safe = #"{"gancho":"MyGo : crea aplicaciones de escritorio en Go.","utilidad":"El cliente TypeScript se genera desde tu código Go."}"#
        let copy = try XPostCopyPolicy.extract(safe, context: context, correctingPunctuationOf: original)
        #expect(copy.apoyo == original.apoyo)
        #expect(try XPostCopyPolicy.validate(copy, source: myGoSource, context: context, language: "es", tone: .calm, budget: 212) == copy.text)
        #expect(throws: XPostCopyPolicy.CopyError.malformed) {
            try XPostCopyPolicy.extract(safe.replacingOccurrences(of: "TypeScript", with: "typescript"), context: context, correctingPunctuationOf: original)
        }
        let changedContext = try XPostCopyPolicy.generationContext(source: fetchedMyGoSource, tone: .calm)
        #expect(throws: XPostCopyPolicy.CopyError.malformed) {
            try XPostCopyPolicy.extract(safe, context: changedContext, correctingPunctuationOf: original)
        }
        let sameIdentifier = try XPostCopyPolicy.generationContext(source: myGoSource.replacingOccurrences(of: "your Go code", with: "a modified program"), tone: .calm)
        #expect(sameIdentifier.fragments.map(\.id) == context.fragments.map(\.id))
        #expect(throws: XPostCopyPolicy.CopyError.malformed) {
            try XPostCopyPolicy.extract(safe, context: sameIdentifier, correctingPunctuationOf: original)
        }
    }

    @Test("La reparación ortográfica identifica el campo y conserva la frase limpia")
    func spellingRepairKeepsCleanField() throws {
        let context = try XPostCopyPolicy.generationContext(source: fetchedMyGoSource, tone: .impactful)
        let original = try XPostCopyPolicy.extract(#"{"gancho":"Ejecuta MyGo para generar interfaces nativas en Go.","utilidad":"Descubre cómo integrar servicios tipados directamente desde Go a la web."}"#, context: context)
        #expect(throws: XPostCopyPolicy.CopyError.spelling(["tipados"])) {
            try XPostCopyPolicy.validate(original, source: fetchedMyGoSource, context: context, language: "es", tone: .impactful, budget: 212, spellingIssues: ["tipados"])
        }
        let prompt = XPostCopyPolicy.prompt(source: fetchedMyGoSource, context: context, title: "MyGo", language: "es", tone: .impactful,
                                            angle: "Descubrimiento", audience: "Desarrolladores", budget: 212,
                                            repair: .spelling(["tipados"]), rejectedCopy: original)
        #expect(prompt.user.contains(original.gancho))
        #expect(prompt.user.contains(original.utilidad))
        #expect(prompt.user.contains("utilidad: tipados"))
        #expect(prompt.user.contains("Conserva gancho exactamente"))
        let repaired = try XPostCopyPolicy.extract(#"{"gancho":"Otra apertura que el modelo cambió sin necesidad.","utilidad":"Desde la web puedes llamar a servicios escritos en Go."}"#,
                                                  context: context, correctingSpellingOf: original, spellingWords: ["tipados"])
        #expect(Array(repaired.gancho.utf8) == Array(original.gancho.utf8))
        #expect(repaired.apoyo == context.support)
        #expect(try XPostCopyPolicy.validate(repaired, source: fetchedMyGoSource, context: context, language: "es", tone: .impactful, budget: 212) == repaired.text)
        let changedContext = try XPostCopyPolicy.generationContext(source: fetchedMyGoSource.replacingOccurrences(of: "typed events", with: "changed events"), tone: .impactful)
        #expect(throws: XPostCopyPolicy.CopyError.malformed) {
            try XPostCopyPolicy.extract(#"{"gancho":"Una apertura diferente.","utilidad":"Desde la web puedes llamar a servicios escritos en Go."}"#,
                                        context: changedContext, correctingSpellingOf: original, spellingWords: ["tipados"])
        }
    }

    @Test("La frase reparada conserva las guardas y no admite palabras ni contexto ajenos")
    func spellingRepairKeepsGuards() throws {
        let context = try XPostCopyPolicy.generationContext(source: sdkSource, tone: .curiosity)
        let original = try XPostCopyPolicy.extract(#"{"gancho":"¿Cómo puedes crear aplicaciones con MyGo?","utilidad":"El recurso admite corticontextos para la interfaz."}"#, context: context)
        for (utility, expected) in [
            ("El extracto pide describir la interfaz.", XPostCopyPolicy.CopyError.instructionLeak),
            ("La GPU ofrece rendimiento en cualquier plataforma.", .unsupportedEvidence),
            ("La interfaz utiliza WebView2.", .unsupportedEvidence)
        ] {
            let raw = try String(decoding: JSONSerialization.data(withJSONObject: ["gancho": original.gancho, "utilidad": utility]), as: UTF8.self)
            let repaired = try XPostCopyPolicy.extract(raw, context: context, correctingSpellingOf: original, spellingWords: ["corticontextos"])
            #expect(throws: expected) {
                try XPostCopyPolicy.validate(repaired, source: sdkSource, context: context, language: "es", tone: .curiosity, budget: 212)
            }
        }
        #expect(throws: XPostCopyPolicy.CopyError.malformed) {
            try XPostCopyPolicy.extract(#"{"gancho":"¿Cómo puedes crear aplicaciones con MyGo?","utilidad":"La interfaz admite ventanas."}"#,
                                        context: context, correctingSpellingOf: original, spellingWords: ["palabra_ausente"])
        }
        #expect(throws: XPostCopyPolicy.CopyError.malformed) {
            try XPostCopyPolicy.extract(#"{"gancho":"¿Cómo puedes crear aplicaciones con MyGo?","utilidad":"La interfaz admite ventanas.","apoyo":["F1"]}"#,
                                        context: context, correctingSpellingOf: original, spellingWords: ["corticontextos"])
        }
    }

    @Test("La reparación de apoyo señala el identificador ajeno y conserva el campo limpio")
    func evidenceRepairKeepsCleanField() throws {
        let context = try XPostCopyPolicy.generationContext(source: sdkSource, tone: .impactful)
        #expect(!context.literalText.contains("APIs"))
        let original = try XPostCopyPolicy.extract(#"{"gancho":"Conecta APIs con los datos de la aplicación.","utilidad":"El cliente TypeScript conserva los tipos de los mensajes."}"#, context: context)
        #expect(throws: XPostCopyPolicy.CopyError.unsupportedEvidence) {
            try XPostCopyPolicy.validate(original, source: sdkSource, context: context, language: "es", tone: .impactful, budget: 212)
        }
        let prompt = XPostCopyPolicy.prompt(source: sdkSource, context: context, title: "Aster", language: "es", tone: .impactful,
                                            angle: "Descubrimiento", audience: "Desarrolladores", budget: 212,
                                            repair: .unsupportedEvidence, rejectedCopy: original)
        #expect(prompt.user.contains(original.gancho))
        #expect(prompt.user.contains(original.utilidad))
        #expect(prompt.user.contains("gancho: APIs"))
        #expect(prompt.user.contains("Conserva utilidad exactamente"))
        #expect(!prompt.user.contains("Desktop APIs"))
        let raw = #"{"gancho":"Conecta los datos de tu aplicación con Aster.","utilidad":"Una frase nueva que el modelo añadió por su cuenta."}"#
        let repaired = try XPostCopyPolicy.extract(raw, context: context, correctingEvidenceOf: original, source: sdkSource)
        #expect(Array(repaired.utilidad.utf8) == Array(original.utilidad.utf8))
        #expect(repaired.apoyo == context.support)
        #expect(try XPostCopyPolicy.validate(repaired, source: sdkSource, context: context, language: "es", tone: .impactful, budget: 212) == repaired.text)
        let changedContext = try XPostCopyPolicy.generationContext(source: sdkSource.replacingOccurrences(of: "los tipos", with: "otro contenido"), tone: .impactful)
        #expect(throws: XPostCopyPolicy.CopyError.malformed) {
            try XPostCopyPolicy.extract(raw, context: changedContext, correctingEvidenceOf: original, source: sdkSource)
        }
        #expect(throws: XPostCopyPolicy.CopyError.malformed) {
            try XPostCopyPolicy.extract(raw, context: context, correctingEvidenceOf: repaired, source: sdkSource)
        }
    }

    @Test("El campo con apoyo reparado vuelve a pasar todas las guardas sin ampliar la fuente")
    func evidenceRepairKeepsGuards() throws {
        let context = try XPostCopyPolicy.generationContext(source: sdkSource, tone: .curiosity)
        let original = try XPostCopyPolicy.extract(#"{"gancho":"¿Cómo conecta Aster los datos de una aplicación?","utilidad":"La interfaz emplea WebView2 para mostrar el contenido."}"#, context: context)
        #expect(!context.literalText.contains("WebView2"))
        for (utility, expected) in [
            ("La interfaz emplea WebView2 para mostrar el contenido.", XPostCopyPolicy.CopyError.unsupportedEvidence),
            ("La GPU ofrece rendimiento en cualquier plataforma.", .unsupportedEvidence),
            ("El extracto pide describir la interfaz.", .instructionLeak),
            (String(repeating: "La interfaz admite edición de texto. ", count: 8), .tooLong)
        ] {
            let raw = try String(decoding: JSONSerialization.data(withJSONObject: ["gancho": "Otra apertura que debe descartarse.", "utilidad": utility]), as: UTF8.self)
            let repaired = try XPostCopyPolicy.extract(raw, context: context, correctingEvidenceOf: original, source: sdkSource)
            #expect(Array(repaired.gancho.utf8) == Array(original.gancho.utf8))
            #expect(throws: expected) {
                try XPostCopyPolicy.validate(repaired, source: sdkSource, context: context, language: "es", tone: .curiosity, budget: 212)
            }
        }
        var batch = XPostGenerationBatch(draft: XPostDraft(text: "Borrador anterior editado."), tones: [.curiosity, .technical], suggestedHashtags: [])
        let copy = try XPostCopyPolicy.extract(#"{"gancho":"¿Cómo conecta Aster los datos de una aplicación?","utilidad":"El cliente TypeScript conserva los tipos de los mensajes."}"#, context: context, correctingEvidenceOf: original, source: sdkSource)
        let body = try XPostCopyPolicy.validate(copy, source: sdkSource, context: context, language: "es", tone: .curiosity, budget: 212)
        try batch.stage(tone: .curiosity, text: body, hashtags: [])
        #expect(throws: XPostGenerationBatch.BatchError.incomplete) { try batch.completedDraft() }
    }

    @Test("La reparación identifica rendimiento y conserva Unicode, tipos y apoyo del campo limpio")
    func performanceRepairKeepsExactCleanField() throws {
        let context = try XPostCopyPolicy.generationContext(source: sdkSource, tone: .curiosity)
        let original = try XPostCopyPolicy.extract(#"{"gancho":"¿Qué conserva Aster cuando envía un mensaje?","utilidad":"Su interfaz reduce la latencia al enviar mensajes."}"#, context: context)
        let indicators = XPostCopyPolicy.evidenceIndicators(original, source: sdkSource, context: context)
        #expect(indicators.unresolvedReferences == 0)
        #expect(indicators.unbackedTechnicalTerms == 0)
        #expect(indicators.unbackedPerformanceClauses == 1)
        let prompt = XPostCopyPolicy.prompt(source: sdkSource, context: context, title: "Aster", language: "es", tone: .curiosity,
                                            angle: "Descubrimiento", audience: "Desarrolladores", budget: 212,
                                            repair: .unsupportedEvidence, rejectedCopy: original)
        #expect(prompt.user.contains("utilidad: afirmación de rendimiento sin apoyo literal"))
        #expect(prompt.user.contains("Conserva gancho exactamente"))
        #expect(prompt.user.contains(context.literalText))
        #expect(!prompt.user.contains("const APIs"))
        let copy = try XPostCopyPolicy.extract(#"{"gancho":"¿Que conserva Aster cuando envia un mensaje?","utilidad":"Conserva texto Unicode como «mañana» y «quién»."}"#,
                                               context: context, correctingEvidenceOf: original, source: sdkSource)
        #expect(Array(copy.gancho.utf8) == Array(original.gancho.utf8))
        #expect(copy.apoyo.map { Array($0.utf8) } == context.support.map { Array($0.utf8) })
        #expect(try XPostCopyPolicy.validate(copy, source: sdkSource, context: context, language: "es", tone: .curiosity, budget: 212) == copy.text)
        #expect(throws: XPostCopyPolicy.CopyError.wrongLanguage) {
            try XPostCopyPolicy.validate(copy, source: sdkSource, context: context, language: "es", tone: .curiosity, budget: 212,
                                         languageAssessment: .init(code: "en", confidence: 0.99, requestedConfidence: 0.001))
        }
        #expect(throws: XPostCopyPolicy.CopyError.repeatedVariant) {
            try XPostCopyPolicy.validate(copy, source: sdkSource, context: context, language: "es", tone: .curiosity, budget: 212, previousTexts: [original.text])
        }
        #expect(throws: XPostCopyPolicy.CopyError.malformed) {
            try XPostCopyPolicy.extract(try responseJSON(copy), context: context, correctingEvidenceOf: original)
        }
        #expect(throws: XPostCopyPolicy.CopyError.malformed) {
            try XPostCopyPolicy.extract(try responseJSON(copy), context: context, correctingOpeningOf: original, correctingEvidenceOf: original, source: sdkSource)
        }
    }

    @Test("Si ambos campos carecen de apoyo, ninguno se conserva como si estuviera comprobado")
    func evidenceRepairHandlesBothFields() throws {
        let context = try XPostCopyPolicy.generationContext(source: sdkSource, tone: .technical)
        let original = try XPostCopyPolicy.extract(#"{"gancho":"Las APIs utilizan WebView2 en la interfaz.","utilidad":"WebView2 muestra los datos de una aplicación."}"#, context: context)
        #expect(XPostCopyPolicy.evidenceIndicators(original, source: sdkSource, context: context).unbackedTechnicalTerms == 2)
        let prompt = XPostCopyPolicy.prompt(source: sdkSource, context: context, title: "Aster", language: "es", tone: .technical,
                                            angle: "Descubrimiento", audience: "Desarrolladores", budget: 212,
                                            repair: .unsupportedEvidence, rejectedCopy: original)
        #expect(prompt.user.contains("gancho: APIs, WebView2"))
        #expect(prompt.user.contains("utilidad: WebView2"))
        #expect(!prompt.user.contains("Conserva gancho exactamente"))
        #expect(!prompt.user.contains("Conserva utilidad exactamente"))
        let raw = #"{"gancho":"TypeScript conserva los tipos de los mensajes.","utilidad":"La interfaz pública conecta los datos de una aplicación."}"#
        let copy = try XPostCopyPolicy.extract(raw, context: context, correctingEvidenceOf: original, source: sdkSource)
        #expect(copy.gancho != original.gancho)
        #expect(copy.utilidad != original.utilidad)
        #expect(copy.apoyo == original.apoyo)
        #expect(try XPostCopyPolicy.validate(copy, source: sdkSource, context: context, language: "es", tone: .technical, budget: 212) == copy.text)
        #expect(throws: XPostCopyPolicy.CopyError.malformed) {
            try XPostCopyPolicy.extract(raw.dropLast().description + #", "apoyo":["F1"]}"#, context: context, correctingEvidenceOf: original, source: sdkSource)
        }
    }

    @Test("El reintento lleva feedback y el lote admite solo dos intentos adicionales")
    func boundedCopyRepair() {
        var retries = XPostCopyRetryBudget()
        let first = retries.consume(for: .impactful)
        let repeated = retries.consume(for: .impactful)
        let second = retries.consume(for: .curiosity)
        let third = retries.consume(for: .technical)
        #expect(first)
        #expect(!repeated)
        #expect(second)
        #expect(!third)
        let original = XPostCopyPolicy.prompt(source: myGoSource, title: "MyGo", language: "es", tone: .impactful, angle: "Descubrimiento", audience: "Desarrolladores", budget: 230)
        let repair = XPostCopyPolicy.prompt(source: myGoSource, title: "MyGo", language: "es", tone: .impactful, angle: "Descubrimiento", audience: "Desarrolladores", budget: 230, repair: .wrongLanguage)
        #expect(original.user.contains(myGoSource))
        #expect(repair.user.contains(myGoSource))
        #expect(repair.user != original.user)
        #expect(repair.user.contains("español"))
        #expect(original.system.contains("JSON"))
    }

    @Test("El borrador 1.59 conserva texto y opciones al añadir variantes")
    func legacyDraftMigration() throws {
        let data = Data(#"{"text":"Mi texto revisado","angle":"Recomendación práctica","audience":"Diseñadores","language":"es","updatedAt":0}"#.utf8)
        let draft = try JSONDecoder().decode(XPostDraft.self, from: data)
        #expect(draft.text == "Mi texto revisado")
        #expect(draft.angle == "Recomendación práctica")
        #expect(draft.audience == "Diseñadores")
        #expect(draft.hashtagMode == .none)
        #expect(draft.variants.count == 1)
        #expect(draft.selectedVariant?.text == draft.text)
    }

    @Test("Seleccionar otra variante conserva la edición de la anterior")
    func variantEditsSurviveSelection() throws {
        var draft = XPostDraft()
        draft.acceptGeneratedVariant(tone: .impactful, text: "Texto A", hashtags: [])
        let first = try #require(draft.selectedVariantID)
        draft.updateSelectedText("Texto A editado")
        draft.acceptGeneratedVariant(tone: .calm, text: "Texto B", hashtags: [])
        draft.selectVariant(first)
        #expect(draft.text == "Texto A editado")
        #expect(draft.variants.count == 2)
    }

    @Test("Los hashtags se normalizan y solo se sugieren términos de la fuente")
    func sourceHashtags() {
        #expect(XPostPolicy.normalizedHashtags("#Swift, swift #Diseño 123 #IA inválido-tag") == ["Swift", "Diseño", "IA", "inválidotag"])
        let suggestions = XPostPolicy.suggestedHashtags(title: "SwiftUI y Swift", source: "SwiftUI para crear apps de macOS.", tags: ["Tendencia", "macOS", "SwiftUI"])
        #expect(suggestions.contains("SwiftUI"))
        #expect(suggestions.contains("macOS"))
        #expect(!suggestions.contains("Tendencia"))
    }

    @Test("La regeneración de un tono conserva los demás y la selección persiste")
    func regenerationAndRoundTrip() throws {
        var draft = XPostDraft()
        draft.acceptGeneratedVariant(tone: .impactful, text: "A #Swift", hashtags: ["Swift"])
        let firstID = try #require(draft.selectedVariantID)
        draft.acceptGeneratedVariant(tone: .technical, text: "B", hashtags: [])
        draft.updateSelectedText("B revisado")
        draft.acceptGeneratedVariant(tone: .impactful, text: "A regenerado", hashtags: [])
        #expect(draft.variants.count == 2)
        #expect(draft.selectedVariantID == firstID)
        #expect(draft.variants.first { $0.tone == .technical }?.text == "B revisado")
        draft.hashtagMode = .manual
        draft.manualHashtags = "#Swift"
        let decoded = try JSONDecoder().decode(XPostDraft.self, from: XPostDraftStore.encodedDraft(draft))
        #expect(decoded == draft)
    }

    @Test("Un lote incompleto conserva todas las variantes editadas")
    func incompleteBatchPreservesDraft() throws {
        var original = XPostDraft(text: "Calmado editado")
        original.acceptGeneratedVariant(tone: .impactful, text: "Impactante editado", hashtags: [])
        let saved = try XPostDraftStore.encodedDraft(original)
        var batch = XPostGenerationBatch(draft: original, tones: XPostTone.allCases, suggestedHashtags: ["Swift"])
        try batch.stage(tone: .impactful, text: "Impactante nuevo", hashtags: [])
        #expect(throws: XPostGenerationBatch.BatchError.self) { try batch.completedDraft() }
        #expect(try JSONDecoder().decode(XPostDraft.self, from: saved) == original)
        for tone in XPostTone.allCases where tone != .impactful {
            try batch.stage(tone: tone, text: tone.title + " nuevo", hashtags: [])
        }
        let completed = try batch.completedDraft()
        #expect(completed.variants.count == 5)
        #expect(completed.variants.first { $0.tone == .impactful }?.text == "Impactante nuevo")
        #expect(completed.suggestedHashtags == ["Swift"])
    }

    @Test("Cancelar un lote terminado impide entregar la transacción")
    func cancelledBatchDoesNotCommit() async throws {
        let original = XPostDraft(text: "Texto revisado antes de generar")
        let saved = try XPostDraftStore.encodedDraft(original)
        let task = Task {
            var batch = XPostGenerationBatch(draft: original, tones: [.calm], suggestedHashtags: [])
            try batch.stage(tone: .calm, text: "Texto generado", hashtags: [])
            withUnsafeCurrentTask { $0?.cancel() }
            return try batch.completedDraft()
        }
        do {
            _ = try await task.value
            Issue.record("Un lote cancelado no debe devolver un borrador para guardar.")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(try JSONDecoder().decode(XPostDraft.self, from: saved) == original)
    }

    @Test("La composición deduplica hashtags sin registrar los escritos por el autor")
    func authoredHashtagsArePreserved() throws {
        let url = try #require(URL(string: "https://example.org/recurso"))
        let body = "Mi texto sobre #Swift y #Diseño conserva su voz."
        let result = XPostPolicy.composition(body, source: url, hashtags: ["swift", "Diseno", "IA"])
        #expect(result.text == body + "\n\n#IA\n\n" + url.absoluteString)
        #expect(result.appliedHashtags == ["IA"])
        let withoutManaged = XPostPolicy.removingHashtags(result.text, only: result.appliedHashtags)
        let removed = XPostPolicy.composed(withoutManaged, source: url)
        #expect(removed == body + "\n\n" + url.absoluteString)
        let duplicate = XPostPolicy.composed("Uso #Swift y #swift", source: url, hashtags: ["SWIFT"])
        #expect(duplicate.components(separatedBy: "#").count == 2)
        let edited = "Mi #Swift merece guardarse.\n\n#Diseño\n\n" + url.absoluteString
        let applied = XPostPolicy.applyingHashtags(to: edited, source: url, hashtags: ["swift", "Diseno", "IA"], previousApplied: ["Swift", "Diseño"])
        #expect(applied.text == "Mi #Swift merece guardarse.\n\n#Diseno #IA\n\n" + url.absoluteString)
        #expect(applied.appliedHashtags == ["Diseno", "IA"])
    }

    @Test("Los hashtags y la fuente caben incluso con Unicode de peso doble")
    func hashtagBudget() throws {
        let url = try #require(URL(string: "https://example.org/recurso"))
        let result = XPostPolicy.composed(String(repeating: "你好 ", count: 100), source: url, hashtags: ["Swift", "Diseño", "Swift", "Extra", "Ignorado"])
        #expect(XPostPolicy.weightedLength(result) <= 280)
        #expect(result.hasSuffix(url.absoluteString))
        #expect(result.contains("#Swift #Diseño #Extra"))
        #expect(!result.contains("#Ignorado"))
        #expect(XPostPolicy.weightedLength("example.com") == 23)
        #expect(XPostPolicy.weightedLength("©️👩🏽‍💻1️⃣") == 6)
    }

    @Test("El JSON mantiene su cota al acumular variantes")
    func variantsStorageBound() throws {
        var draft = XPostDraft()
        for tone in XPostTone.allCases {
            draft.acceptGeneratedVariant(tone: tone, text: String(repeating: "a", count: 9_000), hashtags: [])
        }
        #expect(throws: XPostDraftStore.StoreError.self) { try XPostDraftStore.encodedDraft(draft) }
        draft.variants.append(XPostVariant(tone: .calm, text: "Duplicado"))
        #expect(throws: XPostDraftStore.StoreError.self) { try XPostDraftStore.encodedDraft(draft) }
    }

    @Test("Cuenta Unicode y URLs según el límite de X")
    func countsWeightedText() {
        #expect(XPostPolicy.weightedLength("cafe\u{301}") == 4)
        #expect(XPostPolicy.weightedLength(String(repeating: "a", count: 278) + "1\u{20E3}") == 280)
        #expect(XPostPolicy.weightedLength("👨‍👩‍👧‍👦🇪🇸你好") == 8)
        #expect(XPostPolicy.weightedLength("Hola https://example.com/una/ruta/larga") == 28)
        #expect(XPostPolicy.weightedLength("a https://example.com b https://example.org") == 51)
        #expect(XPostPolicy.weightedLength("a\u{FE0F}") == 3)
        #expect(XPostPolicy.weightedLength("\u{200D}\u{200E}\u{2010}\u{2032}") == 5)
    }
    @Test("Un borrador largo conserva el enlace original y cabe")
    func preservesSource() throws {
        let url = try #require(URL(string: "https://example.org/resource?a=1&b=2"))
        let text = XPostPolicy.composed(String(repeating: "Recurso útil con mucha información. ", count: 30) + "https://inventado.example", source: url)
        #expect(text.hasSuffix(url.absoluteString))
        #expect(!text.contains("inventado.example"))
        #expect(XPostPolicy.weightedLength(text) <= 280)
    }
    @Test("Solo un borrador válido abre el compositor y conserva caracteres reservados")
    func intentEncoding() throws {
        #expect(XPostPolicy.intentURL(text: String(repeating: "a", count: 281)) == nil)
        #expect(XPostPolicy.intentURL(text: "  ") == nil)
        let original = "¿Te sirve? IA + 3D #recursos\nhttps://example.org/?a=1&b=2"
        let intent = try #require(XPostPolicy.intentURL(text: original))
        #expect(URLComponents(url: intent, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == original)
        #expect(intent.host() == "x.com")
    }
    @Test("No conserva el razonamiento ni las URLs propuestas por el modelo")
    func stripsInternalText() throws {
        let url = try #require(URL(string: "https://example.org"))
        #expect(XPostPolicy.composed("<think>secreto</think>Recurso útil https://otro.example", source: url) == "Recurso útil\n\nhttps://example.org")
        #expect(XPostPolicy.composed("<think>razonamiento incompleto", source: url) == url.absoluteString)
    }

    @Test("El límite se aplica al JSON escapado antes de reemplazar un borrador")
    func encodedDraftLimit() throws {
        let oversized = XPostDraft(text: String(repeating: "\"", count: 24_000))
        #expect(throws: XPostDraftStore.StoreError.self) { try XPostDraftStore.encodedDraft(oversized) }
        let draft = XPostDraft(text: String(repeating: "Recurso útil ", count: 1000))
        let data = try XPostDraftStore.encodedDraft(draft)
        #expect(data.count <= XPostDraftStore.maximumEncodedBytes)
        #expect(try JSONDecoder().decode(XPostDraft.self, from: data) == draft)
    }
}

@Suite("Inicio discreto de Stacklume")
struct StacklumeLaunchPolicyTests {
    @Test("Login y argumento explícito abren solo la barra; Finder abre biblioteca")
    func launchIntent() {
        #expect(StacklumeLaunchPolicy.startsInMenuBar(arguments: ["Stacklume"], loginEvent: true))
        #expect(StacklumeLaunchPolicy.startsInMenuBar(arguments: ["Stacklume", "--menu-bar"], loginEvent: false))
        #expect(!StacklumeLaunchPolicy.startsInMenuBar(arguments: ["Stacklume"], loginEvent: false))
    }
    @Test("Reconoce el Apple Event real de inicio de sesión")
    func loginAppleEvent() {
        let event = NSAppleEventDescriptor(eventClass: 0x61657674, eventID: 0x6F617070, targetDescriptor: nil, returnID: -1, transactionID: 0)
        event.setParam(NSAppleEventDescriptor(enumCode: 0x6C676974), forKeyword: 0x70726474)
        #expect(StacklumeLaunchPolicy.isLoginEvent(event))
        let normal = NSAppleEventDescriptor(eventClass: 0x61657674, eventID: 0x6F617070, targetDescriptor: nil, returnID: -1, transactionID: 0)
        #expect(!StacklumeLaunchPolicy.isLoginEvent(normal))
    }
}

@Suite("Protocolo provisional de auditoría X; veredictos declarados, sin LLM")
struct XPostBatchAuditTests {
    private let source = "Aster creates desktop applications from Go code. The TypeScript client is generated from your Go code. Its native interface is drawn on the GPU and supports text editing, screen readers and deep links."

    private func context() throws -> XPostCopyPolicy.GenerationContext {
        try XPostCopyPolicy.generationContext(source: source, tone: .calm)
    }

    private func rows() -> [[String: Any]] {
        let hooks: [XPostTone: String] = [
            .impactful: "Crea aplicaciones de escritorio con Aster.",
            .curiosity: "¿Cómo crea Aster una aplicación de escritorio?",
            .calm: "Aster crea aplicaciones de escritorio en Go.",
            .technical: "TypeScript se genera desde tu código Go.",
            .educational: "Si programas en Go, Aster lleva tu aplicación al escritorio."
        ]
        return XPostTone.allCases.map {
            ["tono": $0.rawValue, "gancho": hooks[$0]!, "utilidad": "La interfaz nativa admite edición de texto y lectores de pantalla."]
        }
    }

    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private func batch() throws -> XPostCopyBatch {
        try XPostGroupedCopyPolicy.extract(json(["variantes": rows()]), tones: XPostTone.allCases, context: context())
    }

    private func auditRows() -> [[String: Any]] {
        return XPostTone.allCases.map { tone in
            let hookQuote = tone == .technical ? "The TypeScript client is generated from your Go code." : "Aster creates desktop applications from Go code."
            return ["tono": tone.rawValue,
                    "gancho": ["estado": "aprobado", "apoyos": [["id": "F1", "cita": hookQuote]]],
                    "utilidad": ["estado": "aprobado", "apoyos": [["id": "F1", "cita": "Its native interface is drawn on the GPU and supports text editing, screen readers and deep links."]]]]
        }
    }

    @Test("La generación agrupada exige exactamente los cinco tonos y dos frases por tono")
    func closedGroupedGeneration() throws {
        let value = try batch()
        #expect(Set(value.copies.keys) == Set(XPostTone.allCases))
        #expect(value.copies.values.allSatisfy { $0.apoyo == value.context.support })
        var duplicate = rows()
        duplicate[4] = duplicate[0]
        var extraField = rows()
        extraField[0]["apoyo"] = ["F1"]
        var absentField = rows()
        absentField[1].removeValue(forKey: "utilidad")
        var unknown = rows()
        unknown[0]["tono"] = "inventado"
        for invalid in [duplicate, extraField, absentField, unknown, Array(rows().dropLast())] {
            #expect(throws: XPostCopyPolicy.CopyError.malformed) {
                try XPostGroupedCopyPolicy.extract(json(["variantes": invalid]), tones: XPostTone.allCases, context: context())
            }
        }
        #expect(throws: XPostCopyPolicy.CopyError.malformed) {
            try XPostGroupedCopyPolicy.extract(json(["variantes": rows(), "comentario": "instrucciones"]), tones: XPostTone.allCases, context: context())
        }
    }

    @Test("Una cita de auditoría exige ID enviado y bytes literales, sin fuente adicional")
    func auditQuoteProvenance() throws {
        let value = try batch()
        let accepted = try XPostSemanticAuditPolicy.extract(json(["variantes": auditRows()]), batch: value)
        #expect(accepted.issues.isEmpty)
        for reference in [
            ["id": "F99", "cita": "Its native interface is drawn on the GPU"],
            ["id": "F1", "cita": "Its native interface is faster on the GPU"],
            ["id": "F1", "cita": source + " Extra source"],
            ["id": "F1", "cita": "GPU"]
        ] {
            var audit = auditRows()
            audit[0]["gancho"] = ["estado": "aprobado", "apoyos": [reference]]
            #expect(throws: XPostSemanticAuditPolicy.AuditError.invalidProvenance) {
                try XPostSemanticAuditPolicy.extract(json(["variantes": audit]), batch: value)
            }
        }
        var extraSource = auditRows()
        extraSource[0]["fuente"] = source
        #expect(throws: XPostSemanticAuditPolicy.AuditError.malformed) {
            try XPostSemanticAuditPolicy.extract(json(["variantes": extraSource]), batch: value)
        }
        var duplicate = auditRows()
        duplicate[4] = duplicate[0]
        #expect(throws: XPostSemanticAuditPolicy.AuditError.malformed) {
            try XPostSemanticAuditPolicy.extract(json(["variantes": duplicate]), batch: value)
        }
    }

    @Test("Las traducciones y contradicciones declaradas por un evaluador bloquean la entrega")
    func declaredSemanticRejections() throws {
        var candidates = rows()
        candidates[0]["utilidad"] = "Ofrece lectores de pantalla y asignaciones profundas."
        candidates[1]["gancho"] = "¿Puedes iniciar Aster sin ejecutar la aplicación?"
        candidates[1]["utilidad"] = "Sí, lanza la app directamente."
        let value = try XPostGroupedCopyPolicy.extract(json(["variantes": candidates]), tones: XPostTone.allCases, context: context())
        for tone in [XPostTone.impactful, .curiosity] {
            let copy = value.copies[tone]!
            #expect(try XPostCopyPolicy.validate(copy, source: source, context: value.context, language: "es", tone: tone, budget: 212) == copy.text)
        }
        var audit = auditRows()
        audit[0]["utilidad"] = ["estado": "traduccion", "apoyos": [["id": "F1", "cita": "screen readers and deep links"]]]
        audit[1]["gancho"] = ["estado": "coherencia", "apoyos": []]
        audit[1]["utilidad"] = ["estado": "coherencia", "apoyos": []]
        let verdict = try XPostSemanticAuditPolicy.extract(json(["variantes": audit]), batch: value)
        #expect(verdict.issues.count == 3)
        #expect(verdict.issues.contains { $0.tone == .impactful && $0.field == .utilidad && $0.reason == .traduccion })
        var workflow = XPostAuditedBatchWorkflow()
        try workflow.beginGeneration()
        workflow.stage(value)
        try workflow.markLexicallyValid(revision: value.revision)
        try workflow.beginAudit()
        try workflow.receive(verdict)
        #expect(throws: XPostSemanticAuditPolicy.AuditError.notApproved) { try workflow.completedBatch() }
    }

    @Test("La procedencia literal no certifica rapidez, eco editorial ni coherencia; decide un evaluador declarado")
    func declaredEvaluatorClosesLexicalBlindSpots() throws {
        for (utility, status) in [
            ("Haz las aplicaciones más rápidas con GPU.", "apoyo"),
            ("Admite lectores de pantalla sin ventajas.", "redaccion")
        ] {
            var candidates = rows()
            candidates[3]["gancho"] = "La interfaz nativa se dibuja en la GPU."
            candidates[3]["utilidad"] = utility
            let value = try XPostGroupedCopyPolicy.extract(json(["variantes": candidates]), tones: XPostTone.allCases, context: context())
            let copy = value.copies[.technical]!
            #expect(try XPostCopyPolicy.validate(copy, source: source, context: value.context, language: "es", tone: .technical, budget: 212) == copy.text)
            var response = auditRows()
            response[3]["gancho"] = ["estado": "aprobado", "apoyos": [["id": "F1", "cita": "Its native interface is drawn on the GPU"]]]
            response[3]["utilidad"] = ["estado": status, "apoyos": [["id": "F1", "cita": "Its native interface is drawn on the GPU"]]]
            let rejected = try XPostSemanticAuditPolicy.extract(json(["variantes": response]), batch: value)
            #expect(rejected.issues.count == 1)
            #expect(rejected.issues.first?.field == .utilidad)
            #expect(rejected.issues.first?.reason.rawValue == status)
        }
    }

    @Test("La igualdad canónica de Unicode no sustituye la cita byte exacta")
    func auditQuoteRequiresUTF8Identity() throws {
        let unicodeSource = source + " Conserva Unicode como «mañana» y «quién»."
        let unicodeContext = try XPostCopyPolicy.generationContext(source: unicodeSource, tone: .calm)
        let value = try XPostGroupedCopyPolicy.extract(json(["variantes": rows()]), tones: XPostTone.allCases, context: unicodeContext)
        let exact = "Conserva Unicode como «mañana» y «quién»."
        var response = auditRows()
        response[0]["gancho"] = ["estado": "aprobado", "apoyos": [["id": "F1", "cita": exact]]]
        #expect(try XPostSemanticAuditPolicy.extract(json(["variantes": response]), batch: value).issues.isEmpty)
        let decomposed = exact.decomposedStringWithCanonicalMapping
        #expect(decomposed == exact)
        #expect(Array(decomposed.utf8) != Array(exact.utf8))
        response[0]["gancho"] = ["estado": "aprobado", "apoyos": [["id": "F1", "cita": decomposed]]]
        #expect(throws: XPostSemanticAuditPolicy.AuditError.invalidProvenance) {
            try XPostSemanticAuditPolicy.extract(json(["variantes": response]), batch: value)
        }
    }

    @Test("Un campo no rechazado conserva Unicode y mayúsculas exactas; el contexto no se amplía")
    func fieldRepairKeepsExactContent() throws {
        let original = try batch()
        let issue = XPostCopyFieldIssue(tone: .technical, field: .gancho, reason: .traduccion)
        var response = rows()
        response[3]["gancho"] = "TypeScript se genera desde Go para la interfaz."
        response[3]["utilidad"] = "Otra utilidad que debe descartarse."
        response[0]["gancho"] = "Una apertura ajena que debe descartarse."
        let repaired = try XPostGroupedCopyPolicy.extract(json(["variantes": response]), tones: XPostTone.allCases,
                                                         context: original.context, repairing: original, issues: [issue])
        #expect(Array(repaired.copies[.technical]!.utilidad.utf8) == Array(original.copies[.technical]!.utilidad.utf8))
        #expect(repaired.copies[.impactful] == original.copies[.impactful])
        #expect(repaired.revision != original.revision)
        #expect(repaired.copies[.technical]!.apoyo == original.context.support)
        let modified = try XPostCopyPolicy.generationContext(source: source.replacingOccurrences(of: "deep links", with: "different links"), tone: .calm)
        #expect(throws: XPostCopyPolicy.CopyError.malformed) {
            try XPostGroupedCopyPolicy.extract(json(["variantes": response]), tones: XPostTone.allCases,
                                               context: modified, repairing: original, issues: [issue])
        }
    }

    @Test("Una auditoría antigua no autoriza texto reparado y toda reparación exige reauditar")
    func auditRevisionCannotEscape() throws {
        let original = try batch()
        let audit = try XPostSemanticAuditPolicy.extract(json(["variantes": auditRows()]), batch: original)
        var workflow = XPostAuditedBatchWorkflow()
        try workflow.beginGeneration()
        workflow.stage(original)
        #expect(throws: XPostSemanticAuditPolicy.AuditError.notApproved) { try workflow.completedBatch() }
        #expect(throws: XPostSemanticAuditPolicy.AuditError.notApproved) { try workflow.beginAudit() }
        try workflow.markLexicallyValid(revision: original.revision)
        try workflow.beginAudit()
        try workflow.receive(audit)
        #expect(try workflow.completedBatch().revision == original.revision)
        try workflow.beginRepair()
        let repaired = try XPostGroupedCopyPolicy.extract(json(["variantes": rows()]), tones: XPostTone.allCases, context: original.context,
                                                         repairing: original, issues: [.init(tone: .calm, field: .utilidad, reason: .coherencia)])
        workflow.stage(repaired)
        #expect(throws: XPostSemanticAuditPolicy.AuditError.notApproved) { try workflow.completedBatch() }
        #expect(throws: XPostSemanticAuditPolicy.AuditError.staleRevision) { try workflow.receive(audit) }
        try workflow.markLexicallyValid(revision: repaired.revision)
        try workflow.beginAudit()
        let fresh = try XPostSemanticAuditPolicy.extract(json(["variantes": auditRows()]), batch: repaired)
        try workflow.receive(fresh)
        #expect(try workflow.completedBatch().revision == repaired.revision)
        #expect(workflow.calls == 4)
        #expect(workflow.repairs == 1)
    }

    @Test("El presupuesto reserva reauditoría y mantiene siete llamadas y dos reparaciones")
    func boundedAuditBudget() throws {
        let value = try batch()
        var workflow = XPostAuditedBatchWorkflow()
        try workflow.beginGeneration()
        workflow.stage(value)
        for _ in 0..<5 {
            try workflow.markLexicallyValid(revision: value.revision)
            try workflow.beginAudit()
        }
        #expect(workflow.calls == 6)
        #expect(throws: XPostSemanticAuditPolicy.AuditError.budget) { try workflow.beginRepair() }
        try workflow.beginAudit()
        #expect(workflow.calls == 7)
        #expect(throws: XPostSemanticAuditPolicy.AuditError.budget) { try workflow.beginAudit() }
        var repairs = XPostAuditedBatchWorkflow()
        try repairs.beginGeneration()
        repairs.stage(value)
        try repairs.beginRepair()
        try repairs.beginRepair()
        #expect(repairs.repairs == 2)
        #expect(throws: XPostSemanticAuditPolicy.AuditError.budget) { try repairs.beginRepair() }
    }

    @Test("Dos reparaciones con auditoría independiente requieren seis llamadas y conservan el borrador previo")
    func completeTwoRepairRoundsWithinSeven() throws {
        let originalDraft = XPostDraft(text: "Texto revisado por el autor, aún sin reemplazar.")
        let stored = try XPostDraftStore.encodedDraft(originalDraft)
        var value = try batch()
        var workflow = XPostAuditedBatchWorkflow()
        try workflow.beginGeneration()
        workflow.stage(value)
        for _ in 0..<2 {
            try workflow.markLexicallyValid(revision: value.revision)
            try workflow.beginAudit()
            var rejected = auditRows()
            rejected[4]["utilidad"] = ["estado": "coherencia", "apoyos": []]
            let verdict = try XPostSemanticAuditPolicy.extract(json(["variantes": rejected]), batch: value)
            try workflow.receive(verdict)
            #expect(throws: XPostSemanticAuditPolicy.AuditError.notApproved) { try workflow.completedBatch() }
            try workflow.beginRepair()
            value = try XPostGroupedCopyPolicy.extract(json(["variantes": rows()]), tones: XPostTone.allCases,
                                                       context: value.context, repairing: value, issues: verdict.issues)
            workflow.stage(value)
        }
        try workflow.markLexicallyValid(revision: value.revision)
        try workflow.beginAudit()
        try workflow.receive(XPostSemanticAuditPolicy.extract(json(["variantes": auditRows()]), batch: value))
        #expect(try workflow.completedBatch().revision == value.revision)
        #expect(workflow.calls == 6)
        #expect(workflow.repairs == 2)
        #expect(try JSONDecoder().decode(XPostDraft.self, from: stored) == originalDraft)
    }

    @Test("Cancelar después de aprobar impide entregar incluso una auditoría vigente")
    func cancellationPreventsAuditedCommit() async throws {
        let value = try batch()
        let audit = try XPostSemanticAuditPolicy.extract(json(["variantes": auditRows()]), batch: value)
        let task = Task {
            var workflow = XPostAuditedBatchWorkflow()
            try workflow.beginGeneration()
            workflow.stage(value)
            try workflow.markLexicallyValid(revision: value.revision)
            try workflow.beginAudit()
            try workflow.receive(audit)
            withUnsafeCurrentTask { $0?.cancel() }
            return try workflow.completedBatch()
        }
        do { _ = try await task.value; Issue.record("No debe entregar un lote cancelado.") }
        catch { #expect(error is CancellationError) }
    }
    @Test("La reparación agrupada de puntuación conserva Unicode, unidades y campos no rechazados")
    func groupedPunctuationPreservesEveryOtherByte() throws {
        var initial = rows()
        initial[3]["gancho"] = "TypeScript — permite saber quién llama a Go."
        let original = try XPostGroupedCopyPolicy.extract(json(["variantes": initial]), tones: XPostTone.allCases, context: context())
        let issue = XPostCopyFieldIssue(tone: .technical, field: .gancho, reason: .puntuacion)
        var revised = initial
        revised[3]["gancho"] = "TypeScript , permite saber quién llama a Go."
        revised[3]["utilidad"] = "El modelo intenta modificar este campo limpio."
        let accepted = try XPostGroupedCopyPolicy.extract(json(["variantes": revised]), tones: XPostTone.allCases,
                                                         context: original.context, repairing: original, issues: [issue])
        #expect(accepted.copies[.technical]!.gancho == "TypeScript , permite saber quién llama a Go.")
        #expect(Array(accepted.copies[.technical]!.utilidad.utf8) == Array(original.copies[.technical]!.utilidad.utf8))
        for altered in ["TypeScript , permite saber quien llama a Go.", "typescript , permite saber quién llama a Go.",
                        "TypeScript , permite saber quién llama a Rust.", "TypeScript permite saber quién llama a Go."] {
            revised[3]["gancho"] = altered
            #expect(throws: XPostCopyPolicy.CopyError.malformed) {
                try XPostGroupedCopyPolicy.extract(json(["variantes": revised]), tones: XPostTone.allCases,
                                                   context: original.context, repairing: original, issues: [issue])
            }
        }
    }

    @Test("Los motivos léxicos identifican solo el campo implicado para mantener la frase limpia")
    func lexicalRepairTargetsTheRejectedField() throws {
        var initial = rows()
        initial[0]["utilidad"] = "La interfaz nativa admite pantalla inventadiña."
        let value = try XPostGroupedCopyPolicy.extract(json(["variantes": [initial[0]]]), tones: [.impactful], context: context())
        let issues = XPostGroupedCopyPolicy.lexicalIssues(value, source: source, language: "es", budget: 212,
                                                        spelling: [.impactful: ["inventadiña"]])
        #expect(issues == [.init(tone: .impactful, field: .utilidad, reason: .ortografia, words: ["inventadiña"])])
    }

    @Test("El diagnóstico de lote no persiste texto, citas ni palabras rechazadas")
    func batchDiagnosticsContainOnlyStructureAndReasons() throws {
        let value = try batch()
        let raw = "<think>Contenido privado example.com/token</think>" + (try json(["variantes": rows()]))
        let diagnostic = XPostBatchDiagnostic(call: 3, phase: .repair, raw: raw, candidate: value,
                                             issues: [.init(tone: .technical, field: .gancho, reason: .apoyo,
                                                            words: ["sensible@example.com", "example.com/token"])])
        let encoded = String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self)
        #expect(!encoded.contains("example.com"))
        #expect(!encoded.contains("Aster"))
        #expect(!encoded.contains("TypeScript"))
        #expect(!encoded.contains("Contenido privado"))
        #expect(diagnostic.jsonParsed)
        #expect(diagnostic.responseVariants == 5)
        #expect(diagnostic.call == 3)
        #expect(diagnostic.rejections.count == 1)
    }
}
