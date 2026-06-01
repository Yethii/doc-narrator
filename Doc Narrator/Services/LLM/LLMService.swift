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

    /// Human-readable label of the active model (recorded on saved artifacts).
    var currentModelLabel: String { settings.providerType.rawValue }

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

    /// Stream into a continuation, retrying the whole stream with backoff if the model
    /// rate-limits *before any tokens arrive* (can't cleanly resume mid-stream).
    private func streamInto(_ continuation: AsyncThrowingStream<String, Error>.Continuation,
                            system: String, user: String,
                            maxTokens: Int, temperature: Double) async throws {
        var delay: UInt64 = 2_000_000_000
        for attempt in 0..<5 {
            var yielded = false
            do {
                for try await delta in stream(system: system, user: user,
                                              maxTokens: maxTokens, temperature: temperature) {
                    yielded = true
                    continuation.yield(delta)
                }
                return
            } catch {
                let msg = String(describing: error).lowercased()
                let isRateLimit = msg.contains("rate") && (msg.contains("limit") || msg.contains("exceed"))
                guard isRateLimit, !yielded, attempt < 4 else { throw error }
                try await Task.sleep(nanoseconds: delay); delay *= 2
            }
        }
    }

    /// `complete` with exponential backoff on the on-device model's rate limit.
    private func completeRetrying(system: String, user: String,
                                  maxTokens: Int, temperature: Double) async throws -> String {
        var delay: UInt64 = 2_000_000_000   // 2s
        for attempt in 0..<5 {
            do {
                return try await complete(system: system, user: user,
                                          maxTokens: maxTokens, temperature: temperature)
            } catch {
                let msg = String(describing: error).lowercased()
                let isRateLimit = msg.contains("rate") && (msg.contains("limit") || msg.contains("exceed"))
                guard isRateLimit, attempt < 4 else { throw error }
                try await Task.sleep(nanoseconds: delay)
                delay *= 2
            }
        }
        throw LLMError.unavailable("Rate limited")
    }

    func cancel() { provider?.cancel() }

    // MARK: - Summarize (map-reduce so long papers fit the model's context window)

    /// General reader-facing summary of the whole paper.
    func summarize(sections: [PaperSection]) -> AsyncThrowingStream<String, Error> {
        summarizeCore(sections: sections, reduceSystem: Self.reduceSystem)
    }

    /// Summary focused on a topic: retrieve the most relevant sections, then summarize those
    /// with a topic-aware prompt. Falls back to the whole paper if retrieval finds nothing.
    func focusedSummary(topic: String, sections: [PaperSection]) -> AsyncThrowingStream<String, Error> {
        let picked = Retriever.topSections(for: topic, in: sections, k: 6)
        let source = picked.isEmpty ? sections : picked
        let reduce =
            "Summarize what the document says about a specific topic: \"\(topic)\". " +
            "Begin with a 2–4 sentence plain-language overview focused on that topic (no heading " +
            "or label), then a blank line and a line **Key points** with 3–6 concise bullets. " +
            "If the document barely covers the topic, say so plainly. Be faithful to the source; " +
            "do not invent details and do not add a 'TL;DR' label."
        return summarizeCore(sections: source, reduceSystem: reduce)
    }

    /// Shared map-reduce engine so long inputs fit the model's context window.
    private func summarizeCore(sections: [PaperSection],
                               reduceSystem: String) -> AsyncThrowingStream<String, Error> {
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
                    if chunks.count == 1 {
                        try await self.streamInto(continuation, system: reduceSystem, user: chunks[0],
                                                  maxTokens: 600, temperature: 0.3)
                        continuation.finish(); return
                    }
                    // MAP: condense each chunk (all chunks — never silently drop content).
                    // Paced + retried to stay under the on-device model's rate limit.
                    var summaries: [String] = []
                    for (i, chunk) in chunks.enumerated() {
                        try Task.checkCancellation()
                        if i > 0 { try await Task.sleep(nanoseconds: 1_000_000_000) }
                        let part = try await self.completeRetrying(system: Self.mapSystem, user: chunk,
                                                                   maxTokens: 200, temperature: 0.2)
                        summaries.append(part)
                    }
                    // FOLD: re-summarize in groups until the combined text fits one reduce pass.
                    while Self.combinedLength(summaries) > Self.foldCharBudget && summaries.count > 1 {
                        var folded: [String] = []
                        for group in Self.group(summaries, maxChars: Self.foldCharBudget) {
                            try Task.checkCancellation()
                            try await Task.sleep(nanoseconds: 1_000_000_000)
                            folded.append(try await self.completeRetrying(system: Self.mapSystem, user: group,
                                                                          maxTokens: 200, temperature: 0.2))
                        }
                        summaries = folded
                    }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    // REDUCE: stream the final reader-facing summary.
                    try await self.streamInto(continuation, system: reduceSystem,
                                              user: summaries.joined(separator: "\n\n"),
                                              maxTokens: 600, temperature: 0.3)
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
        "You are writing a clear, reader-friendly summary of a document. Begin with a 2–4 " +
        "sentence plain-language overview (no heading or label). Then a blank line and a line " +
        "**Key points** followed by 4–7 concise bullets of the most important takeaways. " +
        "Be accurate and faithful to the source; do not invent details and do not add a " +
        "'TL;DR' label."

    // Apple's on-device model has a ~4k-token context shared by input + output. Use large
    // chunks (~7000 chars ≈ ~2300 tokens, leaving room for the capped output) so a typical
    // paper needs only a handful of calls — fewer calls = far less chance of rate limiting.
    private static let chunkCharBudget = 8000
    private static let foldCharBudget = 8000   // max combined map-summary chars per reduce pass

    /// Flatten sections into text and split into context-sized chunks. Each chunk is hard-capped
    /// in size (never merges overflow into one giant chunk). ALL chunks are summarized — content
    /// is never dropped; long docs just take longer (mitigated by background generation).
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
