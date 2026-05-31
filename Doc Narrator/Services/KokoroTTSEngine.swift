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
        text.withCString { cText -> Data? in
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

    // Prefetch pipeline: while sentence N plays, synthesize N+1 in the background.
    // prefetchTask returns Data? directly — no shared cache, no race with removeAll().
    private var prefetchedIndex: Int = -1
    private var prefetchTask: Task<Data?, Never>?

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

        if index == prefetchedIndex, let job = prefetchTask {
            // Prefetch task is running (or done) for this exact sentence index.
            // Await its return value directly — no shared cache involved.
            let capturedJob = job
            prefetchTask    = nil
            prefetchedIndex = -1
            currentTask = Task { [weak self] in
                guard let self else { return }
                let data = await capturedJob.value   // wait for synthesis → returns Data?
                guard !Task.isCancelled, !self.isPaused else { self.isSpeaking = false; return }
                await self.playOrSkip(data: data)
            }
        } else {
            // Prefetch miss — synthesize fresh. Cancel stale prefetch first.
            prefetchTask?.cancel()
            prefetchTask    = nil
            prefetchedIndex = -1
            currentTask = Task { [weak self] in await self?.synthesizeAndPlay(sentence) }
        }
    }

    func prefetch(sentence: String, at index: Int, rate: Float) {
        guard index != prefetchedIndex else { return }
        prefetchTask?.cancel()
        prefetchedIndex     = index
        let capturedSpeed   = 0.7 + rate * 0.8
        let capturedVoiceID = voiceID
        // Task<Data?, Never>: returns synthesized WAV directly so speak() can await it
        // without any intervening shared state that could be wiped by a racing call.
        let prefetchJob: Task<Data?, Never> = Task { [weak self] in
            guard let self, let synth = await self.ensureSynthesizer() else { return nil }
            guard !Task.isCancelled else { return nil }
            // SynthesisSerializer actor serializes this with the current synthesis —
            // S(n+1) only starts after S(n) finishes, then overlaps with S(n) playback.
            return await synth.synthesize(text: sentence, voiceID: capturedVoiceID, speed: capturedSpeed)
        }
        prefetchTask = prefetchJob
    }

    func pause()  { audioPlayer?.pause(); isSpeaking = false; isPaused = true  }
    func resume() { audioPlayer?.play();  isSpeaking = true;  isPaused = false }

    func stop() {
        currentTask?.cancel()
        prefetchTask?.cancel()
        prefetchTask    = nil
        prefetchedIndex = -1
        audioPlayer?.stop()
        audioPlayer = nil
        isSpeaking  = false
        isPaused    = false
    }

    // MARK: - Synthesis

    @MainActor
    private func synthesizeAndPlay(_ text: String) async {
        guard let synth = await ensureSynthesizer() else {
            delegate?.engine(self, didFailWithError: KokoroError.modelNotLoaded)
            return
        }
        guard !Task.isCancelled else { return }
        let data = await synth.synthesize(text: text, voiceID: voiceID, speed: speed)
        guard !Task.isCancelled, !isPaused else { isSpeaking = false; return }
        await playOrSkip(data: data)
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
            let player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
            player.delegate = self
            player.prepareToPlay()
            audioPlayer = player
            player.play()
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
        modelCfg.num_threads = 2
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
