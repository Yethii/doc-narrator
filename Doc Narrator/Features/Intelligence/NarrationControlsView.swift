import SwiftUI

/// Compact playback controls for AI-text narration: play/pause on the bar; speed and
/// voice engine tucked into an overflow menu.
struct NarrationControlsView: View {
    @ObservedObject var narrator: SentenceNarrator

    var body: some View {
        HStack(spacing: 20) {
            Button { narrator.toggle() } label: {
                if narrator.isPlaying && narrator.isBuffering {
                    ProgressView().controlSize(.large).frame(width: 44, height: 44)
                } else {
                    Image(systemName: narrator.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.blue)
                }
            }

            if !narrator.sentences.isEmpty {
                Text(progressLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                Picker("Speed", selection: speedBinding) {
                    Text("0.75×").tag(0.25)
                    Text("1×").tag(0.5)
                    Text("1.25×").tag(0.75)
                    Text("1.5×").tag(1.0)
                }
                Picker("Voice", selection: $narrator.settings.engineType) {
                    ForEach(TTSEngineType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Image(systemName: "slider.horizontal.3").font(.title3)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var progressLabel: String {
        let n = max(narrator.currentIndex + 1, 1)
        return "\(min(n, narrator.sentences.count)) / \(narrator.sentences.count)"
    }

    private var speedBinding: Binding<Double> {
        Binding(get: { Double(narrator.settings.rate) },
                set: { narrator.settings.rate = Float($0) })
    }
}
