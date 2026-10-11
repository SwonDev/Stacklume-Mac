import Foundation

/// Referencia estable al original; ningún vector ni puntuación se confunde con certeza.
struct MultimodalSearchMatch: Codable, Sendable, Identifiable {
    var id: UUID { bookmarkID }
    let bookmarkID: UUID
    let score: Double
    let modality: String
    let location: String?
    let preview: String
}

enum MultimodalSearchRanking {
    /// El límite de vecinos solo acota trabajo; no significa que todos sean relevantes.
    /// Los cosenos de este modelo tienen una base alta, incluso entre contenidos distintos.
    static func relevant(_ matches: [MultimodalSearchMatch], allowed: Set<UUID>? = nil) -> [MultimodalSearchMatch] {
        let candidates = matches.filter {
            $0.score.isFinite && $0.score >= 0.30 && (allowed?.contains($0.bookmarkID) ?? true)
        }
        guard let best = candidates.map(\.score).max() else { return [] }
        return candidates.filter { $0.score >= max(0.30, best - 0.06) }
    }

    /// Conserva coincidencias exactas y añade resultados por significado, una sola vez.
    static func merge(literal: [UUID], semantic: [MultimodalSearchMatch], allowed: Set<UUID>, limit: Int = 100) -> [UUID] {
        var scores: [UUID: Double] = [:]
        for (rank, id) in literal.enumerated() where allowed.contains(id) {
            scores[id, default: 0] += 2 / Double(20 + rank)
        }
        for (rank, match) in relevant(semantic, allowed: allowed).enumerated() {
            scores[match.bookmarkID, default: 0] += 1 / Double(20 + rank)
        }
        return scores.keys.sorted {
            if scores[$0] != scores[$1] { return scores[$0, default: 0] > scores[$1, default: 0] }
            return $0.uuidString < $1.uuidString
        }.prefix(max(0, limit)).map { $0 }
    }

    static func bookmarkID(from path: String, corpus: URL) -> UUID? {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let base = corpus.standardizedFileURL.path + "/"
        guard file.path.hasPrefix(base) else { return nil }
        return UUID(uuidString: String(file.path.dropFirst(base.count)).components(separatedBy: "/").first ?? "")
    }
}
