import AVFoundation

final class SystemTTSEngine: NSObject, TTSEngine {
    weak var delegate: (any TTSEngineDelegate)?
    private let synthesizer = AVSpeechSynthesizer()
    // Index tracked PER utterance — a shared currentIndex would be overwritten by a
    // new speak() before a stale didFinish reads it, breaking the stale-finish guard.
    private var utteranceIndices: [ObjectIdentifier: Int] = [:]
    private(set) var isSpeaking = false
    private(set) var isPaused = false
    /// Selected AVSpeechSynthesisVoice.identifier; empty = best available en-US.
    var voiceIdentifier: String = "" {
        didSet { if voiceIdentifier != oldValue { cachedVoice = nil } }
    }
    private var cachedVoice: AVSpeechSynthesisVoice?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    private func resolvedVoice() -> AVSpeechSynthesisVoice? {
        if let v = cachedVoice { return v }
        let v = SystemTTSEngine.bestVoice(preferring: voiceIdentifier)
        cachedVoice = v
        return v
    }

    /// The chosen voice if given, otherwise the best available en-US voice
    /// (Premium > Enhanced > Default, novelty voices excluded).
    static func bestVoice(preferring identifier: String = "") -> AVSpeechSynthesisVoice? {
        // Honor an explicit selection across ALL languages first.
        if !identifier.isEmpty,
           let chosen = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.identifier == identifier }) {
            return chosen
        }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en-US") }
            .filter { ($0.voiceTraits.rawValue & AVSpeechSynthesisVoice.Traits.isNoveltyVoice.rawValue) == 0 }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
            .first
    }

    func speak(sentence: String, at index: Int, rate: Float) {
        let utterance = AVSpeechUtterance(string: sentence)
        utteranceIndices[ObjectIdentifier(utterance)] = index
        utterance.voice = resolvedVoice()
        // Map 0–1 to AVSpeechUtteranceMinimumSpeechRate...Maximum
        let min = AVSpeechUtteranceMinimumSpeechRate
        let max = AVSpeechUtteranceMaximumSpeechRate
        utterance.rate = min + rate * (max - min)
        utterance.volume = 1.0
        isSpeaking = true; isPaused = false
        synthesizer.speak(utterance)
    }

    func pause() { synthesizer.pauseSpeaking(at: .word); isSpeaking = false; isPaused = true }
    func resume() { synthesizer.continueSpeaking(); isSpeaking = true; isPaused = false }
    func stop() {
        synthesizer.stopSpeaking(at: .immediate); isSpeaking = false; isPaused = false
        utteranceIndices.removeAll()
    }
}

extension SystemTTSEngine: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                            didStart utterance: AVSpeechUtterance) {
        // Audio actually began — clear the buffering/loading indicator.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            delegate?.engineDidBeginPlaying(self)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                            didFinish utterance: AVSpeechUtterance) {
        isSpeaking = false
        let id = ObjectIdentifier(utterance)
        let index = utteranceIndices[id] ?? -1
        utteranceIndices[id] = nil
        // AVSpeechSynthesizerDelegate fires on a background thread — dispatch to main
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            delegate?.engine(self, didFinishSentenceAt: index)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                            didCancel utterance: AVSpeechUtterance) {
        isSpeaking = false
        utteranceIndices[ObjectIdentifier(utterance)] = nil
    }
}
