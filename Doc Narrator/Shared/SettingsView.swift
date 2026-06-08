import SwiftUI
import AVFoundation

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = KeychainHelper.load(key: "openai_api_key") ?? ""
    @State private var settings = TTSSettings.load()
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @ObservedObject private var llm = LLMService.shared
    @ObservedObject private var gemma = LiteRTManager.shared

    @ViewBuilder private var gemmaModelRow: some View {
        if gemma.isDownloaded {
            HStack {
                Label("\(gemma.modelName) installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Delete", role: .destructive) { gemma.deleteModel() }
                    .buttonStyle(.borderless)
            }
            Picker("Compute", selection: $gemma.preferredBackend) {
                Text("GPU").tag("gpu")
                Text("CPU").tag("cpu")
            }
            .pickerStyle(.segmented)
        } else if gemma.isDownloading {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: gemma.progress) {
                    Text("Downloading \(gemma.modelName)…").font(.caption)
                }
                Button("Cancel", role: .cancel) { gemma.cancelDownload() }
                    .buttonStyle(.borderless)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button { gemma.startDownload() } label: {
                    Label("Download \(gemma.modelName) (\(gemma.approxSizeText))", systemImage: "arrow.down.circle")
                }
                if let err = gemma.downloadError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                Text("Downloads once over Wi-Fi and runs fully on device. Larger and slower to start than the Apple model, but more reliable.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Engine", selection: $llm.settings.providerType) {
                        ForEach(LLMProviderType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(llm.isReady ? Color.green : Color.secondary)
                                .frame(width: 8, height: 8)
                            Text(llm.statusText).foregroundStyle(.secondary)
                        }
                    }
                    if llm.settings.providerType == .mlxLocal {
                        gemmaModelRow
                    }
                    if llm.settings.providerType != .off {
                        Picker("Narration", selection: $llm.settings.narrationMode) {
                            ForEach(NarrationMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        NavigationLink {
                            PromptSettingsView()
                        } label: {
                            Label("AI Prompts", systemImage: "text.quote")
                        }
                        NavigationLink {
                            NarrationSettingsView()
                        } label: {
                            Label("Narration", systemImage: "speaker.wave.2")
                        }
                    }
                    if llm.settings.providerType == .appleFoundation {
                        Label("Apple Intelligence works well for summaries but can be unreliable in Chat with PDF, where it sometimes ignores the document. For chat, Gemma (on-device) is more accurate.",
                              systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Intelligence")
                } footer: {
                    Text("On-device language model for summaries, questions, and explanations. With the Apple built-in model, nothing leaves your device. Narration mode controls how text is prepared for reading (Cleaned/Condensed apply once enabled).")
                }

                Section {
                    Picker("Voice", selection: $settings.systemVoiceIdentifier) {
                        Text("Best Available").tag("")
                        ForEach(voices, id: \.identifier) { voice in
                            Text(voiceLabel(voice)).tag(voice.identifier)
                        }
                    }
                } header: {
                    Text("On-Device Voice")
                } footer: {
                    Text("Applies to the System Voice engine. “Enhanced”/“Premium” are higher-quality voices you can download in iOS Settings ▸ Accessibility ▸ Spoken Content ▸ Voices.")
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
            .onAppear { loadVoices(); Task { await llm.refreshStatus() } }
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

    // Show the quality suffix only when it's an upgraded voice; plain Default
    // voices ("Junior (Default)") just looked noisy and confusing.
    private func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        let region = Locale.current.localizedString(forRegionCode: String(voice.language.suffix(2)))
        let base = region.map { "\(voice.name) · \($0)" } ?? voice.name
        switch voice.quality {
        case .premium:  return "\(base) · Premium"
        case .enhanced: return "\(base) · Enhanced"
        default:        return base
        }
    }
}
