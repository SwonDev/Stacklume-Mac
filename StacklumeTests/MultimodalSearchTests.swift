import Foundation
import Testing

@Suite("Búsqueda multimodal")
struct MultimodalSearchTests {
    @Test("Una consulta concreta conserva PDF y audio relevantes y elimina la cola de vecinos")
    func prunesUnrelatedNeighbors() {
        let pdf = UUID(), audio = UUID(), noise = UUID(), outside = UUID()
        let matches = [
            MultimodalSearchMatch(bookmarkID: outside, score: 0.99, modality: "text", location: nil, preview: ""),
            MultimodalSearchMatch(bookmarkID: pdf, score: 0.741, modality: "text", location: "página 1", preview: ""),
            MultimodalSearchMatch(bookmarkID: audio, score: 0.733, modality: "audio", location: "0:00", preview: ""),
            MultimodalSearchMatch(bookmarkID: noise, score: 0.610, modality: "image", location: nil, preview: "")
        ]
        #expect(MultimodalSearchRanking.relevant(matches, allowed: [pdf, audio, noise]).map(\.id) == [pdf, audio])
        #expect(Set(MultimodalSearchRanking.merge(literal: [noise], semantic: matches,
                                                allowed: [pdf, audio, noise])) == [pdf, audio, noise])
        #expect(MultimodalSearchRanking.relevant(matches, allowed: []).isEmpty)
    }

    @Test("La búsqueda respeta el ámbito, prioriza coincidencias y descarta ruido")
    func hybridScope() {
        let exact = UUID(), meaning = UUID(), excluded = UUID(), noise = UUID()
        let matches = [
            MultimodalSearchMatch(bookmarkID: excluded, score: 0.98, modality: "image", location: nil, preview: ""),
            MultimodalSearchMatch(bookmarkID: meaning, score: 0.72, modality: "text", location: nil, preview: ""),
            MultimodalSearchMatch(bookmarkID: exact, score: 0.61, modality: "text", location: nil, preview: ""),
            MultimodalSearchMatch(bookmarkID: noise, score: 0.05, modality: "text", location: nil, preview: "")
        ]
        #expect(MultimodalSearchRanking.merge(literal: [exact], semantic: matches,
                                             allowed: [exact, meaning, noise]) == [exact, meaning])
    }

    @Test("Un resultado externo no puede atribuirse a un enlace del corpus")
    func rejectsExternalPaths() {
        let id = UUID(), root = URL(fileURLWithPath: "/tmp/corpus")
        #expect(MultimodalSearchRanking.bookmarkID(from: "/tmp/corpus/\(id)/cover.jpg", corpus: root) == id)
        #expect(MultimodalSearchRanking.bookmarkID(from: "/tmp/corpus-otro/\(id)/cover.jpg", corpus: root) == nil)
        #expect(MultimodalSearchRanking.bookmarkID(from: "/tmp/corpus/../otro/\(id)/cover.jpg", corpus: root) == nil)
    }
}
