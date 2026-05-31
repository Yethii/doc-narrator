import Foundation
import Combine
import MediaPlayer
import PDFKit
import NaturalLanguage

enum ReaderState: Equatable {
    case idle, processing, ready, playing, paused
    case error(String)
}

@MainActor
final class ReaderViewModel: ObservableObject, TTSEngineDelegate {

    @Published var state: ReaderState = .idle
    @Published var sections: [PaperSection] = []
    @Published var pdfDocument: PDFDocument?
    @Published var currentSectionIndex: Int = 0
    @Published var currentSentenceIndex: Int = 0
    /// True while a sentence is being synthesized but audio hasn't started yet.
    @Published var isBuffering: Bool = false
    /// Flat index across all non-header sentences (drives the progress scrubber).
    @Published private(set) var globalSentenceIndex: Int = 0
    @Published var settings: TTSSettings {
        didSet {
            // Only rebuild the engine when the engine type or OpenAI voice/model changes.
            // Rate and other display-only settings take effect on the next sentence via
            // settings.rate at call time — recreating here would free the C pointer while
            // a synthesis Task.detached is still running (use-after-free crash).
            if oldValue.engineType != settings.engineType
                    || oldValue.openAIVoice != settings.openAIVoice
                    || oldValue.openAIModel != settings.openAIModel
                    || oldValue.systemVoiceIdentifier != settings.systemVoiceIdentifier {
                reconfigureEngine()
            } else if oldValue.rate != settings.rate, state == .playing {
                // Cancel the in-flight prefetch (synthesized at old rate) and
                // immediately queue a new one at the updated rate.
                prefetchNextSentence()
            }
        }
    }

    var paper: Paper
    private(set) var engine: any TTSEngine
    private var sectionPauseTask: Task<Void, Never>?

    // Ad-hoc "read this text aloud" path (e.g. an LLM summary), separate from the
    // document reading loop. Uses a high index base so finish callbacks don't collide.
    private static let auxIndexBase = 1_000_000
    private var auxSentences: [String] = []
    private var auxIndex = 0
    private(set) var isReadingAux = false

    /// Total speakable (non-header) sentences in the document.
    var totalSentences: Int {
        sections.reduce(0) { $0 + ($1.type == .sectionHeader ? 0 : $1.sentences.count) }
    }

    /// 0...1 reading progress through the document.
    var progress: Double {
        let total = totalSentences
        guard total > 1 else { return 0 }
        return min(1, max(0, Double(globalSentenceIndex) / Double(total - 1)))
    }

    init(paper: Paper, settings: TTSSettings) {
        self.paper = paper
        self.settings = settings
        self.engine = SystemTTSEngine()
        reconfigureEngine()
        PlaybackCoordinator.shared.activeReader = self
    }

    // MARK: - Engine

    private func reconfigureEngine() {
        engine.stop()
        switch settings.engineType {
        case .kokoro:
            let e = KokoroTTSEngine.shared; e.delegate = self; engine = e
        case .system:
            let e = SystemTTSEngine()
            e.voiceIdentifier = settings.systemVoiceIdentifier
            e.delegate = self; engine = e
        case .openAI:
            let e = OpenAITTSEngine()
            e.apiKey = KeychainHelper.load(key: "openai_api_key") ?? ""
            e.voice = settings.openAIVoice.rawValue
            e.model = settings.openAIModel
            e.delegate = self; engine = e
        }
    }

    // MARK: - Load

    func load() async {
        state = .processing
        do {
            let url = try paper.resolveURL()
            defer { url.stopAccessingSecurityScopedResource() }
            // Load PDFDocument while the security scope is open
            pdfDocument = PDFDocument(url: url)
            let (_, pages) = try PDFProcessor.extractPages(from: url)
            let headers = PDFProcessor.detectRunningHeaders(pages: pages)
            sections = TextCleaner.clean(pages: pages, runningHeaders: headers)
            restorePosition(from: paper.lastReadSentenceIndex)
            state = .ready
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Playback

    func play() {
        guard state == .ready || state == .paused else { return }
        state = .playing
        PlaybackCoordinator.shared.updateNowPlaying(title: paper.title, author: paper.authors.first ?? "", isPlaying: true)
        speakCurrentSentence()
    }

    func pause() {
        guard state == .playing else { return }
        engine.pause(); sectionPauseTask?.cancel(); state = .paused; isBuffering = false
        PlaybackCoordinator.shared.updateNowPlaying(title: paper.title, author: paper.authors.first ?? "", isPlaying: false)
    }

    func stop() {
        engine.stop(); sectionPauseTask?.cancel(); state = .ready; isBuffering = false
        PlaybackCoordinator.shared.updateNowPlaying(title: paper.title, author: paper.authors.first ?? "", isPlaying: false)
    }

    func skipToNextSection() {
        engine.stop(); sectionPauseTask?.cancel()
        advanceToNextSection()
        if state == .playing { speakCurrentSentence() }
    }

    // Jump to any section/sentence and immediately start reading from there.
    func jumpTo(sectionIndex: Int, sentenceIndex: Int = 0) {
        engine.stop(); sectionPauseTask?.cancel()
        currentSectionIndex  = sectionIndex
        currentSentenceIndex = sentenceIndex
        // Recalculate flat sentence index
        var flat = 0
        for (si, sec) in sections.enumerated() {
            guard sec.type != .sectionHeader else { continue }
            if si < sectionIndex      { flat += sec.sentences.count }
            else if si == sectionIndex { flat += sentenceIndex; break }
        }
        globalSentenceIndex = flat
        savePosition()
        state = .playing
        speakCurrentSentence()
    }

    // MARK: - Read arbitrary text aloud (summaries, answers, explanations)

    /// Stop document playback and read `text` aloud through the current engine.
    func readAloud(_ text: String) {
        engine.stop(); sectionPauseTask?.cancel()
        auxSentences = Self.splitSentences(text)
        guard !auxSentences.isEmpty else { return }
        auxIndex = 0; isReadingAux = true
        state = .playing
        isBuffering = true
        PlaybackCoordinator.shared.updateNowPlaying(title: paper.title,
                                                    author: paper.authors.first ?? "", isPlaying: true)
        engine.speak(sentence: auxSentences[0], at: Self.auxIndexBase, rate: settings.rate)
    }

    /// Stop ad-hoc read-aloud (e.g. when the summary sheet is dismissed).
    func stopReadAloud() {
        guard isReadingAux else { return }
        engine.stop(); isReadingAux = false; isBuffering = false; state = .ready
        PlaybackCoordinator.shared.updateNowPlaying(title: paper.title,
                                                    author: paper.authors.first ?? "", isPlaying: false)
    }

    private func speakAux() {
        guard isReadingAux, auxIndex < auxSentences.count else { return }
        isBuffering = true
        engine.speak(sentence: auxSentences[auxIndex], at: Self.auxIndexBase + auxIndex, rate: settings.rate)
    }

    private static func splitSentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
            return true
        }
        return out
    }

    /// Persist an LLM-generated summary on the paper.
    func cacheSummary(_ text: String) {
        paper.cachedSummary = text
        LibraryStore.shared.update(paper: paper)
    }

    /// Scrub to a fraction (0...1) of the document and start reading from there.
    func seek(toFraction f: Double) {
        let total = totalSentences
        guard total > 0 else { return }
        let target = min(total - 1, max(0, Int((f * Double(total - 1)).rounded())))
        guard let (si, sj) = sectionSentence(forFlat: target) else { return }
        jumpTo(sectionIndex: si, sentenceIndex: sj)
    }

    /// Map a flat (non-header) sentence index back to its section/sentence position.
    private func sectionSentence(forFlat flatIndex: Int) -> (Int, Int)? {
        var count = 0
        for (si, section) in sections.enumerated() {
            if section.type == .sectionHeader { continue }
            for sj in section.sentences.indices {
                if count == flatIndex { return (si, sj) }
                count += 1
            }
        }
        return nil
    }

    func skipToPreviousSection() {
        engine.stop(); sectionPauseTask?.cancel()
        if currentSentenceIndex > 0 {
            currentSentenceIndex = 0
        } else if currentSectionIndex > 0 {
            currentSectionIndex -= 1; currentSentenceIndex = 0
        }
        if state == .playing { speakCurrentSentence() }
    }

    // MARK: - Core reading loop

    private func speakCurrentSentence() {
        guard currentSectionIndex < sections.count else { state = .ready; return }
        let section: PaperSection = sections[currentSectionIndex]

        if section.type == .sectionHeader {
            if let ann = section.announcement {
                isBuffering = true
                engine.speak(sentence: ann, at: globalSentenceIndex, rate: settings.rate * 0.9)
                // Don't prefetch across section boundaries — too complex to index correctly.
            } else {
                advanceToNextSection(); speakCurrentSentence()
            }
            return
        }

        guard currentSentenceIndex < section.sentences.count else {
            advanceAfterSection(); return
        }
        isBuffering = true
        engine.speak(sentence: section.sentences[currentSentenceIndex],
                     at: globalSentenceIndex, rate: settings.rate)
        prefetchNextSentence()
    }

    // Kick off background synthesis for the next sentence so it's ready when needed.
    // Only prefetches within the same body section; cross-section lookahead skipped.
    private func prefetchNextSentence() {
        guard currentSectionIndex < sections.count else { return }
        let section = sections[currentSectionIndex]
        guard section.type == .body || section.type == .abstract else { return }
        let nextSj = currentSentenceIndex + 1
        guard nextSj < section.sentences.count else { return }
        engine.prefetch(sentence: section.sentences[nextSj],
                        at: globalSentenceIndex + 1,
                        rate: settings.rate)
    }

    // MARK: - TTSEngineDelegate

    nonisolated func engine(_ engine: any TTSEngine, didFinishSentenceAt index: Int) {
        Task { @MainActor [weak self] in self?.handleSentenceFinished(finishedIndex: index) }
    }

    nonisolated func engine(_ engine: any TTSEngine, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.state = .error(error.localizedDescription) }
    }

    nonisolated func engineDidBeginPlaying(_ engine: any TTSEngine) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isBuffering = false   // audio actually started → switch highlight to "playing"
            PlaybackCoordinator.shared.updateNowPlaying(title: paper.title,
                                            author: paper.authors.first ?? "",
                                            isPlaying: true)
        }
    }

    private func handleSentenceFinished(finishedIndex: Int) {
        // Ad-hoc read-aloud (summary/answer/explanation) has its own index space.
        if isReadingAux {
            guard finishedIndex >= Self.auxIndexBase else { return }   // stale doc finish
            let idx = finishedIndex - Self.auxIndexBase
            guard idx == auxIndex else { return }                     // stale aux finish
            auxIndex += 1
            if auxIndex < auxSentences.count {
                speakAux()
            } else {
                isReadingAux = false; isBuffering = false; state = .ready
                PlaybackCoordinator.shared.updateNowPlaying(title: paper.title,
                                                            author: paper.authors.first ?? "", isPlaying: false)
            }
            return
        }
        guard state == .playing, currentSectionIndex < sections.count else { return }
        // Ignore stale finishes: when the user jumps/seeks mid-sentence, the engine
        // (esp. AVSpeech, which finishes on a background thread) can deliver a
        // didFinish for the OLD sentence after we've already moved. Advancing on it
        // would skip past — or randomly overshoot — the sentence we jumped to.
        guard finishedIndex == globalSentenceIndex else { return }
        let section: PaperSection = sections[currentSectionIndex]

        if section.type == .sectionHeader { advanceAfterSection(); return }

        globalSentenceIndex += 1; currentSentenceIndex += 1
        savePosition()

        if currentSentenceIndex >= section.sentences.count {
            // 0.8s pause at section boundaries
            sectionPauseTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                await self?.advanceAfterSection()
            }
        } else {
            speakCurrentSentence()
        }
    }

    @MainActor private func advanceAfterSection() {
        advanceToNextSection()
        guard state == .playing else { return }
        speakCurrentSentence()
    }

    private func advanceToNextSection() {
        if currentSectionIndex + 1 < sections.count {
            currentSectionIndex += 1; currentSentenceIndex = 0
        } else {
            state = .ready
            currentSectionIndex = 0; currentSentenceIndex = 0; globalSentenceIndex = 0
        }
    }

    // MARK: - Position persistence

    private func savePosition() {
        paper.lastReadSentenceIndex = globalSentenceIndex
        LibraryStore.shared.update(paper: paper)
    }

    private func restorePosition(from flatIndex: Int) {
        var count = 0
        for (si, section) in sections.enumerated() {
            if section.type == .sectionHeader { continue }
            for sj in section.sentences.indices {
                if count == flatIndex {
                    currentSectionIndex = si; currentSentenceIndex = sj
                    globalSentenceIndex = flatIndex; return
                }
                count += 1
            }
        }
    }
}
