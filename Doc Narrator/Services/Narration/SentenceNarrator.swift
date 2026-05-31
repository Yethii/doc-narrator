import Foundation
import Combine

/// Plays an ordered list of plain-text sentences aloud, gap-free, through the active TTS engine.
/// Reusable by any AI-text surface (summaries, chat). Mirrors the document reader's prefetch
/// pipeline so there are no pauses between sentences, and reports `currentIndex` for highlighting.
///
/// Coexistence: the document reader and this narrator may both use `KokoroTTSEngine.shared`.
/// They are never active simultaneously; each claims `engine.delegate = self` when it speaks
/// (last-writer-wins), so finish callbacks always route to the current owner.
@MainActor
final class SentenceNarrator: NSObject, ObservableObject, TTSEngineDelegate {
    @Published private(set) var sentences: [String] = []
    @Published private(set) var currentIndex: Int = -1
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false

    @Published var settings: TTSSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            if oldValue.engineType != settings.engineType
                || oldValue.openAIVoice != settings.openAIVoice
                || oldValue.openAIModel != settings.openAIModel
                || oldValue.systemVoiceIdentifier != settings.systemVoiceIdentifier {
                let wasPlaying = isPlaying
                let idx = max(0, currentIndex)
                reconfigureEngine()
                if wasPlaying { jump(to: idx) }   // restart current sentence on the new engine
            }
        }
    }

    private var engine: any TTSEngine
    private static let indexBase = 2_000_000   // distinct from the document loop's index space

    override init() {
        self.settings = TTSSettings.load()
        self.engine = SystemTTSEngine()
        super.init()
        reconfigureEngine()
    }

    /// Replace the queue. Stops any current playback.
    func load(sentences: [String]) {
        stop()
        self.sentences = sentences
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard !sentences.isEmpty else { return }
        if currentIndex < 0 || currentIndex >= sentences.count { currentIndex = 0 }
        engine.delegate = self
        isPlaying = true
        speakCurrent()
    }

    func pause() {
        engine.pause(); isPlaying = false; isBuffering = false
    }

    func jump(to index: Int) {
        guard index >= 0, index < sentences.count else { return }
        engine.stop()
        engine.delegate = self
        currentIndex = index
        isPlaying = true
        speakCurrent()
    }

    func stop() {
        engine.stop()
        isPlaying = false; isBuffering = false; currentIndex = -1
    }

    private func speakCurrent() {
        guard isPlaying, currentIndex >= 0, currentIndex < sentences.count else { return }
        engine.delegate = self
        isBuffering = true
        engine.speak(sentence: sentences[currentIndex], at: Self.indexBase + currentIndex, rate: settings.rate)
        let next = currentIndex + 1
        if next < sentences.count {
            engine.prefetch(sentence: sentences[next], at: Self.indexBase + next, rate: settings.rate)
        }
    }

    private func reconfigureEngine() {
        engine.stop()
        switch settings.engineType {
        case .kokoro:
            let e = KokoroTTSEngine.shared; e.delegate = self; engine = e
        case .system:
            let e = SystemTTSEngine(); e.voiceIdentifier = settings.systemVoiceIdentifier
            e.delegate = self; engine = e
        case .openAI:
            let e = OpenAITTSEngine()
            e.apiKey = KeychainHelper.load(key: "openai_api_key") ?? ""
            e.voice = settings.openAIVoice.rawValue
            e.model = settings.openAIModel
            e.delegate = self; engine = e
        }
    }

    // MARK: - TTSEngineDelegate

    nonisolated func engine(_ engine: any TTSEngine, didFinishSentenceAt index: Int) {
        Task { @MainActor [weak self] in self?.handleFinished(index) }
    }

    nonisolated func engine(_ engine: any TTSEngine, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.isBuffering = false; self?.isPlaying = false }
    }

    nonisolated func engineDidBeginPlaying(_ engine: any TTSEngine) {
        Task { @MainActor [weak self] in self?.isBuffering = false }
    }

    private func handleFinished(_ finishedIndex: Int) {
        guard isPlaying else { return }
        let idx = finishedIndex - Self.indexBase
        guard idx == currentIndex else { return }   // ignore stale finishes after a jump
        let next = currentIndex + 1
        if next < sentences.count {
            currentIndex = next
            speakCurrent()
        } else {
            isPlaying = false; isBuffering = false   // keep currentIndex on the last sentence
        }
    }
}
