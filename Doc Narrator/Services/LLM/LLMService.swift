import Foundation
import Combine

/// Owns the active LLM provider and exposes high-level intelligence operations to the UI.
/// Singleton + ObservableObject, mirroring LibraryStore. Re-selects the provider when
/// settings change (mirrors ReaderViewModel.reconfigureEngine()).
@MainActor
final class LLMService: ObservableObject {
    static let shared = LLMService()

    @Published private(set) var provider: (any LLMProvider)?
    @Published private(set) var status: LLMAvailability = .unavailable("Off")
    @Published var settings: LLMSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            reconfigure()
        }
    }

    /// True when an intelligence feature can run right now.
    var isReady: Bool { if case .available = status { return true }; return false }

    var statusText: String {
        switch status {
        case .available:            return "Ready"
        case .unavailable(let r):   return r
        }
    }

    private init() {
        self.settings = LLMSettings.load()
        reconfigure()
    }

    private func reconfigure() {
        switch settings.providerType {
        case .appleFoundation:
            provider = AppleFoundationProvider()
        case .mlxLocal:
            provider = nil   // Phase 4
        case .off:
            provider = nil
        }
        Task { await refreshStatus() }
    }

    func refreshStatus() async {
        guard let provider else { status = .unavailable("Off"); return }
        status = await provider.availability()
    }

    // MARK: - Generation

    /// Streams a response for arbitrary instructions + input. Higher-level ops
    /// (summarize / ask / explain) build on this in later phases.
    func stream(system: String, user: String,
                maxTokens: Int = 512, temperature: Double = 0.3) -> AsyncThrowingStream<String, Error> {
        guard let provider else {
            return AsyncThrowingStream { $0.finish(throwing: LLMError.unavailable("No model selected")) }
        }
        return provider.stream(LLMRequest(system: system, user: user,
                                          maxTokens: maxTokens, temperature: temperature))
    }

    func complete(system: String, user: String,
                  maxTokens: Int = 512, temperature: Double = 0.3) async throws -> String {
        guard let provider else { throw LLMError.unavailable("No model selected") }
        return try await provider.complete(LLMRequest(system: system, user: user,
                                                      maxTokens: maxTokens, temperature: temperature))
    }

    func cancel() { provider?.cancel() }

    // MARK: - Summarize (map-reduce so long papers fit the model's context window)

    func summarize(sections: [PaperSection]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard provider != nil else {
                continuation.finish(throwing: LLMError.unavailable(statusText)); return
            }
            let chunks = Self.buildChunks(from: sections)
            guard !chunks.isEmpty else {
                continuation.finish(throwing: LLMError.unavailable("No readable text in this document.")); return
            }
            let task = Task {
                do {
                    // Short doc (one chunk): summarize the text directly.
                    if chunks.count == 1 {
                        for try await delta in self.stream(system: Self.reduceSystem, user: chunks[0],
                                                           maxTokens: 450, temperature: 0.3) {
                            continuation.yield(delta)
                        }
                        continuation.finish(); return
                    }
                    // MAP: condense each chunk to a few sentences.
                    var summaries: [String] = []
                    for chunk in chunks {
                        try Task.checkCancellation()
                        let part = try await self.complete(system: Self.mapSystem, user: chunk,
                                                           maxTokens: 160, temperature: 0.2)
                        summaries.append(part)
                    }
                    // FOLD: if the combined summaries are still too big for one pass,
                    // re-summarize them in groups until they fit.
                    while Self.combinedLength(summaries) > Self.foldCharBudget && summaries.count > 1 {
                        var folded: [String] = []
                        for group in Self.group(summaries, maxChars: Self.foldCharBudget) {
                            try Task.checkCancellation()
                            folded.append(try await self.complete(system: Self.mapSystem, user: group,
                                                                  maxTokens: 160, temperature: 0.2))
                        }
                        summaries = folded
                    }
                    // REDUCE: stream the final reader-facing summary.
                    let reduceInput = summaries.joined(separator: "\n\n")
                    for try await delta in self.stream(system: Self.reduceSystem, user: reduceInput,
                                                       maxTokens: 450, temperature: 0.3) {
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: LLMError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static let mapSystem =
        "You are summarizing one part of a longer academic or technical document. " +
        "Write a concise, factual summary (3–5 sentences) of the key points in this part. " +
        "Only use information present in the text; do not speculate or add outside facts."

    private static let reduceSystem =
        "You are writing a clear, reader-friendly summary of a document for someone deciding " +
        "whether to read it. Using Markdown, output exactly:\n" +
        "**TL;DR** — a 2–3 sentence plain-language overview.\n\n" +
        "**Key points**\n- 4–7 bullet points of the most important takeaways.\n\n" +
        "Be concise and faithful to the source; do not invent details."

    // Apple's on-device model has a small (~4k token) context shared by input + output.
    // Keep each model call's input well under that. ~3 chars/token, so ~2800 chars ≈ ~950 tokens.
    private static let chunkCharBudget = 2800
    private static let foldCharBudget = 3000   // max combined map-summary chars per reduce pass
    private static let maxChunks = 24          // bound total map calls (and time) on huge docs

    /// Flatten sections into text and split into context-sized chunks. Each chunk is hard-capped
    /// in size (never merges overflow into one giant chunk). Very long docs are sampled evenly
    /// to `maxChunks` so the map step stays bounded.
    private static func buildChunks(from sections: [PaperSection]) -> [String] {
        var blocks: [String] = []
        for s in sections {
            if s.type == .sectionHeader {
                if let h = s.heading { blocks.append("## \(h)") }
                continue
            }
            let body = s.sentences.joined(separator: " ")
            guard !body.isEmpty else { continue }
            blocks.append(s.heading.map { "## \($0)\n\(body)" } ?? body)
        }
        let full = blocks.joined(separator: "\n\n")
        guard !full.isEmpty else { return [] }

        // Split on paragraph boundaries, but also hard-split any single paragraph
        // that exceeds the budget so no chunk is oversized.
        var chunks: [String] = []
        var current = ""
        func flush() { if !current.isEmpty { chunks.append(current); current = "" } }
        for para in full.components(separatedBy: "\n\n") {
            for piece in para.chunked(into: chunkCharBudget) {
                if !current.isEmpty && current.count + piece.count > chunkCharBudget { flush() }
                current += current.isEmpty ? piece : "\n\n" + piece
            }
        }
        flush()

        // Bound the number of chunks by sampling evenly (keeps coverage across the paper).
        if chunks.count > maxChunks {
            let step = Double(chunks.count) / Double(maxChunks)
            chunks = (0..<maxChunks).map { chunks[Int(Double($0) * step)] }
        }
        return chunks
    }

    private static func combinedLength(_ parts: [String]) -> Int {
        parts.reduce(0) { $0 + $1.count + 2 }
    }

    /// Group strings so each group's combined length stays under `maxChars`.
    private static func group(_ parts: [String], maxChars: Int) -> [String] {
        var groups: [String] = []
        var current = ""
        for p in parts {
            if !current.isEmpty && current.count + p.count > maxChars {
                groups.append(current); current = ""
            }
            current += current.isEmpty ? p : "\n\n" + p
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }
}

private extension String {
    /// Split into pieces of at most `size` characters (on a best-effort whitespace boundary).
    func chunked(into size: Int) -> [String] {
        guard count > size else { return [self] }
        var pieces: [String] = []
        var idx = startIndex
        while idx < endIndex {
            let end = index(idx, offsetBy: size, limitedBy: endIndex) ?? endIndex
            pieces.append(String(self[idx..<end]))
            idx = end
        }
        return pieces
    }
}
