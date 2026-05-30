import Foundation

enum TTSEngineType: String, Codable, CaseIterable {
    case system = "On-Device"
    case openAI = "OpenAI (Cloud)"
}

enum OpenAIVoice: String, Codable, CaseIterable {
    case alloy, echo, fable, onyx, nova, shimmer
}

struct TTSSettings: Codable {
    var engineType: TTSEngineType = .system
    /// AVSpeechSynthesisVoice.identifier; empty = best available en-US
    var systemVoiceIdentifier: String = ""
    /// 0.0–1.0; mapped to AVSpeechUtteranceMinimumSpeechRate...Maximum
    var rate: Float = 0.5
    var openAIVoice: OpenAIVoice = .onyx
    var openAIModel: String = "tts-1-hd"

    static let defaultsKey = "ttsSettings"

    static func load() -> TTSSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(TTSSettings.self, from: data)
        else { return TTSSettings() }
        return s
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: TTSSettings.defaultsKey)
    }
}
