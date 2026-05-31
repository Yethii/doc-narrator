import MediaPlayer

@MainActor
final class NowPlayingManager {
    static let shared = NowPlayingManager()
    private var commandTargets: [Any] = []

    private init() {}

    func setup(onPlay: @escaping () -> Void,
               onPause: @escaping () -> Void,
               onNext: @escaping () -> Void,
               onPrevious: @escaping () -> Void) {
        let cc = MPRemoteCommandCenter.shared()
        commandTargets.removeAll()
        commandTargets.append(cc.playCommand.addTarget { _ in onPlay(); return .success })
        commandTargets.append(cc.pauseCommand.addTarget { _ in onPause(); return .success })
        commandTargets.append(cc.togglePlayPauseCommand.addTarget { _ in
            // called by headphone single-tap and lock screen tap
            onPlay(); return .success
        })
        commandTargets.append(cc.nextTrackCommand.addTarget { _ in onNext(); return .success })
        commandTargets.append(cc.previousTrackCommand.addTarget { _ in onPrevious(); return .success })
        cc.playCommand.isEnabled = true
        cc.pauseCommand.isEnabled = true
        cc.nextTrackCommand.isEnabled = true
        cc.previousTrackCommand.isEnabled = true
    }

    func update(title: String, author: String, isPlaying: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: author,
            MPMediaItemPropertyMediaType: MPMediaType.podcast.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}
