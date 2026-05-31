import MediaPlayer

/// Manages the Now Playing widget and remote command handling (Control Center,
/// lock screen, headphones, CarPlay). Callbacks are always dispatched to the
/// main queue before calling into @MainActor ReaderViewModel code.
final class NowPlayingManager {
    static let shared = NowPlayingManager()
    // Retain target objects — MPRemoteCommandCenter uses weak refs internally.
    private var commandTargets: [Any] = []

    private init() {}

    func setup(onPlay: @escaping () -> Void,
               onPause: @escaping () -> Void,
               onToggle: @escaping () -> Void,
               onNext: @escaping () -> Void,
               onPrevious: @escaping () -> Void) {
        let cc = MPRemoteCommandCenter.shared()
        // Remove previous targets before re-registering (e.g. new paper opened).
        for target in commandTargets {
            cc.playCommand.removeTarget(target)
            cc.pauseCommand.removeTarget(target)
            cc.togglePlayPauseCommand.removeTarget(target)
            cc.nextTrackCommand.removeTarget(target)
            cc.previousTrackCommand.removeTarget(target)
        }
        commandTargets.removeAll()

        // All MPRemoteCommandCenter handlers are called on a private background
        // thread. Dispatch to main before touching any @MainActor state.
        commandTargets.append(cc.playCommand.addTarget { _ in
            DispatchQueue.main.async { onPlay() }; return .success
        })
        commandTargets.append(cc.pauseCommand.addTarget { _ in
            DispatchQueue.main.async { onPause() }; return .success
        })
        commandTargets.append(cc.togglePlayPauseCommand.addTarget { _ in
            DispatchQueue.main.async { onToggle() }; return .success
        })
        commandTargets.append(cc.nextTrackCommand.addTarget { _ in
            DispatchQueue.main.async { onNext() }; return .success
        })
        commandTargets.append(cc.previousTrackCommand.addTarget { _ in
            DispatchQueue.main.async { onPrevious() }; return .success
        })

        cc.playCommand.isEnabled         = true
        cc.pauseCommand.isEnabled        = true
        cc.togglePlayPauseCommand.isEnabled = true
        cc.nextTrackCommand.isEnabled    = true
        cc.previousTrackCommand.isEnabled = true
    }

    func update(title: String, author: String, isPlaying: Bool) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle:               title,
            MPMediaItemPropertyArtist:              author,
            MPMediaItemPropertyMediaType:           MPMediaType.podcast.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate:   isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType:      MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState  = .stopped
    }
}
