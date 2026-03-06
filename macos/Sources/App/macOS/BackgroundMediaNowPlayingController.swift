import Foundation
import MediaPlayer
import GhosttyKit

final class BackgroundMediaNowPlayingController {
    private let surfaceProvider: () -> ghostty_surface_t?
    private var refreshTimer: Timer?

    init(surfaceProvider: @escaping () -> ghostty_surface_t?) {
        self.surfaceProvider = surfaceProvider
        configureRemoteCommands()
        startRefreshTimer()
        refreshNowPlayingState()
    }

    deinit {
        refreshTimer?.invalidate()
        clearNowPlaying()
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: true,
            block: { [weak self] _ in self?.refreshNowPlayingState() }
        )
        refreshTimer?.tolerance = 0.25
        if let timer = refreshTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true

        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.withSurface { surface in
                ghostty_surface_set_background_video_paused(surface, false)
            }
        }

        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.withSurface { surface in
                ghostty_surface_set_background_video_paused(surface, true)
            }
        }

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.withSurface { surface in
                let paused = ghostty_surface_is_background_video_paused(surface)
                return ghostty_surface_set_background_video_paused(surface, !paused)
            }
        }

        center.skipForwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.withSurface { surface in
                ghostty_surface_seek_background_video(surface, 10)
            }
        }

        center.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.withSurface { surface in
                ghostty_surface_seek_background_video(surface, -10)
            }
        }

        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.withSurface { surface in
                ghostty_surface_next_background_media_track(surface)
            }
        }

        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.withSurface { surface in
                ghostty_surface_previous_background_media_track(surface)
            }
        }
    }

    private func withSurface(_ body: (ghostty_surface_t) -> Bool) -> MPRemoteCommandHandlerStatus {
        guard let surface = surfaceProvider() else {
            refreshNowPlayingState()
            return .noSuchContent
        }

        guard ghostty_surface_has_background_video(surface) else {
            refreshNowPlayingState()
            return .noSuchContent
        }

        let ok = body(surface)
        refreshNowPlayingState()
        return ok ? .success : .commandFailed
    }

    private func refreshNowPlayingState() {
        guard let surface = surfaceProvider(), ghostty_surface_has_background_video(surface) else {
            clearNowPlaying()
            return
        }

        let paused = ghostty_surface_is_background_video_paused(surface)
        let seekSupported = ghostty_surface_is_background_video_seek_supported(surface)
        let queueCount = Int(ghostty_surface_background_media_queue_count(surface))
        let queueIndex = Int(ghostty_surface_background_media_queue_index(surface))
        let title = string(from: ghostty_surface_background_media_title(surface))
        let artist = string(from: ghostty_surface_background_media_artist(surface))
        let url = string(from: ghostty_surface_background_media_url(surface))

        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = title.isEmpty ? fallbackTitle(from: url) : title
        if artist.isEmpty {
            info[MPMediaItemPropertyArtist] = "Ghostty"
        } else {
            info[MPMediaItemPropertyArtist] = artist
        }
        if queueCount > 1, queueIndex >= 0 {
            info[MPMediaItemPropertyAlbumTitle] = "Queue \(queueIndex + 1)/\(queueCount)"
        } else {
            info.removeValue(forKey: MPMediaItemPropertyAlbumTitle)
        }
        info[MPNowPlayingInfoPropertyIsLiveStream] = !seekSupported
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = paused ? .paused : .playing

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = paused
        center.pauseCommand.isEnabled = !paused
        center.togglePlayPauseCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = seekSupported
        center.skipBackwardCommand.isEnabled = seekSupported
        center.nextTrackCommand.isEnabled = queueCount > 1
        center.previousTrackCommand.isEnabled = queueCount > 1
    }

    private func string(from value: ghostty_string_s) -> String {
        defer { ghostty_string_free(value) }
        guard let ptr = value.ptr else { return "" }
        let data = Data(bytes: ptr, count: Int(value.len))
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func fallbackTitle(from url: String) -> String {
        guard !url.isEmpty else { return "Ghostty Background Media" }
        guard let parsed = URL(string: url) else { return "Ghostty Background Media" }
        let candidate = parsed.lastPathComponent
        return candidate.isEmpty ? "Ghostty Background Media" : candidate
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }
}
