import Foundation

protocol TTSEngineDelegate: AnyObject {
    func engine(_ engine: any TTSEngine, didFinishSentenceAt index: Int)
    func engine(_ engine: any TTSEngine, didFailWithError error: Error)
    /// Called the moment AVAudioPlayer.play() fires — use to update NowPlayingInfoCenter.
    func engineDidBeginPlaying(_ engine: any TTSEngine)
}

extension TTSEngineDelegate {
    func engineDidBeginPlaying(_ engine: any TTSEngine) {}
}

protocol TTSEngine: AnyObject {
    var delegate: (any TTSEngineDelegate)? { get set }
    var isSpeaking: Bool { get }
    var isPaused: Bool { get }
    /// Speak one sentence. `index` is echoed back in the delegate callback.
    func speak(sentence: String, at index: Int, rate: Float)
    /// Begin synthesizing the next sentence in the background while the current one plays.
    func prefetch(sentence: String, at index: Int, rate: Float)
    /// Discard the prefetched/buffered upcoming audio (e.g. after a speed change) so the
    /// next sentences can be re-synthesized with new parameters. The current sentence keeps playing.
    func flushPrefetch()
    func pause()
    func resume()
    func stop()
}

extension TTSEngine {
    func prefetch(sentence: String, at index: Int, rate: Float) {}
    func flushPrefetch() {}
}
