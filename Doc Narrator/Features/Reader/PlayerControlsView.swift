import SwiftUI

struct PlayerControlsView: View {
    @ObservedObject var vm: ReaderViewModel
    @ObservedObject private var generator = SummaryGenerator.shared
    @State private var scrubValue: Double = 0
    @State private var scrubbing = false
    @State private var bannerFlash = false
    @State private var flashTask: Task<Void, Never>?

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
            // While a summary generates on-device it competes with TTS for the chip, so
            // narration is paused until it's done. Tapping play flashes this notice.
            if generator.isGenerating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Generating summary — narration will resume when it's ready.")
                        .font(.caption2)
                        .foregroundStyle(bannerFlash ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(bannerFlash ? Color.orange.opacity(0.18) : Color.clear)
                )
                .animation(.easeInOut(duration: 0.2), value: bannerFlash)
            }

            // Progress scrubber, with a centered "current / total" sentence count beneath.
            VStack(spacing: 4) {
                Slider(value: $scrubValue, in: 0...1) { editing in
                    scrubbing = editing
                    if !editing { vm.seek(toFraction: scrubValue) }
                }
                .disabled(vm.totalSentences == 0)
                Text("\(currentScrubSentence) / \(vm.totalSentences)")
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

            // Transport — prev / play-pause / next, centered and symmetric.
            HStack(spacing: 56) {
                transportButton("backward.end.fill", size: 26) { vm.skipToPreviousSection() }
                playPauseButton
                transportButton("forward.end.fill", size: 26) { vm.skipToNextSection() }
            }
            .frame(maxWidth: .infinity)

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
                .frame(width: 56, height: 56)
        }
        .disabled(!vm.state.isInteractable)
    }

    // Flash the "generating" notice; auto-clears 5s after the LAST tap (debounced).
    private func flashBanner() {
        bannerFlash = true
        flashTask?.cancel()
        flashTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { bannerFlash = false }
        }
    }

    private var playPauseButton: some View {
        Button {
            // Don't start narration while a summary generates — it would re-introduce the
            // contention. Flash the notice instead.
            if generator.isGenerating { flashBanner(); return }
            vm.state == .playing ? vm.pause() : vm.play()
        } label: {
            Group {
                if vm.isBuffering && vm.state == .playing {
                    ProgressView().controlSize(.large)
                } else {
                    Image(systemName: vm.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.blue)
                }
            }
            .frame(width: 56, height: 56)
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
