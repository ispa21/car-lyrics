import LyricsCore
@preconcurrency import MediaPlayer

/// The Music app's player, read on the phone: no login, no network, no developer account.
/// MediaPlayer only exposes Apple's own player; other apps' playback stays invisible.
@MainActor
enum AppleMusic {
    static func authorize() async -> Bool {
        if MPMediaLibrary.authorizationStatus() == .authorized { return true }
        return await MPMediaLibrary.requestAuthorization() == .authorized
    }

    /// The playing song's album art from the phone's library, small, for the blurred card backdrop.
    static func artwork() -> CGImage? {
        MPMusicPlayerController.systemMusicPlayer.nowPlayingItem?.artwork?.image(at: CGSize(width: 48, height: 48))?.cgImage
    }

    /// The ID a library song's lyrics are saved under; the same as nowPlaying() uses, so they're found while playing.
    static func id(of item: MPMediaItem) -> String {
        "am:" + (item.playbackStoreID.isEmpty ? String(item.persistentID) : item.playbackStoreID)
    }

    /// Every song in the user's library, for saving lyrics ahead of time.
    static func librarySongs() -> [NowPlaying] {
        (MPMediaQuery.songs().items ?? []).compactMap { item in
            guard let title = item.title, item.playbackDuration > 0 else { return nil }
            let durationMs = Int(item.playbackDuration * 1000)
            return NowPlaying(trackID: id(of: item), title: title, artists: item.artist.map { [$0] } ?? [], album: item.albumTitle ?? "",
                              durationMs: durationMs,
                              playback: PlaybackSnapshot(progressMs: 0, sampledAt: .distantPast, isPlaying: false, durationMs: durationMs))
        }
    }

    /// The previous reading, to tell whether the position is moving.
    private static var last: (id: String, positionMs: Int, at: Date)?

    /// Returns nil when the Music app has nothing loaded.
    static func nowPlaying() -> NowPlaying? {
        let player = MPMusicPlayerController.systemMusicPlayer
        guard let item = player.nowPlayingItem, let title = item.title else { return nil }
        let durationMs = Int(item.playbackDuration * 1000)
        let id = id(of: item)
        let positionMs = Int(player.currentPlaybackTime * 1000)
        // The Music app's "playing" flag has long been reported to go stale, saying paused while music plays.
        // So a position moving at least half as fast as the clock also counts as playing. A flag that wrongly
        // says playing does little harm: the position is read again every half second.
        var playing = player.playbackState == .playing
        if let last, last.id == id, Date.now.timeIntervalSince(last.at) >= 0.3 {
            playing = playing || Double(positionMs - last.positionMs) >= Date.now.timeIntervalSince(last.at) * 500
        }
        if last?.id != id || Date.now.timeIntervalSince(last?.at ?? .distantPast) >= 0.3 { last = (id, positionMs, .now) }
        return NowPlaying(
            trackID: id,
            title: title,
            artists: item.artist.map { [$0] } ?? [],
            album: item.albumTitle ?? "",
            durationMs: durationMs,
            playback: PlaybackSnapshot(progressMs: positionMs, sampledAt: .now, isPlaying: playing, durationMs: durationMs))
    }
}
