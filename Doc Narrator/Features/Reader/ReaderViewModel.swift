import Foundation
import Combine

enum ReaderState: Equatable {
    case idle, processing, ready, playing, paused
    case error(String)
}

@MainActor
final class ReaderViewModel: ObservableObject, TTSEngineDelegate {

    @Published var state: ReaderState = .idle
    @Published var sections: [PaperSection] = []
    @Published var currentSectionIndex: Int = 0
    @Published var currentSentenceIndex: Int = 0
    @Published var settings: TTSSettings {
        didSet { reconfigureEngine() }
    }

    var paper: Paper
    private(set) var engine: any TTSEngine
    private var globalSentenceIndex: Int = 0
    private var sectionPauseTask: Task<Void, Never>?

    init(paper: Paper, settings: TTSSettings) {
        self.paper = paper
        self.settings = settings
        self.engine = SystemTTSEngine()
        reconfigureEngine()
    }

    // MARK: - Engine

    private func reconfigureEngine() {
        engine.stop()
        switch settings.engineType {
        case .system:
            let e = SystemTTSEngine(); e.delegate = self; engine = e
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
        state = .playing; speakCurrentSentence()
    }

    func pause() {
        guard state == .playing else { return }
        engine.pause(); sectionPauseTask?.cancel(); state = .paused
    }

    func stop() { engine.stop(); sectionPauseTask?.cancel(); state = .ready }

    func skipToNextSection() {
        engine.stop(); sectionPauseTask?.cancel()
        advanceToNextSection()
        if state == .playing { speakCurrentSentence() }
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
                engine.speak(sentence: ann, at: globalSentenceIndex, rate: settings.rate * 0.9)
            } else {
                advanceToNextSection(); speakCurrentSentence()
            }
            return
        }

        guard currentSentenceIndex < section.sentences.count else {
            advanceAfterSection(); return
        }
        engine.speak(sentence: section.sentences[currentSentenceIndex],
                     at: globalSentenceIndex, rate: settings.rate)
    }

    // MARK: - TTSEngineDelegate

    nonisolated func engine(_ engine: any TTSEngine, didFinishSentenceAt index: Int) {
        Task { @MainActor [weak self] in self?.handleSentenceFinished() }
    }

    nonisolated func engine(_ engine: any TTSEngine, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.state = .error(error.localizedDescription) }
    }

    private func handleSentenceFinished() {
        guard state == .playing, currentSectionIndex < sections.count else { return }
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
