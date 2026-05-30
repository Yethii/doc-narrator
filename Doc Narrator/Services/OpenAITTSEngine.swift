import AVFoundation

enum OpenAITTSError: LocalizedError {
    case missingAPIKey, httpError(Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "OpenAI API key not set. Go to Settings."
        case .httpError(let code): return "OpenAI API error: HTTP \(code)"
        }
    }
}

final class OpenAITTSEngine: NSObject, TTSEngine, AVAudioPlayerDelegate {
    weak var delegate: (any TTSEngineDelegate)?
    private(set) var isSpeaking = false
    private(set) var isPaused = false

    var apiKey: String = ""
    var voice: String = "onyx"
    var model: String = "tts-1-hd"

    private var audioPlayer: AVAudioPlayer?
    private var currentIndex = 0
    private var currentTask: Task<Void, Never>?

    func speak(sentence: String, at index: Int, rate: Float) {
        currentIndex = index; isSpeaking = true; isPaused = false
        currentTask = Task { [weak self] in await self?.fetchAndPlay(sentence: sentence, rate: rate) }
    }

    func pause() { audioPlayer?.pause(); isSpeaking = false; isPaused = true }
    func resume() { audioPlayer?.play(); isSpeaking = true; isPaused = false }

    func stop() {
        currentTask?.cancel()
        audioPlayer?.stop(); audioPlayer = nil
        isSpeaking = false; isPaused = false
    }

    @MainActor
    private func fetchAndPlay(sentence: String, rate: Float) async {
        guard !apiKey.isEmpty else {
            delegate?.engine(self, didFailWithError: OpenAITTSError.missingAPIKey); return
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "input": sentence,
            "voice": voice,
            "speed": Double(0.75 + rate * 0.75)  // maps 0–1 to 0.75x–1.5x
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw OpenAITTSError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            let player = try AVAudioPlayer(data: data, fileTypeHint: "mp3")
            player.delegate = self; player.prepareToPlay()
            audioPlayer = player; player.play()
        } catch {
            isSpeaking = false
            delegate?.engine(self, didFailWithError: error)
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        isSpeaking = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            delegate?.engine(self, didFinishSentenceAt: currentIndex)
        }
    }
}
