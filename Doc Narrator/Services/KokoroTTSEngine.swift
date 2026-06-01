import AVFoundation
import Foundation
import OSLog

private let log = Logger(subsystem: "in.lyr.Doc-Narrator", category: "KokoroTTS")

// Serializes sherpa-onnx C API calls — the library is not safe for concurrent synthesis
// on the same TTS handle. Swift actors guarantee at-most-one concurrent execution.
private actor SynthesisSerializer {
    private let tts: OpaquePointer

    init(tts: OpaquePointer) { self.tts = tts }

    func synthesize(text: String, voiceID: Int32, speed: Float) -> Data? {
        // If the calling task was cancelled while waiting in the actor queue,
        // skip the expensive C call immediately — drains backlogs from rapid pause/play.
        guard !Task.isCancelled else { return nil }
        return text.withCString { cText -> Data? in
            var genCfg = SherpaOnnxGenerationConfig()
            genCfg.sid   = voiceID
            genCfg.speed = speed
            guard let audio = SherpaOnnxOfflineTtsGenerateWithConfig(tts, cText, &genCfg, nil, nil) else {
                log.warning("Synthesis nil: \(text.prefix(60))")
                return nil
            }
            defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
            guard let samplesPtr = audio.pointee.samples, audio.pointee.n > 0 else {
                log.warning("Empty audio: \(text.prefix(60))")
                return nil
            }
            let count  = Int(audio.pointee.n)
            let sr     = Int(audio.pointee.sample_rate)
            let samples = Array(UnsafeBufferPointer(start: samplesPtr, count: count))
            log.debug("Synthesized \(count) samples @ \(sr) Hz")
            return KokoroTTSEngine.pcmToWAV(samples: samples, sampleRate: sr)
        }
    }
}

/// On-device TTS using Kokoro via sherpa-onnx C API.
/// Voice IDs: 0 = af_heart (warm female), 1 = af_sky, 2 = am_adam, 3 = am_michael
final class KokoroTTSEngine: NSObject, TTSEngine {

    nonisolated(unsafe) static let shared = KokoroTTSEngine()

    weak var delegate: (any TTSEngineDelegate)?
    private(set) var isSpeaking = false
    private(set) var isPaused  = false

    nonisolated(unsafe) private var ttsPtr:      OpaquePointer?
    nonisolated(unsafe) private var loadTask:    Task<OpaquePointer?, Never>?
    nonisolated(unsafe) private var synthesizer: SynthesisSerializer?

    private var audioPlayer:  AVAudioPlayer?
    private var currentIndex: Int = 0
    private var currentTask:  Task<Void, Never>?

    // Multi-sentence synthesis buffer: several upcoming sentences are synthesized ahead
    // (keyed by sentence index) so playback never waits on synthesis — even when the CPU
    // is busy (e.g. an LLM summary generating). Jobs run serially on the SynthesisSerializer.
    private var synthJobs: [Int: Task<Data?, Never>] = [:]

    var voiceID: Int32 = 0
    var speed:   Float = 1.0

    override init() {
        super.init()
        loadTask = Task.detached(priority: .userInitiated) {
            let ptr = KokoroTTSEngine.createTTS()
            if ptr == nil { log.error("Failed to create TTS — kokoro/ missing from bundle?") }
            else          { log.info("Kokoro TTS engine ready") }
            return ptr
        }
        // Warm up the ONNX graph at launch so the FIRST real sentence isn't slow.
        Task.detached(priority: .utility) { [weak self] in
            guard let self, let synth = await self.ensureSynthesizer() else { return }
            _ = await synth.synthesize(text: "Ready.", voiceID: 0, speed: 1.0)
            log.info("Kokoro warmed up")
        }
    }

    deinit {
        loadTask?.cancel()
        if let ptr = ttsPtr { SherpaOnnxDestroyOfflineTts(ptr) }
    }

    // MARK: - Engine bootstrap

    private func engine() async -> OpaquePointer? {
        if let ptr = ttsPtr { return ptr }
        let ptr = await loadTask?.value
        ttsPtr = ptr
        return ptr
    }

    private func ensureSynthesizer() async -> SynthesisSerializer? {
        if let s = synthesizer { return s }
        guard let ptr = await engine() else { return nil }
        let s = SynthesisSerializer(tts: ptr)
        synthesizer = s
        return s
    }

    // MARK: - TTSEngine

    func speak(sentence: String, at index: Int, rate: Float) {
        currentTask?.cancel()
        currentIndex = index
        isSpeaking   = true
        isPaused     = false
        speed        = 0.7 + rate * 0.8

        // Reuse the already-running/finished synthesis for this sentence if we prefetched it.
        let job = synthJobs[index] ?? makeSynthJob(sentence: sentence, rate: rate)
        synthJobs[index] = nil
        pruneJobs(before: index)   // drop buffers we've moved past

        currentTask = Task { [weak self] in
            guard let self else { return }
            let data = await job.value
            guard !Task.isCancelled, !self.isPaused else { self.isSpeaking = false; return }
            await self.playOrSkip(data: data)
        }
    }

    func prefetch(sentence: String, at index: Int, rate: Float) {
        guard index != currentIndex, synthJobs[index] == nil else { return }
        synthJobs[index] = makeSynthJob(sentence: sentence, rate: rate)
    }

    /// Start synthesizing one sentence on the serializer; returns the audio when done.
    private func makeSynthJob(sentence: String, rate: Float) -> Task<Data?, Never> {
        let capturedSpeed   = 0.7 + rate * 0.8
        let capturedVoiceID = voiceID
        return Task { [weak self] in
            guard let self, let synth = await self.ensureSynthesizer() else { return nil }
            guard !Task.isCancelled else { return nil }
            return await synth.synthesize(text: sentence, voiceID: capturedVoiceID, speed: capturedSpeed)
        }
    }

    private func pruneJobs(before index: Int) {
        for (i, job) in synthJobs where i < index {
            job.cancel(); synthJobs[i] = nil
        }
    }

    /// Drop all buffered upcoming synthesis (the currently-playing sentence is not in the
    /// buffer, so it keeps playing). Used after a speed change so the next sentences are
    /// re-synthesized at the new rate.
    func flushPrefetch() {
        for (_, job) in synthJobs { job.cancel() }
        synthJobs.removeAll()
    }

    func pause()  { audioPlayer?.pause(); isSpeaking = false; isPaused = true  }
    func resume() { audioPlayer?.play();  isSpeaking = true;  isPaused = false }

    func stop() {
        currentTask?.cancel()
        for (_, job) in synthJobs { job.cancel() }
        synthJobs.removeAll()
        audioPlayer?.stop()
        audioPlayer = nil
        isSpeaking  = false
        isPaused    = false
    }

    @MainActor
    private func playOrSkip(data: Data?) async {
        // Synthesis can outlive a pause() call — bail out so we don't auto-restart.
        guard !isPaused else { isSpeaking = false; return }
        guard let data else {
            log.warning("Skipping sentence \(self.currentIndex) — no audio")
            isSpeaking = false
            delegate?.engine(self, didFinishSentenceAt: currentIndex)
            return
        }
        do {
            // Re-activate the audio session each time we start a new player.
            // The system uses this moment to register us as the Now Playing app.
            try? AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
            player.delegate = self
            player.prepareToPlay()
            audioPlayer = player
            player.play()
            // Notify delegate so NowPlayingInfoCenter is updated when audio actually starts,
            // not speculatively when the user taps Play (before synthesis finishes).
            delegate?.engineDidBeginPlaying(self)
        } catch {
            isSpeaking = false
            delegate?.engine(self, didFailWithError: error)
        }
    }

    // MARK: - Engine creation

    private static func createTTS() -> OpaquePointer? {
        guard let bundleURL = Bundle.main.url(forResource: "kokoro", withExtension: nil) else {
            return nil
        }

        let modelNS    = bundleURL.appendingPathComponent("model.onnx").path     as NSString
        let voicesNS   = bundleURL.appendingPathComponent("voices.bin").path     as NSString
        let tokensNS   = bundleURL.appendingPathComponent("tokens.txt").path     as NSString
        let dataDirNS  = bundleURL.appendingPathComponent("espeak-ng-data").path as NSString
        let emptyNS    = "" as NSString
        let cpuNS      = "cpu" as NSString

        var kokoro = SherpaOnnxOfflineTtsKokoroModelConfig()
        kokoro.model        = modelNS.utf8String
        kokoro.voices       = voicesNS.utf8String
        kokoro.tokens       = tokensNS.utf8String
        kokoro.data_dir     = dataDirNS.utf8String
        kokoro.length_scale = 1.0
        kokoro.dict_dir     = emptyNS.utf8String
        kokoro.lexicon      = emptyNS.utf8String
        kokoro.lang         = emptyNS.utf8String

        var modelCfg = SherpaOnnxOfflineTtsModelConfig()
        modelCfg.kokoro      = kokoro
        modelCfg.num_threads = 4   // iPhone 15 Pro+ has cores to spare; faster synthesis
        modelCfg.debug       = 0
        modelCfg.provider    = cpuNS.utf8String

        var cfg = SherpaOnnxOfflineTtsConfig()
        cfg.model             = modelCfg
        cfg.rule_fsts         = emptyNS.utf8String
        cfg.max_num_sentences = 1

        return SherpaOnnxCreateOfflineTts(&cfg)
    }

    // MARK: - WAV encoding

    fileprivate static func pcmToWAV(samples: [Float], sampleRate: Int) -> Data {
        let numChannels:   UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate    = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign  = numChannels * (bitsPerSample / 8)
        let dataSize    = UInt32(samples.count * 2)

        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))

        func write<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: "RIFF".utf8); write(UInt32(36 + dataSize))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8); write(UInt32(16))
        write(UInt16(1)); write(numChannels); write(UInt32(sampleRate))
        write(byteRate);  write(blockAlign);  write(bitsPerSample)
        data.append(contentsOf: "data".utf8); write(dataSize)

        for sample in samples {
            write(Int16(max(-1.0, min(1.0, sample)) * 32767.0))
        }
        return data
    }
}

// MARK: - AVAudioPlayerDelegate

extension KokoroTTSEngine: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        isSpeaking = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            delegate?.engine(self, didFinishSentenceAt: currentIndex)
        }
    }
}

// MARK: - Errors

enum KokoroError: LocalizedError {
    case modelNotLoaded
    var errorDescription: String? {
        "Kokoro model not loaded — ensure the kokoro/ folder is in the app bundle."
    }
}
