import Foundation
import Combine

/// Plays an ordered list of plain-text sentences aloud, gap-free, through the active TTS engine.
/// Reusable by any AI-text surface (summaries, chat). Mirrors the document reader's prefetch
/// pipeline so there are no pauses, and reports `currentIndex` for highlighting.
///
/// IMPORTANT: the engine is acquired *lazily* — the narrator never touches the (shared) TTS
/// engine until the user actually plays. Merely creating a narrator (when a summary view
/// appears) must not stop or hijack the document reader's playback.
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
            let engineChanged = oldValue.engineType != settings.engineType
                || oldValue.openAIVoice != settings.openAIVoice
                || oldValue.openAIModel != settings.openAIModel
                || oldValue.systemVoiceIdentifier != settings.systemVoiceIdentifier
            if engineChanged {
                let wasPlaying = isPlaying
                let idx = max(0, currentIndex)
                if wasPlaying { engine?.stop() }
                engine = nil                 // drop reference; rebuilt lazily on next play
                if wasPlaying { jump(to: idx) }
            }
        }
    }

    private var engine: (any TTSEngine)?
    private static let indexBase = 2_000_000   // distinct from the document loop's index space

    override init() {
        self.settings = TTSSettings.load()
        super.init()
    }

    /// Replace the queue. Stops only our own playback (never an idle shared engine).
    func load(sentences: [String]) {
        stop()
        self.sentences = sentences
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard !sentences.isEmpty else { return }
        if currentIndex < 0 || currentIndex >= sentences.count { currentIndex = 0 }
        isPlaying = true
        speakCurrent()
    }

    func pause() {
        engine?.pause(); isPlaying = false; isBuffering = false
    }

    func jump(to index: Int) {
        guard index >= 0, index < sentences.count else { return }
        let e = ensureEngine()
        e.stop(); e.delegate = self
        currentIndex = index
        isPlaying = true
        speakCurrent()
    }

    func stop() {
        engine?.stop()
        isPlaying = false; isBuffering = false; currentIndex = -1
    }

    private func ensureEngine() -> any TTSEngine {
        if let engine { return engine }
        let e: any TTSEngine
        switch settings.engineType {
        case .kokoro:
            e = KokoroTTSEngine.shared
        case .system:
            let s = SystemTTSEngine(); s.voiceIdentifier = settings.systemVoiceIdentifier; e = s
        case .openAI:
            let o = OpenAITTSEngine()
            o.apiKey = KeychainHelper.load(key: "openai_api_key") ?? ""
            o.voice = settings.openAIVoice.rawValue
            o.model = settings.openAIModel
            e = o
        }
        engine = e
        return e
    }

    private func speakCurrent() {
        guard isPlaying, currentIndex >= 0, currentIndex < sentences.count else { return }
        let e = ensureEngine()
        e.delegate = self                 // claim the (possibly shared) engine while we read
        isBuffering = true
        e.speak(sentence: sentences[currentIndex], at: Self.indexBase + currentIndex, rate: settings.rate)
        // Synthesize a window ahead so narration never pauses between sentences.
        for offset in 1...4 {
            let n = currentIndex + offset
            guard n < sentences.count else { break }
            e.prefetch(sentence: sentences[n], at: Self.indexBase + n, rate: settings.rate)
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
        guard idx == currentIndex else { return }   // ignore stale finishes / the document loop's
        let next = currentIndex + 1
        if next < sentences.count {
            currentIndex = next
            speakCurrent()
        } else {
            isPlaying = false; isBuffering = false   // keep currentIndex on the last sentence
        }
    }
}
