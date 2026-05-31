import Foundation
import NaturalLanguage

/// On-device semantic retrieval over a paper's sections (no extra model — uses Apple's
/// built-in NLEmbedding). Used to ground Custom Summaries and Chat answers in the most
/// relevant parts of the document so prompts stay within the model's context window.
enum Retriever {
    /// Return the `k` sections most relevant to `query`, best first.
    static func topSections(for query: String, in sections: [PaperSection], k: Int = 6) -> [PaperSection] {
        let bodies = sections.filter { $0.type != .sectionHeader && !$0.sentences.isEmpty }
        guard !bodies.isEmpty else { return [] }
        guard bodies.count > k else { return bodies }

        if let embedding = NLEmbedding.sentenceEmbedding(for: .english),
           let qVec = embedding.vector(for: query) {
            let scored = bodies.map { section -> (PaperSection, Double) in
                let text = String(section.sentences.joined(separator: " ").prefix(500))
                guard let v = embedding.vector(for: text) else { return (section, -1) }
                return (section, cosine(qVec, v))
            }
            return scored.sorted { $0.1 > $1.1 }.prefix(k).map { $0.0 }
        }

        // Fallback: keyword overlap if embeddings are unavailable.
        let terms = Set(query.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        let scored = bodies.map { section -> (PaperSection, Int) in
            let text = section.sentences.joined(separator: " ").lowercased()
            return (section, terms.reduce(0) { $0 + (text.contains($1) ? 1 : 0) })
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(k).map { $0.0 }
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count else { return -1 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom == 0 ? -1 : dot / denom
    }
}
