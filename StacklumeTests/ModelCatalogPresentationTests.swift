import Foundation
import Testing

@Suite("Presentación y ventana de resultados del catálogo")
struct ModelCatalogPresentationTests {
    private func item(_ id: String) -> ModelCatalogItem {
        .snapshot(provider: .civitai, id: id, title: "Modelo \(id)", author: nil, site: .standard, rating: .pg)
    }

    @Test("Cargar más mantiene la selección previa y elimina modelos repetidos entre cursores")
    func cursorOverlap() throws {
        let original = [item("1"), item("2")]
        let next = [item("2"), item("3"), item("4")]
        let loaded = try ModelCatalogResultWindow.appending(next, to: original)
        #expect(loaded.map(\.id) == ["1", "2", "3", "4"])
        #expect(loaded.first == original.first)
    }

    @Test("La ventana admite 300 modelos y rechaza una página que excedería esa cota sin recortar datos")
    func boundedWindow() throws {
        let initial = (1...240).map { item(String($0)) }
        #expect(ModelCatalogResultWindow.canAppend(count: initial.count, pageSize: 60))
        let full = try ModelCatalogResultWindow.appending((241...300).map { item(String($0)) }, to: initial)
        #expect(full.count == 300)
        #expect(!ModelCatalogResultWindow.canAppend(count: full.count, pageSize: 60))
        #expect(throws: ModelCatalogError.tooLarge) { try ModelCatalogResultWindow.appending([item("301")], to: full) }
        #expect(full.last?.id == "300")
    }

    @Test("El límite elegido viaja en la petición real del proveedor y no altera NSFW ni RED")
    func upstreamLimit() throws {
        for provider in ModelCatalogProvider.allCases {
            for size in [30, 60, 100] {
                var filters = ModelCatalogFilters()
                filters.pageSize = size; filters.civitaiSite = .red; filters.adultFilter = .only
                let url = try ModelCatalogRequest.searchURL(provider: provider, filters: filters)
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                #expect(query.first { $0.name == "limit" }?.value == String(size))
                if provider == .civitai {
                    #expect(url.host == "civitai.red")
                    #expect(query.first { $0.name == "nsfw" }?.value == "true")
                }
            }
        }
    }

    @Test("Tamaños no admitidos no pueden enviar límites arbitrarios al proveedor")
    func validatedLimit() throws {
        var filters = ModelCatalogFilters(); filters.pageSize = Int.max
        let url = try ModelCatalogRequest.searchURL(provider: .civitai, filters: filters)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "limit" }?.value == "60")
    }

    @Test("Tipo, base y versión proceden de campos recibidos, conservando familias desconocidas y diversidad")
    func publishedFacets() throws {
        let data = Data(#"{"items":[{"id":42,"name":"Título con Flux pero base distinta","type":"LORA","nsfwLevel":1,"modelVersions":[{"id":91,"name":"Versión Krea publicada","baseModel":"Krea 2 desconocida"},{"id":92,"name":"Otra","baseModel":"Illustrious"},{"id":93,"name":"Tercera","baseModel":"Qwen Image"}]}]}"#.utf8)
        let model = try ModelCatalogDecoding.page(data: data, provider: .civitai, filters: .init(), currentURL: URL(string: "https://civitai.com/api/v1/models")!, link: nil).items[0]
        let info = ModelCatalogResultSummary(item: model)
        #expect(info.kind == "LORA")
        #expect(info.baseModel == "Krea 2 desconocida")
        #expect(info.versionName == "Versión Krea publicada")
        #expect(info.otherBaseModels == ["Illustrious", "Qwen Image"])
        #expect(info.otherVersionCount == 2)
    }

    @Test("Candidatos reales de todas las versiones: omite adultos y medios activos, admite poster y respaldo")
    func coverCandidates() throws {
        let data = Data(#"{"items":[{"id":45,"name":"Modelo","type":"LORA","nsfwLevel":1,"modelVersions":[{"id":1,"name":"Primera","images":[{"id":10,"url":"https://image.civitai.com/public/adult.jpeg","nsfwLevel":8},{"id":11,"url":"https://image.civitai.com/public/good.webp","nsfwLevel":1,"thumbnail":"https://image.civitai.com/public/missing.jpeg"}]},{"id":2,"name":"Otra","images":[{"id":12,"type":"video","url":"https://image.civitai.com/public/demo.mp4","nsfwLevel":1,"thumbnail":"https://image.civitai.com/public/poster.avif"},{"id":13,"url":"https://image.civitai.com/public/good.webp","nsfwLevel":1},{"id":14,"url":"https://image.civitai.com/public/script.svg","nsfwLevel":1}]}]}]}"#.utf8)
        let model = try ModelCatalogDecoding.page(data: data, provider: .civitai, filters: .init(), currentURL: URL(string: "https://civitai.com/api/v1/models")!, link: nil).items[0]
        let candidates = ModelCatalogCoverCandidates(item: model, adultFilter: .exclude)
        #expect(candidates.urls.map(\.lastPathComponent) == ["missing.jpeg", "good.webp", "poster.avif"])
        #expect(candidates.media.map(\.id) == ["11", "12", "13"])
        #expect(candidates.media[1].kind == .video)
        #expect(!candidates.urls.contains { $0.pathExtension == "mp4" || $0.pathExtension == "svg" })
        #expect(ModelCatalogCoverCandidates(item: model, adultFilter: .only).urls.map(\.lastPathComponent) == ["adult.jpeg"])
    }

    @Test("Hugging Face conserva imagen publicada en el widget y su clasificación real")
    func widgetCandidate() throws {
        let data = Data(#"[{"id":"demo/widget","tags":["nsfw"],"cardData":{"widget":[{"text":"prompt original","output":{"url":"assets/output.webp","futureField":"original"}}]},"sha":"abc"}]"#.utf8)
        let item = try ModelCatalogDecoding.page(data: data, provider: .huggingFace, filters: .init(), currentURL: URL(string: "https://huggingface.co/api/models")!, link: nil).items[0]
        #expect(ModelCatalogCoverCandidates(item: item, adultFilter: .exclude).urls.isEmpty)
        let adult = ModelCatalogCoverCandidates(item: item, adultFilter: .only)
        #expect(adult.urls.first?.path == "/demo/widget/resolve/abc/assets/output.webp")
        #expect(adult.media.first?.rawMetadata != nil)
    }

    @Test("Un vídeo de Civitai sin poster usa su fotograma del CDN, sin descargar el vídeo como imagen")
    func civitaiVideoStillCandidate() throws {
        let video = URL(string: "https://image.civitai.com/xG1nkqKTMzGDvpLrqFT7WA/a2fc6439-d562-42c4-a5ea-1764516861d2/original=true/963567.mp4")!
        let media = ModelCatalogPreview(url: video, isAdult: false, kind: .video)
        let candidates = ModelCatalogPreviewCandidates(media: media, provider: .civitai)
        let poster = try #require(candidates.urls.first)
        #expect(poster.host == video.host)
        #expect(poster.lastPathComponent == "963567.jpeg")
        #expect(poster.path.contains("anim=false"))
        #expect(poster.path.contains("transcode=true"))
        #expect(poster.path.contains("width=640"))
        #expect(!poster.path.contains("original=true"))
        #expect(!candidates.urls.contains(video))
        #expect(media.url == video && media.kind == .video)
    }

    @Test("El poster publicado tiene prioridad y el fotograma derivado es un respaldo de la misma muestra")
    func publishedVideoPosterPrecedesStill() {
        let video = URL(string: "https://image.civitai.com/account/object/original=true/sample.mp4")!
        let published = URL(string: "https://image.civitai.com/account/thumbnail/width=450/sample.webp")!
        let media = ModelCatalogPreview(url: video, isAdult: false, kind: .video, thumbnailURL: published)
        let urls = ModelCatalogPreviewCandidates(media: media, provider: .civitai).urls
        #expect(urls.map(\.lastPathComponent) == ["sample.webp", "sample.jpeg"])
    }

    @Test("No inventa fotogramas del Hub, audio ni rutas ajenas al CDN de Civitai")
    func videoStillBoundary() {
        let samples: [(String, ModelCatalogProvider, ModelCatalogMediaKind)] = [
            ("https://huggingface.co/org/model/resolve/main/sample.mp4", .huggingFace, .video),
            ("https://blobs-b2.civitai.com/file/blobs-managed-public/sample.mp4", .civitai, .video),
            ("https://image.civitai.com/account/object/original=true/sample.mp3", .civitai, .audio),
            ("https://image.civitai.com.evil.test/account/object/original=true/sample.mp4", .civitai, .video),
            ("https://image.civitai.com/account/object/original=true/sample.mp4?token=secret", .civitai, .video)
        ]
        for (raw, provider, kind) in samples {
            let media = ModelCatalogPreview(url: URL(string: raw)!, isAdult: false, kind: kind)
            #expect(ModelCatalogPreviewCandidates(media: media, provider: provider).urls.isEmpty)
        }
    }

    @Test("Tamaño grande se adapta al viewport estrecho y conserva la preferencia en pantallas amplias")
    func narrowCard() {
        #expect(ModelCatalogPreviewSize.large.cardWidth(in: 308) == 308)
        #expect(ModelCatalogPreviewSize.large.cardWidth(in: 1_000) == 360)
        #expect(ModelCatalogPreviewSize.large.cardWidth(in: -8) == 1)
    }

    @Test("Las bases múltiples de cardData del Hub son datos publicados, no nombres inferidos")
    func huggingFaceBases() throws {
        let data = Data(#"[{"id":"org/demo","pipeline_tag":"image-to-text","cardData":{"base_model":["org/Qwen-base","org/another-base","org/Qwen-base"]},"sha":"abc"}]"#.utf8)
        let item = try ModelCatalogDecoding.page(data: data, provider: .huggingFace, filters: .init(), currentURL: URL(string: "https://huggingface.co/api/models")!, link: nil).items[0]
        let info = ModelCatalogResultSummary(item: item)
        #expect(info.kind == "image-to-text")
        #expect(info.baseModel == "org/Qwen-base")
        #expect(info.otherBaseModels == ["org/another-base"])
    }

    @Test("Sin datos publicados no se deduce una familia del título")
    func unknownIsHonest() {
        let model = ModelCatalogItem.snapshot(provider: .civitai, id: "44", title: "Flux Krea Qwen", author: nil, site: .standard, rating: .pg)
        let info = ModelCatalogResultSummary(item: model)
        #expect(info.baseModel == nil && info.versionName == nil && info.kind == nil)
    }
}
