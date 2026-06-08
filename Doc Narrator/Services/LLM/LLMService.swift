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

    /// User-editable system prompts (Settings → AI Prompts). Live so edits take effect at once.
    @Published var prompts: PromptSettings {
        didSet { if prompts != oldValue { prompts.save() } }
    }

    /// Character budget for the chat/summary context window, sized to the active model.
    /// Apple's on-device model has a ~4k-TOKEN total (input + output) — much smaller than it
    /// sounds — so it gets a tighter budget than Gemma to avoid context overflow (which makes
    /// Apple confabulate "I can't read the paper"). Same rolling-window mechanism for both;
    /// only the size differs.
    var contextCharBudget: Int {
        switch settings.providerType {
        case .appleFoundation: return 2400   // ~700–800 tokens of excerpts, leaves room in 4k
        case .mlxLocal:        return 6000   // Gemma E2B has more headroom
        case .off:             return 6000
        }
    }

    /// Output-token reservation, also sized to the active model's budget.
    var chatMaxOutputTokens: Int {
        settings.providerType == .appleFoundation ? 450 : 700
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
        self.prompts = PromptSettings.load()
        reconfigure()
    }

    private func reconfigure() {
        switch settings.providerType {
        case .appleFoundation:
            provider = AppleFoundationProvider()
        case .mlxLocal:
            provider = LiteRTProvider()   // downloadable Gemma via LiteRT-LM
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
        var delay: UInt64 = 1_500_000_000
        for attempt in 0..<4 {
            var yielded = false
            do {
                for try await delta in stream(system: system, user: user,
                                              maxTokens: maxTokens, temperature: temperature) {
                    yielded = true
                    continuation.yield(delta)
                }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Retry any transient error, but only if nothing was emitted yet.
                guard !yielded, attempt < 3 else { throw error }
                try await Task.sleep(nanoseconds: delay); delay *= 2
            }
        }
    }

    /// `complete` with exponential backoff on the on-device model's rate limit.
    private func completeRetrying(system: String, user: String,
                                  maxTokens: Int, temperature: Double) async throws -> String {
        var delay: UInt64 = 1_500_000_000
        for attempt in 0..<4 {
            do {
                return try await complete(system: system, user: user,
                                          maxTokens: maxTokens, temperature: temperature)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Retry any transient model error (rate limit, generic GenerationError -1, etc.).
                guard attempt < 3 else { throw error }
                try await Task.sleep(nanoseconds: delay)
                delay *= 2
            }
        }
        throw LLMError.unavailable("Couldn't generate.")
    }

    func cancel() { provider?.cancel() }

    // MARK: - Summarize (map-reduce so long papers fit the model's context window)

    /// General reader-facing summary of the whole paper.
    func summarize(sections: [PaperSection]) -> AsyncThrowingStream<String, Error> {
        summarizeCore(sections: sections, reduceSystem: prompts.generalSummary)
    }

    /// Summary focused on a topic: retrieve the most relevant sections, then summarize those
    /// with a topic-aware prompt. Falls back to the whole paper if retrieval finds nothing.
    func focusedSummary(topic: String, sections: [PaperSection]) -> AsyncThrowingStream<String, Error> {
        let picked = Retriever.topSections(for: topic, in: sections, k: 6)
        let source = picked.isEmpty ? sections : picked
        return summarizeCore(sections: source,
                             reduceSystem: prompts.resolvedCustomSummary(topic: topic))
    }

    // MARK: - Chat with PDF (retrieval-grounded Q&A)

    /// Answer a question about the document, grounded in the most relevant sections (retrieval)
    /// plus the recent conversation. Streams the answer. Keeps the prompt within the on-device
    /// model's context by sending only top-k sections and the last few turns.
    func chat(question: String,
              history: [ChatMessage],
              sections: [PaperSection],
              paperTitle: String = "") -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard provider != nil else {
                continuation.finish(throwing: LLMError.unavailable(statusText)); return
            }
            let budget = contextCharBudget
            let context = Self.chatContext(question: question, sections: sections,
                                           paperTitle: paperTitle, budget: budget)
            let convo = Self.recentHistory(history)
            let user = Self.chatUserPrompt(context: context, history: convo, question: question)
            let chatSystem = prompts.chat
            let maxOut = chatMaxOutputTokens
            let task = Task {
                do {
                    try await self.streamInto(continuation, system: chatSystem,
                                              user: user, maxTokens: maxOut, temperature: 0.3)
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

    /// Build the grounding context: top-k relevant sections, capped to a char budget sized to
    /// the active model (see `contextCharBudget`). Metadata questions (title / authors /
    /// abstract) don't retrieve well by embedding similarity — the word "title" isn't
    /// semantically close to the actual title text — so we detect that intent cheaply and pull
    /// the document's front matter ON DEMAND instead of always spending context on it.
    ///
    /// Retrieves more sections (k=8) than it can fit, then fills the budget best-first. The
    /// extra headroom reduces RAG brittleness: a one-word change in the question shifts the
    /// embedding less destructively when there's slack to absorb a reordering.
    private static func chatContext(question: String, sections: [PaperSection],
                                    paperTitle: String, budget: Int) -> String {
        var blocks: [String] = []
        var used = 0
        func add(_ text: String, heading: String? = nil) -> Bool {
            let body = sanitize(text)
            guard !body.isEmpty else { return true }
            let block = heading.map { "## \($0)\n\(body)" } ?? body
            if used + block.count > budget { return false }
            blocks.append(block); used += block.count
            return true
        }

        // On-demand front matter for metadata questions only. The title isn't stored as a
        // section (TextCleaner only emits abstract/header/body), so it comes from Paper.title.
        if isMetadataQuestion(question) {
            if !paperTitle.isEmpty { _ = add(paperTitle, heading: "Title") }
            for s in frontMatter(sections) {
                let heading = s.heading ?? defaultHeading(for: s.type)
                _ = add(s.sentences.joined(separator: " "), heading: heading)
            }
        }

        // Then the semantically retrieved sections, until the budget is full.
        let picked = Retriever.topSections(for: question, in: sections, k: 8)
        let source = picked.isEmpty ? sections : picked
        for s in source {
            let body = s.sentences.joined(separator: " ")
            guard !body.isEmpty else { continue }
            if !add(body, heading: s.heading) { break }
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Cheap keyword intent check for "what's the title/author/abstract?"-style questions.
    private static func isMetadataQuestion(_ q: String) -> Bool {
        let lower = q.lowercased()
        let keys = ["title", "titled", "called", "name of",
                    "author", "authors", "who wrote", "written by", "by whom",
                    "abstract", "what is this paper", "what's this paper", "what is this document"]
        return keys.contains { lower.contains($0) }
    }

    /// Title + abstract sections (the document's front matter), if present.
    private static func frontMatter(_ sections: [PaperSection]) -> [PaperSection] {
        sections.filter { $0.type == .title || $0.type == .abstract }
    }

    private static func defaultHeading(for type: SectionType) -> String? {
        switch type {
        case .title:    return "Title"
        case .abstract: return "Abstract"
        default:        return nil
        }
    }

    /// Keep the last few turns so the model has conversational context without overrunning.
    private static func recentHistory(_ history: [ChatMessage]) -> String {
        let recent = history.suffix(6)
        guard !recent.isEmpty else { return "" }
        return recent.map { m in
            let who = m.role == .user ? "User" : "Assistant"
            return "\(who): \(sanitize(m.text))"
        }.joined(separator: "\n")
    }

    private static func chatUserPrompt(context: String, history: String, question: String) -> String {
        var p = "Document excerpts:\n\(context)\n\n"
        if !history.isEmpty { p += "Conversation so far:\n\(history)\n\n" }
        p += "Question: \(question)"
        return p
    }

    /// Shared map-reduce engine so long inputs fit the model's context window.
    private func summarizeCore(sections: [PaperSection],
                               reduceSystem: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard provider != nil else {
                continuation.finish(throwing: LLMError.unavailable(statusText)); return
            }
            let mapSystem = prompts.map
            let foldSystem = prompts.fold
            let chunks = Self.buildChunks(from: sections)
            guard !chunks.isEmpty else {
                continuation.finish(throwing: LLMError.unavailable("No readable text in this document.")); return
            }
            let task = Task {
                do {
                    if chunks.count == 1 {
                        try await self.streamInto(continuation, system: reduceSystem,
                                                  user: Self.sanitize(chunks[0]),
                                                  maxTokens: 600, temperature: 0.3)
                        continuation.finish(); return
                    }
                    // MAP: condense each chunk (all chunks — never silently drop content).
                    // Paced + retried to stay under the on-device model's rate limit.
                    var summaries: [String] = []
                    var sawError: Error?
                    for (i, chunk) in chunks.enumerated() {
                        try Task.checkCancellation()
                        let clean = Self.sanitize(chunk)
                        guard clean.count > 20 else { continue }   // skip empty/near-empty chunks
                        if i > 0 { try await Task.sleep(nanoseconds: 1_000_000_000) }
                        do {
                            let part = try await self.completeRetrying(system: mapSystem, user: clean,
                                                                       maxTokens: 200, temperature: 0.2)
                            summaries.append(part)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            sawError = error   // skip this chunk; one bad chunk shouldn't kill it all
                        }
                    }
                    // Only fail outright if EVERY chunk failed.
                    if summaries.isEmpty { throw sawError ?? LLMError.unavailable("Couldn't generate a summary.") }
                    // FOLD: re-summarize in groups until the combined text fits one reduce pass.
                    while Self.combinedLength(summaries) > Self.foldCharBudget && summaries.count > 1 {
                        var folded: [String] = []
                        for group in Self.group(summaries, maxChars: Self.foldCharBudget) {
                            try Task.checkCancellation()
                            try await Task.sleep(nanoseconds: 1_000_000_000)
                            folded.append(try await self.completeRetrying(system: foldSystem, user: group,
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

    // Apple's on-device model has a ~4k-token context shared by input + output. Use large
    // chunks (~7000 chars ≈ ~2300 tokens, leaving room for the capped output) so a typical
    // paper needs only a handful of calls — fewer calls = far less chance of rate limiting.
    private static let chunkCharBudget = 5000
    private static let foldCharBudget = 5000   // max combined map-summary chars per reduce pass

    /// Clean extracted PDF text before sending to the model: drop control/format characters and
    /// odd symbols that can make the on-device model fail, normalize, and collapse whitespace.
    static func sanitize(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { scalar -> Character in
            if scalar == "\n" || scalar == "\t" { return " " }
            if scalar.value < 0x20 { return " " }                       // control chars
            if scalar.properties.isDefaultIgnorableCodePoint { return " " }
            return Character(scalar)
        }
        return String(scalars)
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: #"[ ]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
