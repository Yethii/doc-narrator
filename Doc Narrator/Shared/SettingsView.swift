import SwiftUI
import AVFoundation

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = KeychainHelper.load(key: "openai_api_key") ?? ""
    @State private var settings = TTSSettings.load()
    @State private var voices: [AVSpeechSynthesisVoice] = []

    var body: some View {
        NavigationStack {
            List {
                Section("On-Device Voice") {
                    Picker("Voice", selection: $settings.systemVoiceIdentifier) {
                        Text("Best Available").tag("")
                        ForEach(voices, id: \.identifier) { voice in
                            Text("\(voice.name) (\(qualityLabel(voice.quality)))")
                                .tag(voice.identifier)
                        }
                    }
                }

                Section {
                    SecureField("API Key", text: $apiKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Picker("Voice", selection: $settings.openAIVoice) {
                        ForEach(OpenAIVoice.allCases, id: \.self) { voice in
                            Text(voice.rawValue.capitalized).tag(voice)
                        }
                    }
                } header: {
                    Text("OpenAI TTS")
                } footer: {
                    Text("Required for cloud engine. Key stored securely in Keychain.")
                }

                Section("About") {
                    LabeledContent("App", value: "Doc Narrator")
                    LabeledContent("Engine", value: "AVSpeechSynthesizer + OpenAI tts-1-hd")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save(); dismiss() }
                }
            }
            .onAppear { loadVoices() }
        }
    }

    private func save() {
        settings.save()
        if apiKey.isEmpty {
            KeychainHelper.delete(key: "openai_api_key")
        } else {
            KeychainHelper.save(key: "openai_api_key", value: apiKey)
        }
    }

    private func loadVoices() {
        voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .filter { ($0.voiceTraits.rawValue & AVSpeechSynthesisVoice.Traits.isNoveltyVoice.rawValue) == 0 }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }

    private func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium:  return "Premium"
        case .enhanced: return "Enhanced"
        default:        return "Default"
        }
    }
}
