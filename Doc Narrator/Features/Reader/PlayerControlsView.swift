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
        VStack(spacing: 20) {
            // Progress scrubber, with matching current / total captions beneath each end.
            VStack(spacing: 4) {
                Slider(value: $scrubValue, in: 0...1) { editing in
                    scrubbing = editing
                    if !editing { vm.seek(toFraction: scrubValue) }
                }
                .disabled(vm.totalSentences == 0)
                HStack {
                    Text("\(currentScrubSentence)")
                    Spacer()
                    Text("\(vm.totalSentences)")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .opacity(vm.totalSentences > 0 ? 1 : 0)
            }
            .onAppear { scrubValue = vm.progress }
            .onChange(of: vm.progress) { _, new in if !scrubbing { scrubValue = new } }

            // Speed, with a centered caption beneath (same pattern as the scrubber).
            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                    Slider(value: $vm.settings.rate, in: 0...1, step: 0.05)
                    Image(systemName: "hare.fill").foregroundStyle(.secondary)
                }
                Text("Speed \(speedLabel)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Transport — four equal, evenly distributed slots for a symmetric row.
            HStack(spacing: 0) {
                transportButton("arrow.counterclockwise", size: 22) { vm.restartFromBeginning() }
                transportButton("backward.end.fill", size: 24) { vm.skipToPreviousSection() }
                playPauseButton
                transportButton("forward.end.fill", size: 24) { vm.skipToNextSection() }
            }

            // Engine picker
            Picker("Engine", selection: $vm.settings.engineType) {
                ForEach(TTSEngineType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal)
        .padding(.vertical)
        .background(.ultraThinMaterial)
        .onChange(of: vm.settings.engineType) { _, _ in vm.settings.save() }
        .onChange(of: vm.settings.rate) { _, _ in vm.settings.save() }
    }

    private func transportButton(_ systemName: String, size: CGFloat,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
        }
        .disabled(!vm.state.isInteractable)
    }

    private var playPauseButton: some View {
        Button {
            vm.state == .playing ? vm.pause() : vm.play()
        } label: {
            Group {
                if vm.isBuffering && vm.state == .playing {
                    ProgressView().controlSize(.large)
                } else {
                    Image(systemName: vm.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.blue)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
        }
        .disabled(!vm.state.isInteractable)
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
