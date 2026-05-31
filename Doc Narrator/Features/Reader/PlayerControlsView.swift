import SwiftUI

struct PlayerControlsView: View {
    @ObservedObject var vm: ReaderViewModel
    @State private var scrubValue: Double = 0
    @State private var scrubbing = false

    // Display the rate (0...1) as a speech-speed multiplier (0.5×–1.5×, 1× = normal).
    private var speedLabel: String {
        String(format: "%g×", 0.5 + Double(vm.settings.rate))
    }

    // 1-based sentence number for the current scrubber position.
    private var currentScrubSentence: Int {
        let total = vm.totalSentences
        guard total > 0 else { return 0 }
        return min(total, Int((scrubValue * Double(max(total - 1, 1))).rounded()) + 1)
    }

    var body: some View {
        VStack(spacing: 16) {
            // Progress scrubber — drag to skip to any point and start reading there.
            VStack(spacing: 2) {
                Slider(value: $scrubValue, in: 0...1) { editing in
                    scrubbing = editing
                    if !editing { vm.seek(toFraction: scrubValue) }
                }
                .disabled(vm.totalSentences == 0)
                // Sentence number tracking the slider thumb's position.
                GeometryReader { geo in
                    let inset: CGFloat = 12
                    let usable = max(geo.size.width - inset * 2, 1)
                    let x = inset + CGFloat(scrubValue) * usable
                    Text("\(currentScrubSentence) / \(vm.totalSentences)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: min(max(x, 26), geo.size.width - 26), y: 7)
                }
                .frame(height: 16)
                .opacity(vm.totalSentences > 0 ? 1 : 0)
            }
            .padding(.horizontal)
            .onAppear { scrubValue = vm.progress }
            .onChange(of: vm.progress) { _, new in if !scrubbing { scrubValue = new } }

            // Speed control
            HStack(spacing: 8) {
                Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                Slider(value: $vm.settings.rate, in: 0...1, step: 0.05)
                Image(systemName: "hare.fill").foregroundStyle(.secondary)
                Text(speedLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            .padding(.horizontal)

            // Transport controls
            HStack(spacing: 36) {
                Button { vm.restartFromBeginning() } label: {
                    Image(systemName: "arrow.counterclockwise").font(.title2)
                }
                .disabled(!vm.state.isInteractable)

                Button { vm.skipToPreviousSection() } label: {
                    Image(systemName: "backward.end.fill").font(.title2)
                }
                .disabled(!vm.state.isInteractable)

                Button {
                    vm.state == .playing ? vm.pause() : vm.play()
                } label: {
                    if vm.isBuffering && vm.state == .playing {
                        // Synthesizing — show a spinner until audio actually starts.
                        ProgressView()
                            .controlSize(.large)
                            .frame(width: 60, height: 60)
                    } else {
                        Image(systemName: vm.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.blue)
                    }
                }
                .disabled(!vm.state.isInteractable)

                Button { vm.skipToNextSection() } label: {
                    Image(systemName: "forward.end.fill").font(.title2)
                }
                .disabled(!vm.state.isInteractable)
            }

            // Engine picker
            Picker("Engine", selection: $vm.settings.engineType) {
                ForEach(TTSEngineType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
        }
        .padding(.vertical)
        .background(.ultraThinMaterial)
        .onChange(of: vm.settings.engineType) { _, _ in vm.settings.save() }
        .onChange(of: vm.settings.rate) { _, _ in vm.settings.save() }
    }
}

private extension ReaderState {
    var isInteractable: Bool {
        switch self {
        case .ready, .playing, .paused: return true
        default: return false
        }
    }
}
