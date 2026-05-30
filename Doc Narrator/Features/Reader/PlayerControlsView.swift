import SwiftUI

struct PlayerControlsView: View {
    @ObservedObject var vm: ReaderViewModel

    var body: some View {
        VStack(spacing: 16) {
            // Speed control
            HStack(spacing: 8) {
                Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                Slider(value: $vm.settings.rate, in: 0...1, step: 0.05)
                Image(systemName: "hare.fill").foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            // Transport controls
            HStack(spacing: 44) {
                Button { vm.skipToPreviousSection() } label: {
                    Image(systemName: "backward.end.fill").font(.title2)
                }
                .disabled(!vm.state.isInteractable)

                Button {
                    vm.state == .playing ? vm.pause() : vm.play()
                } label: {
                    Image(systemName: vm.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.blue)
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
