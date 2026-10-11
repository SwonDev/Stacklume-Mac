import Testing
import Foundation

// `PackageReleaseFeed` se compila dentro del módulo de tests. Aquí solo se prueban las
// rutas DETERMINISTAS (sin red): extracción de slug, gestores soportados y los feeds de
// PyPI/Packagist/Go. Las rutas que consultan registros (npm/cargo/gem) NO se prueban
// aquí para no depender de la red.

@Suite("PackageReleaseFeed — feeds de versiones")
struct PackageReleaseFeedTests {

    @Test("Slug GitHub desde URL de repo (git+https y sufijo .git)")
    func slugFromRepoURL() {
        #expect(PackageReleaseFeed.githubSlug(fromRepoURL: "git+https://github.com/colinhacks/zod.git") == "colinhacks/zod")
        #expect(PackageReleaseFeed.githubSlug(fromRepoURL: "https://github.com/o/r/tree/v1") == "o/r")
    }

    @Test("Slug nil si el repo no es de GitHub")
    func slugNilForNonGitHub() {
        #expect(PackageReleaseFeed.githubSlug(fromRepoURL: "https://gitlab.com/o/r") == nil)
    }

    @Test("Slug desde ruta de módulo Go")
    func slugFromModulePath() {
        #expect(PackageReleaseFeed.githubSlug(fromModulePath: "github.com/foo/bar/cmd/x") == "foo/bar")
        #expect(PackageReleaseFeed.githubSlug(fromModulePath: "golang.org/x/tools") == nil)
    }

    @Test("isSupported por gestor")
    func supportedManagers() {
        #expect(PackageReleaseFeed.isSupported(manager: "pip"))
        #expect(PackageReleaseFeed.isSupported(manager: "npm"))
        #expect(!PackageReleaseFeed.isSupported(manager: "brew"))
        #expect(!PackageReleaseFeed.isSupported(manager: "dotnet"))
    }

    @Test("pip ⇒ RSS de PyPI (determinista, sin red)")
    func pipFeed() async {
        let r = await PackageReleaseFeed.resolve(manager: "pip", packageName: "requests")
        #expect(r?.feedURL == "https://pypi.org/rss/project/requests/releases.xml")
    }

    @Test("composer ⇒ RSS de Packagist; nil si falta vendor/")
    func composerFeed() async {
        let ok = await PackageReleaseFeed.resolve(manager: "composer", packageName: "symfony/console")
        #expect(ok?.feedURL == "https://packagist.org/feeds/package.symfony/console.rss")
        let bad = await PackageReleaseFeed.resolve(manager: "composer", packageName: "novendor")
        #expect(bad == nil)
    }

    @Test("go ⇒ releases.atom del repo GitHub")
    func goFeed() async {
        let r = await PackageReleaseFeed.resolve(manager: "go", packageName: "github.com/spf13/cobra")
        #expect(r?.feedURL == "https://github.com/spf13/cobra/releases.atom")
    }

    @Test("Gestor sin feed fiable ⇒ nil")
    func unsupportedReturnsNil() async {
        #expect(await PackageReleaseFeed.resolve(manager: "brew", packageName: "wget") == nil)
    }
}
