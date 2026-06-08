import Foundation
import Combine
import MediaPlayer
import PDFKit

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
                // The buffered upcoming sentences were synthesized at the OLD rate. Discard
                // them and re-synthesize at the new rate, so the change takes effect on the
                // next sentence (the current one finishes at its rate).
                engine.flushPrefetch()
                prefetchNextSentence()
            }
        }
    }

    var paper: Paper
    private(set) var engine: any TTSEngine
    private var sectionPauseTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    /// True when we auto-paused the document because a summary started generating, so we
    /// can auto-resume when it finishes (an LLM + TTS can't both run full speed on-device).
    private var pausedForGeneration = false

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

        // Auto-pause narration while a summary generates (they compete for the chip), and
        // auto-resume when it's done — fires only on true↔false transitions.
        SummaryGenerator.shared.$jobs
            .map { jobs in jobs.contains { $0.isGenerating } }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] generating in self?.handleGenerationState(generating) }
            .store(in: &cancellables)
    }

    private func handleGenerationState(_ generating: Bool) {
        if generating {
            if state == .playing {
                pausedForGeneration = true
                engine.flushPrefetch()   // stop pending synthesis so the CPU is actually freed
                pause()
            }
        } else if pausedForGeneration {
            pausedForGeneration = false
            if state == .paused { play() }
        }
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

    /// Restart the document from the very beginning and play.
    func restartFromBeginning() {
        engine.stop(); sectionPauseTask?.cancel()
        currentSectionIndex = 0; currentSentenceIndex = 0; globalSentenceIndex = 0
        savePosition()
        state = .playing
        speakCurrentSentence()
    }

    func skipToNextSection() {
        engine.stop(); sectionPauseTask?.cancel()
        advanceToNextSection()
        if state == .playing { speakCurrentSentence() }
    }

    func skipToNextSentence() {
        engine.stop(); sectionPauseTask?.cancel()
        setPosition(flat: min(max(totalSentences - 1, 0), globalSentenceIndex + 1))
        if state == .playing { speakCurrentSentence() }
    }

    func skipToPreviousSentence() {
        engine.stop(); sectionPauseTask?.cancel()
        setPosition(flat: max(0, globalSentenceIndex - 1))
        if state == .playing { speakCurrentSentence() }
    }

    private func setPosition(flat: Int) {
        guard let (si, sj) = sectionSentence(forFlat: flat) else { return }
        currentSectionIndex = si; currentSentenceIndex = sj; globalSentenceIndex = flat
        savePosition()
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
        // Reclaim the engine delegate — a SentenceNarrator (summary/chat read-aloud) may have
        // claimed it; the document loop must own finish callbacks while it's reading.
        engine.delegate = self
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
        // Synthesize a WINDOW of upcoming sentences so playback never waits on synthesis,
        // even when the CPU is busy. The engine buffers them; topped up after each sentence.
        let window = 6
        for offset in 1...window {
            let sj = currentSentenceIndex + offset
            guard sj < section.sentences.count else { break }
            engine.prefetch(sentence: section.sentences[sj],
                            at: globalSentenceIndex + offset,
                            rate: settings.rate)
        }
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
