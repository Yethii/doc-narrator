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
                    // MAP: condense each chunk (skipped when the whole doc fits in one).
                    let reduceInput: String
                    if chunks.count == 1 {
                        reduceInput = chunks[0]
                    } else {
                        var parts: [String] = []
                        for (i, chunk) in chunks.enumerated() {
                            try Task.checkCancellation()
                            let part = try await self.complete(system: Self.mapSystem, user: chunk,
                                                               maxTokens: 300, temperature: 0.2)
                            parts.append("Section group \(i + 1):\n\(part)")
                        }
                        reduceInput = parts.joined(separator: "\n\n")
                    }
                    // REDUCE: stream the final reader-facing summary.
                    for try await delta in self.stream(system: Self.reduceSystem, user: reduceInput,
                                                       maxTokens: 700, temperature: 0.3) {
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

    /// Flatten sections into text and split into context-sized chunks on paragraph boundaries.
    private static func buildChunks(from sections: [PaperSection],
                                    maxChars: Int = 6000, maxChunks: Int = 8) -> [String] {
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

        var chunks: [String] = []
        var current = ""
        for para in full.components(separatedBy: "\n\n") {
            if !current.isEmpty && current.count + para.count > maxChars {
                chunks.append(current); current = ""
            }
            current += current.isEmpty ? para : "\n\n" + para
        }
        if !current.isEmpty { chunks.append(current) }

        // Cap chunk count: merge any overflow into the final chunk.
        if chunks.count > maxChunks {
            let head = Array(chunks.prefix(maxChunks - 1))
            let tail = chunks[(maxChunks - 1)...].joined(separator: "\n\n")
            chunks = head + [tail]
        }
        return chunks
    }
}
