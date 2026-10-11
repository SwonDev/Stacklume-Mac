import Foundation
import Testing

@Suite("Catálogos de modelos")
struct ModelCatalogTests {
    @Test("Las descargas del mismo volumen no reservan el mismo espacio")
    func downloadReservationsShareVolumeCapacity() throws {
        let ledger = ModelCatalogCapacityLedger()
        let first = UUID(), second = UUID(), other = UUID()
        try ledger.reserve(first, volume: "volume-a", remaining: 70, available: 100)
        #expect(throws: (any Error).self) { try ledger.reserve(second, volume: "volume-a", remaining: 40, available: 100) }
        try ledger.reserve(second, volume: "volume-a", remaining: 30, available: 100)
        try ledger.reserve(other, volume: "volume-b", remaining: 100, available: 100)
        var wrote = false
        #expect(throws: (any Error).self) {
            try ledger.write(second, bytes: 31, available: { 100 }) { wrote = true }
        }
        #expect(!wrote)
        try ledger.write(first, bytes: 20, available: { 100 }) { wrote = true }
        #expect(wrote)
        ledger.release(first)
        try ledger.resize(second, remaining: 80, available: 80)
        ledger.release(second)
        try ledger.reserve(second, volume: "volume-a", remaining: 0, available: 10)
        #expect(throws: (any Error).self) { try ledger.write(second, bytes: 11, available: { 10 }) { Issue.record("Escritura sin espacio") } }
        try ledger.write(second, bytes: 10, available: { 10 }) { }
    }

    @Test("La búsqueda conserva filtros múltiples y cursores opacos sin credenciales en la URL")
    func searchPagination() throws {
        var filters = ModelCatalogFilters()
        filters.query = "pixel art"
        filters.types = "LORA, Checkpoint"
        filters.baseModels = "SDXL 1.0, Pony"
        let url = try ModelCatalogRequest.searchURL(provider: .civitai, filters: filters, cursor: "a|b +c")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.filter { $0.name == "types" }.map(\.value) == ["LORA", "Checkpoint"])
        #expect(items.filter { $0.name == "baseModels" }.map(\.value) == ["SDXL 1.0", "Pony"])
        #expect(items.first { $0.name == "cursor" }?.value == "a|b +c")
        #expect(items.first { $0.name == "nsfw" }?.value == "false")
        #expect(!items.contains { ["token", "api_key", "page"].contains($0.name) })
    }

    @Test("Un cursor de otro host o con token no se sigue")
    func rejectsCredentialPagination() throws {
        let current = try ModelCatalogRequest.searchURL(provider: .huggingFace, filters: .init())
        for address in ["https://huggingface.co.evil.test/api/models?cursor=a", "https://huggingface.co/api/models?token=secret", "http://huggingface.co/api/models?cursor=a", "https://user:pass@huggingface.co/api/models?cursor=a", "https://huggingface.co:444/api/models?cursor=a"] {
            #expect(ModelCatalogRequest.nextHuggingFaceURL(link: "<\(address)>; rel=\"next\"", current: current) == nil)
        }
        #expect(ModelCatalogRequest.nextHuggingFaceURL(link: "<https://huggingface.co/api/models?cursor=opaque>; rel=\"next\"", current: current)?.query == "cursor=opaque")
    }

    @Test("Las versiones de Civitai conservan identidad, licencia y muestras aptas")
    func decodesCivitaiVersion() throws {
        let data = Data(#"{"id":42,"name":"Modelo","type":"LORA","creator":{"username":"autor"},"allowDerivatives":true,"allowCommercialUse":["Image","Sell"],"modelVersions":[{"id":9,"name":"v2","baseModel":"SDXL 1.0","files":[{"name":"model.safetensors","sizeKB":1024}],"images":[{"url":"https://image.civitai.com/a/original=true/sample.jpeg","nsfwLevel":1},{"url":"https://image.civitai.com/a/original=true/adult.jpeg","nsfwLevel":4,"nsfw":false},{"url":"https://evil.test/image.jpeg","nsfwLevel":1}]}]}"#.utf8)
        let item = try ModelCatalogDecoding.detail(data: data, provider: .civitai)
        let version = try #require(item.versions.first)
        #expect(item.bookmarkURL(version: version)?.absoluteString == "https://civitai.com/models/42?modelVersionId=9")
        #expect(version.files.first?.sizeBytes == 1_048_576)
        #expect(item.visiblePreviews(includeAdult: false).count == 1)
        #expect(item.visiblePreviews(includeAdult: true).count == 2)
        #expect(item.allowsDerivatives == true)
        #expect(item.commercialUses == ["Image", "Sell"])
    }

    @Test("Hugging Face conserva el commit de la revisión y etiquetas de licencia")
    func huggingFaceRevision() throws {
        let data = Data(#"{"id":"org/model","sha":"abcdef123","tags":["license:apache-2.0","text-generation"],"gated":"manual","private":true,"siblings":[{"rfilename":"README.md"}]}"#.utf8)
        let item = try ModelCatalogDecoding.detail(data: data, provider: .huggingFace)
        #expect(item.licenses == ["apache-2.0"])
        #expect(item.isPrivate)
        #expect(item.gated == "manual")
        #expect(item.bookmarkURL(version: item.versions.first)?.absoluteString == "https://huggingface.co/org/model/tree/abcdef123")
        #expect(ModelCatalogRequest.modelURL(provider: .huggingFace, id: "org/../model") == nil)
    }

    @Test("Las muestras externas y las claves mal formadas se rechazan")
    func rejectsUnsafeMediaAndTokens() {
        for raw in ["https://image.civitai.com/a.jpeg?token=secret", "https://image.civitai.com.evil.test/a.jpeg", "http://image.civitai.com/a.jpeg", "https://image.civitai.com/a.svg", "https://image.civitai.com/a.mp4"] {
            #expect(ModelCatalogRequest.previewURL(raw, provider: .civitai) == nil)
        }
        for token in ["", " abc", "abc\n", "abc def", "Bearer abc"] { #expect(!ModelCatalogRequest.validToken(token)) }
        #expect(ModelCatalogRequest.validToken("hf_Example123"))
    }

    @Test("El filtrado local no transforma permisos desconocidos en concedidos")
    func permissionFiltering() throws {
        let item = try ModelCatalogDecoding.detail(data: Data(#"{"id":42,"name":"Modelo"}"#.utf8), provider: .civitai)
        var filters = ModelCatalogFilters(); filters.requireDerivatives = true
        #expect(!ModelCatalogDecoding.matchesLocalPermissions(item, filters: filters))
        #expect(ModelCatalogDecoding.plainDescription("<script>secret()</script><p>Texto &amp; licencia</p>") == "Texto & licencia")
    }

    @Test("El uso comercial se filtra en Civitai y la licencia singular conserva el permiso")
    func currentCivitaiLicensing() throws {
        var filters = ModelCatalogFilters(); filters.commercialUse = "SellMerge"; filters.fileFormats = "SafeTensor"
        let url = try ModelCatalogRequest.searchURL(provider: .civitai, filters: filters)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "allowCommercialUse" }?.value == "SellMerge")
        #expect(items.filter { $0.name == "fileFormats" }.count == 2)
        #expect(!items.contains { ["allowDerivatives", "allowNoCredit", "allowDifferentLicense"].contains($0.name) })
        let model = try ModelCatalogDecoding.detail(data: Data(#"{"id":42,"allowDifferentLicense":true}"#.utf8), provider: .civitai)
        #expect(model.allowsDifferentLicenses == true)
    }

    @Test("Una revisión histórica usa sus propias licencias y etiquetas, sin heredar las de main")
    func revisionMetadataIsBoundToCommit() throws {
        let main = try ModelCatalogDecoding.detail(data: Data(#"{"id":"org/model","sha":"current123","tags":["license:apache-2.0","text-generation"]}"#.utf8), provider: .huggingFace)
        let historical = try ModelCatalogDecoding.detail(data: Data(#"{"id":"org/model","sha":"historical456","tags":["license:mit","feature-extraction"]}"#.utf8), provider: .huggingFace)
        let selected = try #require(historical.versions.first)
        #expect(historical.metadataMatches(version: selected))
        #expect(historical.licenses(for: selected) == ["mit"])
        #expect(historical.tags(for: selected) == ["license:mit", "feature-extraction"])
        #expect(!main.metadataMatches(version: selected))
        #expect(main.licenses(for: selected).isEmpty)
        #expect(main.tags(for: selected).isEmpty)
        #expect(historical.bookmarkURL(version: selected)?.absoluteString == "https://huggingface.co/org/model/tree/historical456")
        let unverified = try ModelCatalogDecoding.detail(data: Data(#"{"id":"org/model","tags":["license:apache-2.0"]}"#.utf8), provider: .huggingFace)
        let unknownCommit = try #require(unverified.versions.first)
        #expect(!unverified.metadataMatches(version: unknownCommit))
        #expect(unverified.licenses(for: unknownCommit).isEmpty)
    }

    @Test("Los fallos de transporte distinguen conexión, espera y cancelación sin mostrar direcciones")
    func transportFeedback() {
        for code in [URLError.Code.notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .networkConnectionLost] {
            #expect(ModelCatalogError.transportError(code) as? ModelCatalogError == .connection)
        }
        #expect(ModelCatalogError.transportError(.timedOut) as? ModelCatalogError == .timeout)
        #expect(ModelCatalogError.transportError(.cannotParseResponse) as? ModelCatalogError == .invalidResponse)
        #expect(ModelCatalogError.transportError(.cancelled) is CancellationError)
        #expect(!(ModelCatalogError.connection.errorDescription ?? "").contains("http"))
    }

    @Test("La galería mantiene el modelo y la versión al paginar y solicita metadatos aptos")
    func communityGalleryRequest() throws {
        let url = try ModelCatalogRequest.communityURL(provider: .civitai, modelID: "4201", versionID: "130072", kind: .images, filters: .init(), includeAdult: false, cursor: "123|456")
        let fields = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(url.path == "/api/v1/images")
        #expect(fields.first { $0.name == "modelId" }?.value == "4201")
        #expect(fields.first { $0.name == "modelVersionId" }?.value == "130072")
        #expect(fields.first { $0.name == "cursor" }?.value == "123|456")
        #expect(fields.first { $0.name == "withMeta" }?.value == "true")
        #expect(fields.first { $0.name == "nsfw" }?.value == "false")
        #expect(fields.first { $0.name == "browsingLevel" }?.value == "3")
        let adultURL = try ModelCatalogRequest.communityURL(provider: .civitai, modelID: "4201", versionID: nil, kind: .images, filters: .init(), includeAdult: true)
        #expect(URLComponents(url: adultURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "browsingLevel" }?.value == "31")
        #expect(ModelCatalogRequest.mediaURL("https://image.civitai.com/a/original=true/example.mp4", provider: .civitai, kind: .video)?.pathExtension == "mp4")
        #expect(ModelCatalogRequest.mediaURL("https://evil.test/example.mp4", provider: .civitai, kind: .video) == nil)
    }

    @Test("La comunidad conserva vídeos, parámetros y clasificación sin seguir una continuación externa")
    func decodesCommunityMedia() throws {
        let url = try ModelCatalogRequest.communityURL(provider: .civitai, modelID: "42", versionID: "9", kind: .images, filters: .init(), includeAdult: false)
        let data = Data(#"{"items":[{"id":71,"type":"video","url":"https://image.civitai.com/a/original=true/demo.mp4","nsfw":false,"nsfwLevel":"None","username":"autor","width":1024,"height":768,"modelVersionIds":[9],"meta":{"prompt":"Paisaje","seed":123}},{"id":72,"url":"https://image.civitai.com/a/original=true/adult.jpeg","nsfwLevel":"Mature"}],"metadata":{"nextCursor":"opaque|123","nextPage":"https://evil.test/api/v1/images"}}"#.utf8)
        let page = try ModelCatalogDecoding.community(data: data, provider: .civitai, kind: .images, currentURL: url, link: nil)
        let video = try #require(page.media.first)
        #expect(video.kind == .video && !video.isAdult)
        #expect(video.author == "autor" && video.versionIDs == ["9"])
        #expect(video.parameters.contains(.init(name: "prompt", value: "Paisaje")))
        #expect(video.sourceURL?.absoluteString == "https://civitai.com/images/71")
        #expect(page.media.last?.isAdult == true)
        #expect(page.nextURL?.host == "civitai.com")
        #expect(URLComponents(url: try #require(page.nextURL), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "modelVersionId" }?.value == "9")
    }

    @Test("Las redirecciones multimedia admiten firmas de almacenamiento oficial sin admitir claves API ni hosts arbitrarios")
    func huggingFaceStorageRedirects() throws {
        let signed = "https://us.aws.cdn.hf.co/xet/opaque-object?Expires=2000000000&Policy=fixture&Signature=fixture&Key-Pair-Id=public-id"
        #expect(ModelCatalogRequest.mediaURL(signed, provider: .huggingFace, kind: .audio) == nil)
        #expect(ModelCatalogRequest.redirectedMediaURL(signed, provider: .huggingFace, kind: .audio)?.host == "us.aws.cdn.hf.co")
        #expect(ModelCatalogRequest.redirectedMediaURL("https://cdn-lfs-eu-1.hf.co/opaque?X-Amz-Signature=fixture&X-Amz-Security-Token=temporary-storage-grant", provider: .huggingFace, kind: .video) != nil)
        #expect(ModelCatalogRequest.redirectedMediaURL("https://huggingface.co/datasets/Narsil/asr_dummy/resolve/main/1.flac", provider: .huggingFace, kind: .audio) != nil)
        for raw in ["https://arbitrary.hf.co/opaque?Signature=fixture", "https://us.aws.cdn.hf.co.evil.test/opaque", "http://us.aws.cdn.hf.co/opaque", "https://user:password@us.aws.cdn.hf.co/opaque", "https://us.aws.cdn.hf.co:8443/opaque", "https://us.aws.cdn.hf.co/../opaque", "https://us.aws.cdn.hf.co/opaque?api_key=private", "https://us.aws.cdn.hf.co/opaque?token=private", "https://us.aws.cdn.hf.co/opaque?access_token=private", "https://huggingface.co/api/models?Signature=fixture"] {
            #expect(ModelCatalogRequest.redirectedMediaURL(raw, provider: .huggingFace, kind: .video) == nil)
        }
        #expect(ModelCatalogRequest.redirectedMediaURL(signed, provider: .civitai, kind: .video) == nil)
    }

    @Test("La autenticación multimedia se limita al recurso original resolve de Hugging Face")
    func authenticatedMediaScope() throws {
        #expect(ModelCatalogRequest.mayAuthenticateMediaURL(try #require(URL(string: "https://huggingface.co/org/model/resolve/commit/image.png"))))
        #expect(ModelCatalogRequest.mayAuthenticateMediaURL(try #require(URL(string: "https://huggingface.co/datasets/org/data/resolve/main/audio.wav"))))
        for raw in ["https://cdn-uploads.huggingface.co/image.png", "https://us.aws.cdn.hf.co/xet/file", "https://huggingface.co/api/resolve-cache/models/org/model/file.png", "https://huggingface.co/org/model/raw/main/image.png", "https://huggingface.co/org/model/resolve/main/image.png?token=secret"] {
            #expect(!ModelCatalogRequest.mayAuthenticateMediaURL(try #require(URL(string: raw))))
        }
        let sha = String(repeating: "a", count: 40)
        let original = try #require(URL(string: "https://huggingface.co/org/model/resolve/\(sha)/images/test.png"))
        let cache = "https://huggingface.co/api/resolve-cache/models/org/model/\(sha)/images/test.png?etag=public"
        #expect(ModelCatalogRequest.mayRetainMediaAuthorization(original: original, redirect: try #require(URL(string: cache))))
        for raw in [cache.replacingOccurrences(of: "/org/model/", with: "/other/model/"), cache.replacingOccurrences(of: "images/test.png", with: "other.png"), cache.replacingOccurrences(of: sha, with: String(repeating: "b", count: 40)), "https://us.aws.cdn.hf.co/xet/file", "https://huggingface.co/api/whoami-v2"] {
            #expect(!ModelCatalogRequest.mayRetainMediaAuthorization(original: original, redirect: try #require(URL(string: raw))))
        }
    }

    @Test("Los comentarios posteriores a eventos de actividad permanecen accesibles con todos sus adjuntos")
    func allDiscussionComments() throws {
        var events: [[String: Any]] = (0..<320).map { ["id": "activity\($0)", "type": "status-change"] }
        for index in 0..<65 {
            let body = (0..<35).map { "![Muestra](https://cdn-uploads.huggingface.co/test/\(index)-\($0).png)" }.joined(separator: " ")
            events.append(["id": "comment\(index)", "type": "comment", "data": ["latest": ["raw": body]]])
        }
        let comments = try ModelCatalogDecoding.discussionComments(data: JSONSerialization.data(withJSONObject: ["events": events]), source: try #require(URL(string: "https://huggingface.co/org/model/discussions/1")))
        #expect(comments.count == 65)
        #expect(comments.last?.id == "comment64")
        #expect(comments.last?.media.count == 35)
    }

    @Test("Los temporales tienen permisos privados, reservas acotadas y purga que respeta archivos ajenos")
    func boundedPrivateTemporaryMedia() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("modelcatalog-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ModelCatalogTemporaryMedia.Store(directory: directory)
        let first = try store.create(extension: "mp4")
        let second = try store.create(extension: "wav")
        #expect(throws: ModelCatalogError.mediaTooLarge) { try store.create(extension: "mp4") }
        #expect((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let foreign = directory.appendingPathComponent("keep.txt")
        try Data("Ajeno".utf8).write(to: foreign)
        store.remove(first)
        let third = try store.create(extension: "flac")
        store.purge()
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(!FileManager.default.fileExists(atPath: third.path))
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    @Test("Todo, excluir y solo NSFW mantienen los bits oficiales sin aceptar contenido bloqueado")
    func adultModesAndRed() throws {
        for mode in ModelCatalogAdultFilter.allCases {
            var filters = ModelCatalogFilters(); filters.adultFilter = mode; filters.civitaiSite = .red
            let url = try ModelCatalogRequest.searchURL(provider: .civitai, filters: filters)
            #expect(url.host == "civitai.red" && ModelCatalogRequest.isAllowedAPIURL(url, provider: .civitai))
            let fields = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            #expect(fields.first { $0.name == "nsfw" }?.value == (mode == .all ? nil : mode == .only ? "true" : "false"))
            let gallery = try ModelCatalogRequest.communityURL(provider: .civitai, modelID: "42", versionID: "9", kind: .images, filters: .init(), includeAdult: mode != .exclude, adultFilter: mode, site: .red)
            #expect(gallery.host == "civitai.red")
            #expect(URLComponents(url: gallery, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "browsingLevel" }?.value == mode.browsingLevel)
            #expect(!mode.allows(.blocked, provider: .civitai))
        }
        #expect(ModelCatalogAdultFilter.exclude.allows(.pg, provider: .civitai))
        #expect(ModelCatalogAdultFilter.exclude.allows(.pg13, provider: .civitai))
        #expect(!ModelCatalogAdultFilter.only.allows(.unknown, provider: .civitai))
        #expect(ModelCatalogAdultFilter.only.allows(.xxx, provider: .civitai))
        #expect(ModelCatalogContentRating.decode(level: 31) == .xxx)
        #expect(ModelCatalogContentRating.decode(level: 63) == .blocked)
        #expect(!ModelCatalogRequest.isAllowedAPIURL(try #require(URL(string: "https://civitai.red.evil.test/api/v1/models")), provider: .civitai))
    }

    @Test("La ficha y el inspector conservan versiones, archivos y parámetros completos sin recortes silenciosos")
    func completeMetadata() throws {
        let versions: [[String: Any]] = (1...305).map { index in ["id": index, "name": "Versión \(index)", "files": index == 305 ? (1...1005).map { ["name": "file\($0)", "unknownField": "Conservado"] } : []] }
        let object: [String: Any] = ["id": 42, "name": "Modelo", "modelVersions": versions, "extraProviderField": ["unknown": "Dato completo"]]
        let data = try JSONSerialization.data(withJSONObject: object)
        let model = try ModelCatalogDecoding.detail(data: data, provider: .civitai, site: .red)
        #expect(model.versions.count == 305)
        #expect(model.versions.last?.files.count == 1005)
        #expect(model.bookmarkURL()?.host == "civitai.red")
        let document = try ModelCatalogMetadataDocument(data: #require(model.rawMetadata))
        #expect(document.text.contains("extraProviderField") && document.matching("Dato completo").count == 1)
        let decoded = try JSONSerialization.jsonObject(with: Data(document.text.utf8)) as? [String: Any]
        #expect((decoded?["modelVersions"] as? [Any])?.count == 305)
    }

    @Test("Los favoritos locales se respaldan de forma aditiva y deduplican COM/RED sin aceptar IDs ajenos")
    func catalogFavoriteBackup() throws {
        let standard = ModelCatalogFavorite(provider: .civitai, modelID: "42", title: "Modelo", author: "Ana", site: .standard, createdAt: .distantPast)
        let red = ModelCatalogFavorite(provider: .civitai, modelID: "42", title: "RED", author: nil, site: .red, createdAt: .now)
        let hf = ModelCatalogFavorite(provider: .huggingFace, modelID: "org/model", title: "HF", author: "org", site: .standard, createdAt: .now)
        #expect(ModelCatalogFavorites.merge([standard], [red, hf]).count == 2)
        let invalid = ModelCatalogFavorite(provider: .civitai, modelID: "../bad", title: "Ajeno", author: nil, site: .red, createdAt: .now)
        #expect(throws: ModelCatalogError.invalidResponse) { try ModelCatalogFavorites.decode(JSONEncoder().encode([invalid])) }
        let name = "modelCatalogFavoritesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        try ModelCatalogFavorites.set([standard], defaults: defaults)
        try ModelCatalogFavorites.mergeJSON(ModelCatalogFavorites.encode([red, hf]), defaults: defaults)
        let exported = try #require(ModelCatalogFavorites.exportJSON(defaults: defaults))
        #expect(try ModelCatalogFavorites.decode(exported).count == 2)
        #expect(try ModelCatalogFavorites.load(defaults: defaults).first { $0.id == standard.id }?.title == "Modelo")
    }

    @Test("Las conversaciones conservan el contenido publicado y solo muestran adjuntos permitidos")
    func huggingFaceCommunityComments() throws {
        let source = try #require(URL(string: "https://huggingface.co/org/model/discussions/7"))
        let data = Data(#"{"events":[{"id":"comment1","type":"comment","author":{"name":"Ana"},"data":{"latest":{"raw":"Ejemplo real ![Resultado](https://cdn-uploads.huggingface.co/test/demo.png) ![Externo](https://evil.test/demo.png)"}}},{"id":"hidden","type":"comment","data":{"hidden":true,"latest":{"raw":"Oculto"}}}]}"#.utf8)
        let posts = try ModelCatalogDecoding.discussionComments(data: data, source: source)
        #expect(posts.count == 1 && posts[0].author == "Ana")
        #expect(posts[0].body.hasPrefix("Ejemplo real"))
        #expect(posts[0].media.count == 1 && posts[0].media[0].sourceURL == source)
        let url = try ModelCatalogRequest.communityURL(provider: .huggingFace, modelID: "org/model", versionID: nil, kind: .discussions, filters: .init(), includeAdult: false)
        let page = try ModelCatalogDecoding.community(data: Data(#"{"count":21,"start":0,"discussions":[{"num":7,"title":"Ejemplos","author":{"name":"Ana"},"numComments":3}]}"#.utf8), provider: .huggingFace, kind: .discussions, currentURL: url, link: nil)
        #expect(page.posts[0].url == source && page.posts[0].comments == 3)
        #expect(URLComponents(url: try #require(page.nextURL), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "p" }?.value == "1")
    }

    @Test("Los widgets mantienen varias salidas y resuelven archivos relativos contra su revisión")
    func widgetOutputs() throws {
        let data = Data(#"{"id":"org/model","sha":"commit123","widgetData":[{"example_title":"Paisaje","text":"Un bosque","output":[{"url":"images/demo.png"},{"url":"https://cdn-media.huggingface.co/demo.mp4"},{"url":"https://evil.test/demo.png"}]}]}"#.utf8)
        let item = try ModelCatalogDecoding.detail(data: data, provider: .huggingFace)
        let example = try #require(item.examples.first)
        #expect(example.title == "Paisaje" && example.body.contains("Un bosque"))
        #expect(example.media.count == 2 && example.unavailableMediaCount == 1)
        #expect(example.media.first?.url.absoluteString == "https://huggingface.co/org/model/resolve/commit123/images/demo.png")
        #expect(example.media.last?.kind == .video)
    }
    @Test("La adquisición usa archivos reales, respeta RED y nunca acepta claves en URLs")
    func fileAcquisitionPolicy() throws {
        let data = Data(#"{"id":42,"name":"Modelo","modelVersions":[{"id":9,"name":"v1","files":[{"name":"model.safetensors","sizeKB":1,"downloadUrl":"https://civitai.com/api/download/models/9?fileId=77","hashes":{"SHA256":"abcd"}}]}]}"#.utf8)
        let model = try ModelCatalogDecoding.detail(data: data, provider: .civitai, site: .red)
        let version = try #require(model.versions.first); let file = try #require(version.files.first)
        #expect(ModelCatalogRequest.fileDownloadURL(model: model, version: version, file: file)?.host == "civitai.red")
        #expect(file.downloadURL?.path == "/api/download/models/9" && file.sizeBytes == 1024 && file.sizeIsApproximate && file.sha256 == "abcd")
        #expect(ModelCatalogRequest.matchesDownloadSize(received: 1020, expected: 1024, approximate: true))
        #expect(!ModelCatalogRequest.matchesDownloadSize(received: 1020, expected: 1024, approximate: false))
        #expect(!ModelCatalogRequest.matchesDownloadSize(received: 4096, expected: 1024, approximate: true))
        #expect(ModelCatalogRequest.downloadInitialURL("https://huggingface.co/org/model/resolve/commit/model.safetensors", provider: .huggingFace) != nil)
        let signed = "https://civitai-delivery-worker-prod.5ac0637cfd0766c97916cefa3764fbdf.r2.cloudflarestorage.com/model/object?X-Amz-Signature=fixture"
        #expect(ModelCatalogRequest.downloadInitialURL(signed, provider: .civitai) == nil)
        #expect(ModelCatalogRequest.downloadRedirectURL(signed, provider: .civitai) != nil)
        for raw in ["https://civitai.com/api/download/models/9?token=secret", "https://civitai.red/api/download/models/9?api_key=secret", "https://civitai.red/login", "https://civitai.red/api/download/models/abc", "https://huggingface.co/org/model/resolve/main/model.bin?hf_token=secret"] {
            #expect(ModelCatalogRequest.downloadInitialURL(raw, provider: raw.contains("huggingface") ? .huggingFace : .civitai) == nil)
        }
        #expect(ModelCatalogRequest.downloadRedirectURL("https://evil.test/file?X-Amz-Signature=fixture", provider: .civitai) == nil)
        let root = try ModelCatalogRequest.communityURL(provider: .civitai, modelID: "42", versionID: nil, kind: .images, filters: .init(sort: "Most Comments"), includeAdult: false)
        #expect(URLComponents(url: root, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "sort" }?.value == "Newest")
        let versionURL = try ModelCatalogRequest.communityURL(provider: .civitai, modelID: "42", versionID: "9", kind: .images, filters: .init(sort: "Most Collected"), includeAdult: false)
        #expect(URLComponents(url: versionURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "sort" }?.value == "Most Collected")
    }

    @Test("Los contenedores de parámetros Civitai exigen la muestra y conservan el JSON publicado")
    func civitaiPublishedParameterContainers() throws {
        let data = Data(#"{"items":[{"id":71,"url":"https://image.civitai.com/a/original=true/one.jpeg","nsfwLevel":1,"meta":{"id":71,"meta":null}},{"id":72,"url":"https://image.civitai.com/a/original=true/two.jpeg","nsfwLevel":1,"meta":{"id":72,"meta":{"prompt":"Paisaje","seed":123}}},{"id":73,"url":"https://image.civitai.com/a/original=true/three.jpeg","nsfwLevel":1,"meta":{"id":999,"meta":{"prompt":"De otra muestra"}}},{"id":74,"url":"https://image.civitai.com/a/original=true/four.jpeg","nsfwLevel":1,"meta":{"prompt":"Plano","seed":456}},{"id":75,"url":"https://image.civitai.com/a/original=true/five.jpeg","nsfwLevel":1,"meta":{"id":75,"meta":{}}}]}"#.utf8)
        let request = try ModelCatalogRequest.communityURL(provider: .civitai, modelID: "80324", versionID: nil, kind: .images, filters: .init(requiringMetadata: true), includeAdult: false)
        let page = try ModelCatalogDecoding.community(data: data, provider: .civitai, kind: .images, currentURL: request, link: nil)
        #expect(page.media.count == 5)
        #expect(page.media[0].parameters.isEmpty && page.media[2].parameters.isEmpty && page.media[4].parameters.isEmpty)
        #expect(page.media[1].parameters.contains(.init(name: "prompt", value: "Paisaje")))
        #expect(page.media[1].parameters.contains(.init(name: "seed", value: "123")))
        #expect(page.media[3].parameters.contains(.init(name: "prompt", value: "Plano")))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let original = try #require(object["items"] as? [[String: Any]])
        for (index, media) in page.media.enumerated() {
            let rawMetadata = try #require(media.rawMetadata)
            let metadata = try #require(JSONSerialization.jsonObject(with: rawMetadata) as? [String: Any])
            #expect(NSDictionary(dictionary: metadata).isEqual(to: original[index]))
        }
    }

    @Test("Los widgets sin multimedia conservan tablas, contexto, frases y puntuaciones")
    func nativeTextWidgets() throws {
        let data = Data(#"{"id":"org/model","sha":"abc","tags":["not-for-all-audiences"],"widgetData":[{"example_title":"Clasificación","text":"Una frase","output":[{"label":"positive","score":0.99},{"label":"negative","score":0.01}]},{"context":"Contexto completo","inputs":["Frase uno","Frase dos"],"table":{"columns":["A","B"],"rows":[[1,2],[3,4]]},"output":{"answer":"Respuesta","coordinates":[1,2]}}]}"#.utf8)
        let model = try ModelCatalogDecoding.detail(data: data, provider: .huggingFace)
        #expect(model.examples.count == 2 && model.examples.allSatisfy { $0.media.isEmpty })
        #expect(model.examples[0].body.contains("positive") && model.examples[0].body.contains("0.99"))
        #expect(model.examples[1].body.contains("Contexto completo") && model.examples[1].body.contains("Frase dos") && model.examples[1].body.contains("columns") && model.examples[1].body.contains("Respuesta"))
        let metadata = try ModelCatalogMetadataDocument(data: try #require(model.examples[1].rawMetadata))
        #expect(metadata.text.contains("coordinates") && metadata.text.contains("rows"))
        #expect(model.contentRating == .r)
    }

    @Test("La respuesta dedicada de versión conserva todos los datos y exige el modelo esperado")
    func completeVersionLookup() throws {
        let data = Data(#"{"id":9,"modelId":42,"name":"v1","description":"Ficha de versión","usageControl":"Download","trainingDetails":{"steps":1200},"paidAccess":{"download":false},"files":[{"name":"model.bin","downloadUrl":"https://civitai.red/api/download/models/9"}]}"#.utf8)
        let version = try ModelCatalogDecoding.civitaiVersion(data: data, modelID: "42", versionID: "9", site: .red)
        #expect(version.description == "Ficha de versión" && version.files.first?.downloadURL?.host == "civitai.red")
        let metadata = try ModelCatalogMetadataDocument(data: try #require(version.rawMetadata))
        #expect(metadata.text.contains("trainingDetails") && metadata.text.contains("usageControl") && metadata.text.contains("paidAccess"))
        #expect(throws: ModelCatalogError.self) { try ModelCatalogDecoding.civitaiVersion(data: data, modelID: "43", versionID: "9", site: .red) }
    }

    @Test("El staging de adquisición limpia solo temporales propios y conserva el destino existente")
    func downloadStagingLifecycle() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("catalog-download-test-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("existing.bin"); let original = Data("Conservar".utf8); try original.write(to: destination)
        let store = ModelCatalogDownloads.StagingStore(directory: folder.appendingPathComponent("registry", isDirectory: true))
        let first = try store.reserve(beside: destination); let second = try store.reserve(beside: destination)
        #expect((try manager.attributesOfItem(atPath: first.directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((try manager.attributesOfItem(atPath: first.file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(throws: ModelCatalogDownloadError.self) { try store.reserve(beside: destination) }
        let foreign = second.directory.appendingPathComponent("foreign.txt"); try Data("Ajeno".utf8).write(to: foreign)
        store.purge()
        #expect(!manager.fileExists(atPath: first.directory.path) && !manager.fileExists(atPath: second.file.path))
        let retained = try Data(contentsOf: destination)
        #expect(manager.fileExists(atPath: foreign.path) && retained == original)
        let registry = try Data(contentsOf: folder.appendingPathComponent("registry/pending.json"))
        #expect(try JSONDecoder().decode([ModelCatalogDownloads.Stage].self, from: registry).isEmpty)
    }

    @Test("Los favoritos de modelos anteriores siguen válidos y las muestras conservan metadata y visor sin duplicar COM/RED")
    func artifactFavoritesCompatibility() throws {
        let legacy = Data(#"[{"provider":"huggingFace","modelID":"org/model","title":"Modelo","site":"standard","createdAt":0,"contentRating":"unknown"}]"#.utf8)
        let old = try ModelCatalogFavorites.decode(legacy)
        #expect(old.count == 1 && old[0].isModel && old[0].id == "huggingFace:org/model")
        let model = ModelCatalogItem.snapshot(provider: .civitai, id: "42", title: "Modelo", author: "Creador", site: .red, rating: .pg)
        let sample = ModelCatalogPreview(url: try #require(URL(string: "https://image.civitai.com/a/original=true/image.jpeg")), isAdult: false, identifier: "71", sourceURL: try #require(URL(string: "https://civitai.red/images/71")), title: "Ejemplo", parameters: [.init(name: "prompt", value: "Paisaje")], contentRating: .pg13, rawMetadata: Data(#"{"meta":{"prompt":"Paisaje"},"extra":"Conservado"}"#.utf8))
        let favorite = ModelCatalogFavorite.sample(sample, model: model)
        var alias = favorite; alias.sourceURL = URL(string: "https://civitai.com/images/71")
        let restored = try ModelCatalogFavorites.decode(ModelCatalogFavorites.encode(old + [favorite, alias]))
        #expect(restored.count == 2 && favorite.id == alias.id && !favorite.isModel)
        let saved = try #require(restored.first { !$0.isModel })
        #expect(saved.media?.parameters.first?.value == "Paisaje" && saved.media?.rawMetadata == sample.rawMetadata)
        #expect(saved.url?.host == "civitai.red" && saved.media?.url == sample.url && saved.modelSnapshot.id == "42")
        #expect(ModelCatalogAdultFilter.exclude.allows(saved.contentRating, provider: .civitai))
        #expect(!ModelCatalogAdultFilter.only.allows(saved.contentRating, provider: .civitai))
        var malicious = favorite; malicious.sourceURL = URL(string: "https://evil.test/images/71")
        #expect(throws: ModelCatalogError.self) { try ModelCatalogFavorites.decode(ModelCatalogFavorites.encode([malicious])) }
    }

    @Test("Los widgets comparten la ficha real del modelo y los comentarios mantienen identidad local propia")
    func widgetAndCommentFavorites() throws {
        let model = ModelCatalogItem.snapshot(provider: .huggingFace, id: "org/model", title: "Modelo", author: "Org", site: .standard, rating: .unknown)
        let source = try #require(model.bookmarkURL())
        let widget = ModelCatalogPost(id: "widget:0", title: "Ejemplo textual", url: source, body: "Salida completa", rawMetadata: Data(#"{"output":{"label":"positive","score":0.99}}"#.utf8))
        let favorite = ModelCatalogFavorite.publication(widget, model: model)
        #expect(favorite.kind == .widget && favorite.url == source && favorite.id != "huggingFace:org/model")
        let discussion = try #require(URL(string: "https://huggingface.co/org/model/discussions/9"))
        let first = ModelCatalogFavorite.publication(.init(id: "comment-1", title: "Comentario", url: discussion, body: "Uno"), model: model)
        let second = ModelCatalogFavorite.publication(.init(id: "comment-2", title: "Comentario", url: discussion, body: "Dos"), model: model)
        #expect(first.kind == .comment && first.url == discussion && first.id != second.id)
        #expect(try ModelCatalogFavorites.decode(ModelCatalogFavorites.encode([favorite, first, second])).count == 3)
    }

    @Test("Las muestras de Spaces conservan la procedencia real y el filtro puede ocultar y recuperar la misma selección")
    func spaceSamplesAndLiveClassification() throws {
        let model = ModelCatalogItem.snapshot(provider: .huggingFace, id: "org/model", title: "Modelo", author: "Org", site: .standard, rating: .unknown)
        let sample = ModelCatalogPreview(url: try #require(URL(string: "https://huggingface.co/spaces/org/app/resolve/main/example.png")), isAdult: false, identifier: "space-sample", sourceURL: try #require(URL(string: "https://huggingface.co/spaces/org/app")), title: "Muestra del Space", contentRating: .unknown)
        let favorite = ModelCatalogFavorite.sample(sample, model: model)
        let restored = try ModelCatalogFavorites.decode(ModelCatalogFavorites.encode([favorite]))
        #expect(restored.first?.url == sample.sourceURL && restored.first?.media?.url == sample.url)
        let adult = ModelCatalogPreview(url: try #require(URL(string: "https://image.civitai.com/a/example.jpeg")), isAdult: true, identifier: "adult-sample", contentRating: .r)
        let received = [adult]
        let selectedID = adult.id
        #expect(received.filter { ModelCatalogAdultFilter.exclude.allows($0.contentRating, provider: .civitai) }.first { $0.id == selectedID } == nil)
        #expect(received.filter { ModelCatalogAdultFilter.only.allows($0.contentRating, provider: .civitai) }.first { $0.id == selectedID }?.id == selectedID)
        #expect(received.count == 1)
    }

    @Test("La portada de publicaciones respeta la clasificación declarada del widget y selecciona otra muestra permitida")
    func representativePostPreviewPolicy() throws {
        let data = Data(#"{"id":"org/model","tags":["not-for-all-audiences"],"widgetData":[{"text":"Ejemplo","output":{"url":"https://cdn-uploads.huggingface.co/example.png"}}]}"#.utf8)
        let model = try ModelCatalogDecoding.detail(data: data, provider: .huggingFace)
        let widget = try #require(model.examples.first)
        #expect(widget.representativePreview(provider: .huggingFace, adultFilter: .exclude) == nil)
        let declaredAdult = try #require(widget.representativePreview(provider: .huggingFace, adultFilter: .only))
        #expect(declaredAdult.contentRating == .r)
        var mixed = widget
        var blocked = declaredAdult; blocked.contentRating = .blocked
        var pg13 = declaredAdult; pg13.contentRating = .pg13; pg13.identifier = "safe-alternative"
        mixed.media = [blocked, declaredAdult, pg13]
        #expect(mixed.representativePreview(provider: .civitai, adultFilter: .exclude)?.id == pg13.id)
        #expect(mixed.representativePreview(provider: .civitai, adultFilter: .all)?.contentRating == .r)
        #expect(mixed.representativePreview(provider: .civitai, adultFilter: .only)?.contentRating == .r)
        #expect(mixed.media.count == 3)
    }

    @Test("Adquirir archivos HF permite cualquier extensión sin ampliar los formatos ejecutables del visor")
    func repositoryFilesAreSeparateFromPlayback() throws {
        let sha = String(repeating: "a", count: 40)
        let model = ModelCatalogItem.snapshot(provider: .huggingFace, id: "org/model", title: "Modelo", author: "Org", site: .standard, rating: .unknown)
        let version = ModelCatalogVersion(id: "release", name: "release", revision: sha, baseModel: nil, createdAt: nil, description: "", trainedWords: [], files: [], previews: [])
        for filename in ["config.json", "weights.safetensors", "index.html", "document.htm", "page.xhtml", "demo.js", "illustration.svg", "playlist.m3u8"] {
            let file = ModelCatalogFile(name: filename)
            let selection = try #require(ModelCatalogDownloadSelection.file(file, model: model, version: version))
            #expect(selection.filename == filename && ModelCatalogRequest.mayAuthenticateFileURL(selection.url))
            let cache = try #require(URL(string: "https://huggingface.co/api/resolve-cache/models/org/model/\(sha)/\(filename)?etag=public"))
            #expect(ModelCatalogRequest.downloadRedirectURL(cache.absoluteString, provider: .huggingFace) != nil)
            #expect(ModelCatalogRequest.mayRetainDownloadAuthorization(original: selection.url, redirect: cache))
            let cdn = try #require(URL(string: "https://us.aws.cdn.hf.co/xet/storage?X-Amz-Signature=storage"))
            #expect(!ModelCatalogRequest.mayRetainDownloadAuthorization(original: selection.url, redirect: cdn))
            let wrongRepo = try #require(URL(string: cache.absoluteString.replacingOccurrences(of: "/org/model/", with: "/other/model/")))
            #expect(!ModelCatalogRequest.mayRetainDownloadAuthorization(original: selection.url, redirect: wrongRepo))
        }
        for filename in ["index.html", "demo.js", "illustration.svg", "playlist.m3u8"] {
            #expect(ModelCatalogRequest.mediaURL("https://huggingface.co/org/model/resolve/\(sha)/\(filename)", provider: .huggingFace, kind: .image) == nil)
        }
        #expect(ModelCatalogRequest.acceptsDownloadMIME("text/html", filename: "index.html"))
        #expect(ModelCatalogRequest.acceptsDownloadMIME("application/xhtml+xml", filename: "page.xhtml"))
        #expect(!ModelCatalogRequest.acceptsDownloadMIME("text/html", filename: "config.json"))
        #expect(ModelCatalogRequest.downloadInitialURL("https://huggingface.co/org/model/resolve/\(sha)/demo.js?token=secret", provider: .huggingFace) == nil)
    }

    @Test("Favoritar una muestra HF conserva el widget original completo, su autor y campos desconocidos de la salida")
    func widgetSampleMetadataRoundTrip() throws {
        let data = Data(#"{"id":"org/model","sha":"commit123","author":"Org","cardData":{"thumbnail":"https://cdn-uploads.huggingface.co/thumbnail.png"},"widgetData":[{"example_title":"Ejemplo","author":"Autor Ω","text":"Prompt íntegro","resources":[{"model":"Base","weight":0.6}],"src":"audio/input.wav","output":{"url":"images/output.png","unknown":{"detail":"Dato preservado"},"score":0.99}}]}"#.utf8)
        let model = try ModelCatalogDecoding.detail(data: data, provider: .huggingFace)
        let post = try #require(model.examples.first)
        #expect(post.media.count == 2)
        for sample in post.media {
            let favorite = ModelCatalogFavorite.sample(sample, model: model)
            let restored = try #require(ModelCatalogFavorites.decode(ModelCatalogFavorites.encode([favorite])).first?.media)
            let original = try #require(restored.rawMetadata)
            let fields = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
            #expect(fields["text"] as? String == "Prompt íntegro")
            #expect(fields["author"] as? String == "Autor Ω" && restored.author == "Autor Ω")
            #expect((fields["resources"] as? [[String: Any]])?.first?["model"] as? String == "Base")
            #expect(((fields["output"] as? [String: Any])?["unknown"] as? [String: Any])?["detail"] as? String == "Dato preservado")
            #expect(restored.url == sample.url && restored.parameters.contains { $0.value == "Prompt íntegro" })
        }
        #expect(model.versions.first?.previews.allSatisfy { $0.rawMetadata != nil } == true)
    }

    @Test("El README resuelve imágenes, vídeo y audio relativos contra el repositorio y la revisión exacta")
    func relativeReadmeMediaIsBoundToSource() throws {
        let sha = String(repeating: "a", count: 40)
        let modelSource = try #require(URL(string: "https://huggingface.co/org/model/tree/\(sha)"))
        let text = "![Demo](assets/demo.png) <video src=\"videos/demo.mp4\"></video> <audio src='audio/demo.wav'></audio> ![Externa](https://evil.test/demo.png) ![Traversal](../demo.png)"
        let parsed = ModelCatalogDecoding.markdownMediaResult(text, source: modelSource)
        #expect(parsed.media.count == 3 && parsed.unavailableCount == 2)
        #expect(parsed.media.map(\.kind) == [.image, .video, .audio])
        #expect(parsed.media.allSatisfy { $0.url.path.hasPrefix("/org/model/resolve/\(sha)/") && $0.sourceURL == modelSource && $0.rawMetadata != nil })
        let spaceSource = try #require(URL(string: "https://huggingface.co/spaces/org/app"))
        let space = ModelCatalogDecoding.markdownMediaResult("![Demo](./assets/demo.png)", source: spaceSource, revision: sha)
        #expect(space.media.first?.url.path == "/spaces/org/app/resolve/\(sha)/assets/demo.png")
        #expect(space.media.first?.sourceURL == spaceSource)
        let discussion = try #require(URL(string: "https://huggingface.co/org/model/discussions/7"))
        #expect(ModelCatalogDecoding.markdownMediaResult("![Demo](assets/demo.png)", source: discussion).unavailableCount == 1)
        for raw in ["../demo.png", "assets/%2e%2e/demo.png", "%252e%252e/demo.png", "//evil.test/demo.png", "https://evil.test/demo.png", "https://huggingface.co/org/model/resolve/main/demo.png?token=secret"] {
            #expect(ModelCatalogRequest.readmeAssetURL(raw, source: modelSource, kind: .image) == nil)
        }
    }

    @Test("Un Space NSFW conserva su clasificación en miniaturas, README y favoritos aunque el modelo vinculado no esté clasificado")
    func declaredSpaceClassificationReachesArtifacts() throws {
        let current = try ModelCatalogRequest.communityURL(provider: .huggingFace, modelID: "org/model", versionID: nil, kind: .spaces, filters: .init(), includeAdult: false)
        let query = try #require(URLComponents(url: current, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains { $0.name == "expand" && $0.value == "tags" })
        let model = ModelCatalogItem.snapshot(provider: .huggingFace, id: "org/model", title: "Modelo", author: "Org", site: .standard, rating: .unknown)
        for fields in [#""tags":["nsfw"],"cardData":{"thumbnail":"https://cdn-uploads.huggingface.co/demo.png"}"#,
                       #""tags":["demo"],"cardData":{"tags":["not-for-all-audiences"],"thumbnail":"https://cdn-uploads.huggingface.co/demo.png"}"#] {
            let data = Data(("[{\"id\":\"demo/adult-space\"," + fields + "}]").utf8)
            let page = try ModelCatalogDecoding.community(data: data, provider: .huggingFace, kind: .spaces, currentURL: current, link: nil)
            let post = try #require(page.posts.first)
            let thumbnail = try #require(post.media.first)
            #expect(thumbnail.contentRating == .r && thumbnail.isAdult)
            #expect(post.representativePreview(provider: .huggingFace, adultFilter: .exclude) == nil)
            #expect(post.representativePreview(provider: .huggingFace, adultFilter: .only)?.url == thumbnail.url)
            let examples = ModelCatalogDecoding.markdownMediaResult("![Demo](assets/demo.png)", source: post.url, revision: "commit123", rating: thumbnail.contentRating, rawMetadata: post.rawMetadata)
            let sample = try #require(examples.media.first)
            #expect(!ModelCatalogAdultFilter.exclude.allows(sample.contentRating, provider: .huggingFace))
            let implicitRating = ModelCatalogDecoding.markdownMediaResult("![Demo](assets/demo.png)", source: post.url, revision: "commit123", rawMetadata: post.rawMetadata)
            #expect(implicitRating.media.first?.contentRating == .r)
            let restored = try ModelCatalogFavorites.decode(ModelCatalogFavorites.encode([.publication(post, model: model), .sample(sample, model: model)]))
            #expect(restored.count == 2 && restored.allSatisfy { $0.contentRating == .r })
            #expect(restored.first { $0.post != nil }?.post?.representativePreview(provider: .huggingFace, adultFilter: .exclude) == nil)
        }
    }

    @Test("La ficha completa reclasifica un Space y el backup antiguo preserva esa declaración sin inferir que los demás son aptos")
    func spaceClassificationSurvivesRefreshAndLegacyFavorites() throws {
        let source = try #require(URL(string: "https://huggingface.co/spaces/demo/adult-space"))
        let image = try #require(URL(string: "https://cdn-uploads.huggingface.co/demo.png"))
        let metadata = Data(#"{"id":"demo/adult-space","sha":"commit456","cardData":{"tags":["nsfw"],"thumbnail":"https://cdn-uploads.huggingface.co/demo.png"}}"#.utf8)
        let full = try ModelCatalogDecoding.huggingFaceRepositoryMetadata(data: metadata)
        #expect(full.revision == "commit456" && full.contentRating == .r)
        var original = ModelCatalogPost(id: "space:demo/adult-space", title: "Space", url: source, media: [.init(url: image, isAdult: false, sourceURL: source)])
        original.rawMetadata = metadata
        let enriched = original.applyingContentRating(full.contentRating)
        #expect(enriched.representativePreview(provider: .huggingFace, adultFilter: .exclude) == nil)
        #expect(enriched.applyingContentRating(.unknown).contentRating == .r)
        let model = ModelCatalogItem.snapshot(provider: .huggingFace, id: "org/model", title: "Modelo", author: "Org", site: .standard, rating: .unknown)
        let sample = try #require(ModelCatalogDecoding.markdownMediaResult("![Demo](assets/demo.png)", source: source, revision: full.revision, rawMetadata: metadata).media.first)
        let favorites = [ModelCatalogFavorite.publication(enriched, model: model), .sample(sample, model: model)]
        var legacy = try #require(JSONSerialization.jsonObject(with: ModelCatalogFavorites.encode(favorites)) as? [[String: Any]])
        for index in legacy.indices {
            legacy[index]["contentRating"] = "unknown"
            if var post = legacy[index]["post"] as? [String: Any] {
                post["contentRating"] = nil
                if var media = post["media"] as? [[String: Any]] { for index in media.indices { media[index]["contentRating"] = "unknown"; media[index]["isAdult"] = false }; post["media"] = media }
                legacy[index]["post"] = post
            }
            if var media = legacy[index]["media"] as? [String: Any] { media["contentRating"] = "unknown"; media["isAdult"] = false; legacy[index]["media"] = media }
        }
        let restored = try ModelCatalogFavorites.decode(JSONSerialization.data(withJSONObject: legacy))
        #expect(restored.count == 2 && restored.allSatisfy { $0.contentRating == .r })
        #expect(restored.first { $0.post != nil }?.post?.representativePreview(provider: .huggingFace, adultFilter: .exclude) == nil)
        #expect(restored.first { $0.media != nil }?.media?.contentRating == .r)
        let unknown = try ModelCatalogDecoding.huggingFaceRepositoryMetadata(data: Data(#"{"id":"demo/unknown-space","tags":["demo"],"cardData":{"tags":["image"]}}"#.utf8))
        #expect(unknown.contentRating == .unknown)
        #expect(ModelCatalogAdultFilter.exclude.allows(unknown.contentRating, provider: .huggingFace))
        #expect(!ModelCatalogAdultFilter.only.allows(unknown.contentRating, provider: .huggingFace))
        let taggedModel = try ModelCatalogDecoding.detail(data: Data(#"{"id":"org/model","cardData":{"tags":["nsfw"]},"widgetData":[{"output":{"url":"https://cdn-uploads.huggingface.co/demo.png"}}]}"#.utf8), provider: .huggingFace)
        #expect(taggedModel.contentRating == .r && taggedModel.examples.first?.representativePreview(provider: .huggingFace, adultFilter: .exclude) == nil)
    }

    @Test("Un Llavero que exige permiso o deniega el acceso mantiene el catálogo público sin clave ni filtros de cuenta")
    func noninteractiveKeychainKeepsPublicAccess() throws {
        for status: Int32 in [-25308, -25293, -128, -25291] {
            var access = ModelCatalogCredentialAccess(reader: { _, interactive in
                interactive ? .keychain(status: 0, data: Data("synthetic-token".utf8)) : .keychain(status: status, data: Data("synthetic-token".utf8))
            })
            #expect(access.background(.huggingFace).status == .checking && access.background(.huggingFace).token == nil)
            let pending = access.beginProbe(.huggingFace)
            let ticket = try #require(pending)
            let completed = access.completeProbe(.huggingFace, ticket: ticket, result: access.reader(.huggingFace, false))
            #expect(completed)
            let reply = access.background(.huggingFace)
            #expect(reply.token == nil && !reply.status.canUseAccount)
            #expect(reply.status == (status == -25291 ? .unavailable : .authorizationRequired))
            #expect(access.status(.huggingFace) == reply.status)
            var request = URLRequest(url: try ModelCatalogRequest.searchURL(provider: .huggingFace, filters: .init()))
            if let token = reply.token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(reply.status.message.contains("público"))
        }
        #expect(ModelCatalogCredentialRead.keychain(status: -25300, data: nil).status == .absent)
        #expect(ModelCatalogCredentialRead.keychain(status: 0, data: nil).status == .unavailable)
        #expect(ModelCatalogCredentialRead.keychain(status: 0, data: Data()).status == .unavailable)
    }

    @Test("Una autorización explícita conserva acceso en memoria solo para su proveedor y desconectar lo invalida")
    func authorizedCredentialIsProviderScoped() throws {
        var access = ModelCatalogCredentialAccess(reader: { _, _ in .keychain(status: -25308, data: nil) })
        let pending = access.beginProbe(.huggingFace)
        let ticket = try #require(pending)
        let completed = access.completeProbe(.huggingFace, ticket: ticket, result: access.reader(.huggingFace, false))
        #expect(completed)
        #expect(access.background(.huggingFace).status == .authorizationRequired)
        try access.authorized(.huggingFace, token: "synthetic-token")
        #expect(access.background(.huggingFace).status.canUseAccount)
        #expect(access.background(.huggingFace).token == "synthetic-token")
        #expect(access.background(.civitai).status == .checking && access.background(.civitai).token == nil)
        access.forget(.huggingFace)
        #expect(access.background(.huggingFace).status == .absent && access.background(.huggingFace).token == nil)
        #expect(throws: ModelCatalogError.invalidToken) { try access.authorized(.civitai, token: "") }
        #expect(!access.background(.civitai).status.canUseAccount)
    }

    @Test("Una autorización cancelada o ausente corrige el estado pendiente sin invalidar una cuenta ya validada")
    func foregroundFailurePreservesValidatedAccess() throws {
        var access = ModelCatalogCredentialAccess(reader: { _, _ in .keychain(status: -25300, data: nil) })
        let pending = access.beginProbe(.huggingFace)
        let ticket = try #require(pending)
        access.authorizationFailed(.huggingFace, status: .absent)
        let late = access.completeProbe(.huggingFace, ticket: ticket, result: .keychain(status: 0, data: Data("old-synthetic-token".utf8)))
        #expect(!late && access.background(.huggingFace).status == .absent && access.background(.huggingFace).token == nil)
        try access.authorized(.huggingFace, token: "validated-synthetic-token")
        access.authorizationFailed(.huggingFace, status: .authorizationRequired)
        #expect(access.background(.huggingFace).status == .available && access.background(.huggingFace).token == "validated-synthetic-token")
        access.authorizationFailed(.civitai, status: .accountUnavailable)
        #expect(!access.background(.civitai).status.canUseAccount && access.background(.civitai).token == nil)
    }

    @Test("Una conexión nueva fallida termina la consulta pendiente sin afirmar que exista una clave, y conserva el token de una cuenta validada")
    func failedConnectionKeepsHonestPublicStatus() throws {
        var access = ModelCatalogCredentialAccess(reader: { _, _ in .keychain(status: -25308, data: nil) })
        let pending = access.beginProbe(.huggingFace)
        let ticket = try #require(pending)
        access.invalidateProbe(.huggingFace)
        access.authorizationFailed(.huggingFace, status: .accessUnverified)
        let value = access.background(.huggingFace)
        #expect(value.status != .checking && !value.status.canUseAccount && !value.status.hasSavedCredential && value.token == nil)
        let late = access.completeProbe(.huggingFace, ticket: ticket, result: .keychain(status: 0, data: Data("late-synthetic-token".utf8)))
        #expect(!late && access.background(.huggingFace).status == .accessUnverified)
        try access.authorized(.huggingFace, token: "prior-validated-synthetic-token")
        access.authorizationFailed(.huggingFace, status: .accessUnverified)
        #expect(access.background(.huggingFace).status == .available && access.background(.huggingFace).token == "prior-validated-synthetic-token")
        #expect(access.background(.civitai).token == nil)
    }

    @Test("Invalidar una operación impide que un trabajo antiguo alcance el Llavero y mantiene vigente el siguiente intento")
    func credentialOperationTicketCancellation() throws {
        let old = ModelCatalogCredentialOperation(), current = ModelCatalogCredentialOperation()
        try old.check(); try current.check()
        old.invalidate()
        #expect(throws: CancellationError.self) { try old.check() }
        #expect(throws: CancellationError.self) { try old.beginMutation() }
        #expect(!old.hasStartedMutation)
        try current.beginMutation()
        current.invalidate()
        #expect(current.hasStartedMutation)
        #expect(throws: CancellationError.self) { try current.check() }
        #expect(old.id != current.id)
    }

    @Test("Una mutación iniciada con resultado incierto limpia la cuenta anterior; un fallo anterior a la mutación la conserva")
    func startedMutationClearsUncertainAccount() throws {
        var access = ModelCatalogCredentialAccess(reader: { _, _ in .keychain(status: -25300, data: nil) })
        try access.authorized(.huggingFace, token: "prior-validated-synthetic-token")
        access.authorizationFailed(.huggingFace, status: .accessUnverified)
        #expect(access.background(.huggingFace).status == .available && access.background(.huggingFace).token != nil)
        access.mutationOutcomeUnverified(.huggingFace)
        #expect(access.background(.huggingFace).status == .accessUnverified && access.background(.huggingFace).token == nil)
        #expect(!access.background(.huggingFace).status.canUseAccount && !access.background(.huggingFace).status.hasSavedCredential)
        #expect(access.background(.civitai).token == nil)
    }

    @Test("La caché pública no lee el Llavero, admite solo una sonda por proveedor y descarta resultados anteriores a una autorización nueva")
    func boundedCredentialProbeTickets() throws {
        var access = ModelCatalogCredentialAccess(reader: { _, _ in .keychain(status: -25308, data: nil) })
        let pendingHF = access.beginProbe(.huggingFace), pendingCivitai = access.beginProbe(.civitai)
        let hf = try #require(pendingHF)
        let civitai = try #require(pendingCivitai)
        for _ in 0..<100 {
            let extraHF = access.beginProbe(.huggingFace), extraCivitai = access.beginProbe(.civitai)
            #expect(extraHF == nil && extraCivitai == nil)
            #expect(access.background(.huggingFace).status == .checking && access.background(.civitai).status == .checking)
            #expect(access.background(.huggingFace).token == nil && access.background(.civitai).token == nil)
        }
        access.invalidateProbe(.huggingFace)
        try access.authorized(.huggingFace, token: "new-synthetic-token")
        let appliedOld = access.completeProbe(.huggingFace, ticket: hf, result: .keychain(status: 0, data: Data("old-synthetic-token".utf8)))
        #expect(!appliedOld)
        #expect(access.background(.huggingFace).token == "new-synthetic-token")
        let appliedUnavailable = access.completeProbe(.civitai, ticket: civitai, result: .init(status: .accountUnavailable, token: nil))
        #expect(appliedUnavailable)
        #expect(access.background(.civitai).status == .accountUnavailable && access.background(.civitai).token == nil)
        let repeatedCivitai = access.beginProbe(.civitai), repeatedHF = access.beginProbe(.huggingFace)
        #expect(repeatedCivitai == nil && repeatedHF == nil)
        access.forget(.huggingFace)
        #expect(access.background(.huggingFace).status == .absent && access.background(.huggingFace).token == nil)
    }

}
