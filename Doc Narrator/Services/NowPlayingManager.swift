import MediaPlayer
import AVFoundation

/// Single point of truth for Now Playing / Control Center integration.
/// Initialized at app launch so MPRemoteCommandCenter handlers are always registered.
/// ReaderViewModel registers itself as the active reader when it opens a paper.
@MainActor
final class PlaybackCoordinator {
    static let shared = PlaybackCoordinator()

    weak var activeReader: ReaderViewModel?

    private init() {
        registerRemoteCommands()
    }

    // MARK: - Remote commands (registered once at app launch)

    private func registerRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.isEnabled  = true
        cc.pauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.isEnabled = true
        cc.nextTrackCommand.isEnabled     = true
        cc.previousTrackCommand.isEnabled = true

        cc.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.activeReader?.play() }
            return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.activeReader?.pause() }
            return .success
        }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                guard let r = self?.activeReader else { return }
                r.state == .playing ? r.pause() : r.play()
            }
            return .success
        }
        cc.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.activeReader?.skipToNextSection() }
            return .success
        }
        cc.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.activeReader?.skipToPreviousSection() }
            return .success
        }
    }

    // MARK: - Now Playing info

    func updateNowPlaying(title: String, author: String, isPlaying: Bool) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle:              title,
            MPMediaItemPropertyArtist:             author,
            MPNowPlayingInfoPropertyPlaybackRate:  isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType:     MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState  = .stopped
    }
}
