@preconcurrency import ActivityKit
import AVFAudio
import Foundation
import LyricsCore
import Observation
import UIKit
import WidgetKit
import os

enum PlaybackSourceKind: String { case spotify, appleMusic, demo }

/// Something about the session the user should know, shown on Home with a way to fix it. Each one is also logged.
enum SessionIssue: Equatable {
    case liveActivitiesOff, startFailed(String)
    case spotifyRefused, spotifyLoggedOut, spotifyWait(seconds: Int), noConnection, spotifyFailed(String)
    case suspended(seconds: Int), autoStopped(minutes: Int)

    /// A Spotify check that works again clears these.
    var clearsOnPoll: Bool {
        switch self {
        case .spotifyRefused, .spotifyLoggedOut, .spotifyWait, .noConnection, .spotifyFailed: true
        default: false
        }
    }

    init(_ error: Error) {
        switch error as? SpotifyError {
        case .http(403)?: self = .spotifyRefused
        case .notConnected?, .http(400)?, .http(401)?: self = .spotifyLoggedOut
        default: self = error is URLError ? .noConnection : .spotifyFailed(error.localizedDescription)
        }
    }
}

/// A song and whether LRCLIB has lyrics for it, for the app's Up next / Played lists.
struct SongCheck: Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    var lyrics: LyricsAvailability
}

/// Polls what's playing, finds synced lyrics, and updates one Live Activity at each line change.
/// The demo uses this exact path with a fake looping track, so it tests what Spotify will use.
@MainActor @Observable
final class LyricsEngine {
    private(set) var running: PlaybackSourceKind?
    /// The card last sent to the Lock Screen and CarPlay, which Home shows too. Nil when stopped.
    private(set) var card: LyricsActivityAttributes.ContentState?
    /// What Home should explain. Cleared on Start and Stop; Spotify trouble also clears once a check works again.
    private(set) var issue: SessionIssue?
    /// Also kept in a file, so it survives the app closing and can be shared from the app or copied off the phone.
    private(set) var log: [String] = (try? String(contentsOf: LyricsEngine.logFile, encoding: .utf8))
        .map { $0.split(separator: "\n").map(String.init) } ?? []
    static let logFile = URL.documentsDirectory.appending(path: "LyricsDash-log.txt")
    /// Songs played this session, newest first, with their lyrics status.
    private(set) var history: [SongCheck] = []
    /// The next few Spotify queue songs; their lyrics are prefetched so they show instantly.
    private(set) var upNext: [SongCheck] = []
    let spotify = Spotify()
    let offline = OfflineLyrics()
    /// Detailed logs, one file per session, for sharing when something goes wrong with the card.
    let diagnostics = UpdateDiagnostics()

    private var activity: Activity<LyricsActivityAttributes>?
    private var now: NowPlaying?
    private var lines: [LyricLine] = []
    private var availability = LyricsAvailability.waiting
    private var cache: [String: LyricsLookup.Result] = [:]
    private var pollTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var demoStart = Date.now
    @ObservationIgnored private lazy var silentAudio = SilentAudio { [weak self] in self?.note($0) }
    @ObservationIgnored private lazy var location = LocationKeepAlive { [weak self] in self?.note($0) }
    private var observers: [NSObjectProtocol] = []
    private var activityStateTask: Task<Void, Never>?
    private var otherAudioTask: Task<Void, Never>?
    // Diagnostics for "lyrics stop updating after a while" (see startDiagnostics).
    private var heartbeatTask: Task<Void, Never>?
    private var contentTask: Task<Void, Never>?
    private var startedAt = Date.now
    private(set) var appliedSeq = 0  // the newest update iOS reported applying (contentUpdates)
    private var reportedLag = false
    private var pushesSinceBeat = 0
    private var checksOK = 0
    private var checksFailed = 0
    private var lastPlayed = Date.now
    private var art: (trackID: String, data: Data)?
    private var artTask: Task<Void, Never>?

    func start(_ source: PlaybackSourceKind) async {
        issue = nil
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            note("Live Activities are off for Lyrics Dash: Settings → Lyrics Dash → Live Activities")
            issue = .liveActivitiesOff
            return
        }
        // Xcode's Stop, a crash, or iOS killing the app leaves its card on screen, frozen. Next to the new one,
        // iOS may show the dead card (for example "Play something on Spotify") in the Dynamic Island.
        let leftovers = Activity<LyricsActivityAttributes>.activities
        for old in leftovers { await old.end(nil, dismissalPolicy: .immediate) }
        if !leftovers.isEmpty { note("Closed \(leftovers.count) frozen card\(leftovers.count == 1 ? "" : "s") from an earlier run") }
        do {
            activity = try Activity.request(
                attributes: .init(),
                content: .init(state: .init(title: "Lyrics Dash", artist: "", current: "Starting…", next: "",
                                            lyrics: .waiting, seq: 0), staleDate: nil))
        } catch {
            note("Start failed: \(error.localizedDescription)")
            issue = .startFailed(error.localizedDescription)
            return
        }
        running = source
        demoStart = .now
        watchForPauses()
        startDiagnostics()
        diagnostics.runStarted(source == .demo ? "Demo" : source == .spotify ? "Spotify" : "Apple Music")
        updateKeepAlive()
        note(source == .demo ? "Demo started" : "Following \(source == .spotify ? "Spotify" : "Apple Music")")
        pollTask = Task { await pollLoop(source) }
        if source == .spotify { otherAudioTask = Task { await watchOtherAudio() } }
    }

    func stop() async {
        issue = nil
        [pollTask, renderTask, lyricsTask, prefetchTask, activityStateTask, otherAudioTask, artTask, heartbeatTask, contentTask]
            .forEach { $0?.cancel() }
        diagnostics.runEnded()
        art = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        await activity?.end(nil, dismissalPolicy: .immediate)
        activity = nil
        silentAudio.stop()
        location.stop()
        running = nil; now = nil; lines = []; card = nil; upNext = []
        WidgetSnapshot.save(nil)  // the widget goes back to its start button
        WidgetCenter.shared.reloadAllTimelines()
        note("Stopped")
    }

    // MARK: Polling

    private func pollLoop(_ source: PlaybackSourceKind) async {
        lastPlayed = .now
        while !Task.isCancelled {
            let delay = await pollOnce(source)
            silentAudio.check()
            let idleMinutes = UserDefaults.standard.object(forKey: "idleMinutes") as? Int ?? 20
            if Date.now.timeIntervalSince(lastPlayed) > Double(idleMinutes * 60) {
                note("Nothing played for \(idleMinutes) minutes, so lyrics stopped to save battery")
                Task { await stop(); issue = .autoStopped(minutes: idleMinutes) }
                return
            }
            let due = Date.now.addingTimeInterval(Double(delay) / 1000)
            try? await Task.sleep(for: .milliseconds(delay))
            let paused = Date.now.timeIntervalSince(due)
            if !Task.isCancelled, paused > 3 {
                note("App was paused for \(Int(paused)) s, likely suspended by iOS")
                // Home explains pauses long enough to have dimmed the card (it goes stale 10 s after a missed line).
                if paused > 10 { issue = .suspended(seconds: Int(paused)) }
            }
        }
    }

    /// Asks the source what's playing and applies it. Returns how long to wait before asking again.
    /// Neither source says when you pause or play, so the lyrics run on (or stay frozen) until the next check.
    @discardableResult
    private func pollOnce(_ source: PlaybackSourceKind) async -> Int {
        // Apple Music is read on the phone, so twice a second is free. Spotify is a web request, so every 2 s.
        let interval = source == .appleMusic ? 500 : 2_000
        do {
            let fresh: NowPlaying?
            switch source {
            case .spotify: fresh = try await spotify.nowPlaying()
            case .appleMusic: fresh = AppleMusic.nowPlaying()
            case .demo: fresh = demoNowPlaying()
            }
            apply(fresh)
            if issue?.clearsOnPoll == true { issue = nil }
            if source == .spotify { checksOK += 1 }
            guard let fresh, fresh.playback.isPlaying else { return interval }
            lastPlayed = .now
            // Also check right after the song should end, to pick up the next one.
            let remaining = fresh.durationMs - fresh.playback.position(at: .now)
            return min(interval, max(500, remaining + 300))
        } catch SpotifyError.rateLimited(let seconds) {
            checksFailed += 1
            if now?.playback.isPlaying == true { lastPlayed = .now }  // the music is most likely still playing
            // Spotify can ask for a very long wait; never freeze the lyrics for more than 30 s.
            note("Spotify asked the app to wait \(seconds) s; trying again in \(min(seconds, 30)) s")
            issue = .spotifyWait(seconds: min(seconds, 30))
            return min(seconds, 30) * 1000
        } catch {
            // No network (a tunnel, a dead zone): the song is most likely still playing and its lyrics keep moving on
            // the phone's clock, so this isn't idle time. Counting it as idle used to stop the app in long dead zones.
            if now?.playback.isPlaying == true { lastPlayed = .now }
            checksFailed += 1
            note("Spotify: \(error.localizedDescription)")
            issue = SessionIssue(error)
            return 10_000
        }
    }

    /// iOS can say whether another app (Spotify) is playing audio. Reading that costs nothing, so it's checked
    /// twice a second; when it flips, Spotify is asked straight away instead of at the next 2-second check.
    /// ponytail: Apple doesn't say this works in the background. If it never fires there, the 2-second
    /// checks still cap how long lyrics run on after a pause.
    private func watchOtherAudio() async {
        var playing = AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            let now = AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint
            guard now != playing, !Task.isCancelled else { continue }
            playing = now
            note("Music \(now ? "started" : "stopped") on the phone; checking Spotify now")
            await pollOnce(.spotify)
            try? await Task.sleep(for: .seconds(1))  // Spotify's servers can lag the app by a moment
            await pollOnce(.spotify)
        }
    }

    /// Logs what can stop the Lock Screen card updating: iOS suspending the app or the Live Activity being
    /// ended or dismissed. The keep-alives log their own trouble.
    private func watchForPauses() {
        let events: [(Notification.Name, String)] = [
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "Phone locked"),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "Phone unlocked"),
            (UIApplication.didEnterBackgroundNotification, "App in background"),
            (UIApplication.willEnterForegroundNotification, "App in foreground"),
        ]
        observers = events.map { name, message in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.note(message) }
            }
        }
        guard let activity else { return }
        activityStateTask = Task { [weak self] in
            for await state in activity.activityStateUpdates { self?.note("Live Activity is now \(state)") }
        }
    }

    /// Evidence for lyrics that stop updating after a while: a status line every 5 minutes, and a warning when iOS
    /// stops applying the card updates the app sends. iOS reports each update it applies through contentUpdates, so
    /// "sent" racing ahead of "applied" while the app keeps running means iOS is holding the updates back.
    private func startDiagnostics() {
        startedAt = .now; appliedSeq = 0; reportedLag = false
        pushesSinceBeat = 0; checksOK = 0; checksFailed = 0
        guard let activity else { return }
        contentTask = Task { [weak self] in
            for await content in activity.contentUpdates {
                self?.appliedSeq = content.state.seq
                self?.diagnostics.took(content.state.seq)
            }
        }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                if !Task.isCancelled { self?.heartbeat() }
            }
        }
    }

    private func heartbeat() {
        let minutes = Int(Date.now.timeIntervalSince(startedAt) / 60)
        let renewed = spotify.renewedAt.map { "Spotify login renewed \(Int(Date.now.timeIntervalSince($0) / 60)) min ago" } ?? "Spotify login not renewed yet"
        note("Running \(minutes) min · card #\(card?.seq ?? 0) sent, #\(appliedSeq) applied by iOS · last 5 min: \(pushesSinceBeat) card updates, "
             + "\(checksOK) ok and \(checksFailed) failed checks · Live Activity \(activity.map { "\($0.activityState)" } ?? "none") · "
             + "\(renewed) · \(os_proc_available_memory() / 1_048_576) MB memory headroom")
        pushesSinceBeat = 0; checksOK = 0; checksFailed = 0
    }

    /// Starts or stops each way of staying alive in the background to match the app's settings.
    /// Either one alone keeps the app running; together they cover each other's gaps.
    func updateKeepAlive() {
        guard running != nil else { return }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "keepAliveAudio") as? Bool ?? true { silentAudio.start() } else { silentAudio.stop() }
        if defaults.object(forKey: "keepAliveLocation") as? Bool ?? true { location.start() } else { location.stop() }
    }

    /// Re-sends the card now, e.g. after the appearance or timing changes.
    func refreshCard() {
        if running != nil { reschedule(); publishWidget() }
    }

    func dismissIssue() { issue = nil }

    /// Whether the Lock Screen card is still up (active), paused (stale), or closed (dismissed or ended).
    var activityState: ActivityState? { activity?.activityState }

    /// Which keep-alives are running right now, for the Keep running screen.
    var keepAliveStatus: (audio: Bool, location: Bool) { (silentAudio.isRunning, location.updating) }

    private func apply(_ fresh: NowPlaying?) {
        let trackChanged = fresh?.trackID != now?.trackID
        let playChanged = fresh?.playback.isPlaying != now?.playback.isPlaying
        // A position more than 1.5 s from where it should be means a seek, so the widget's timeline is wrong.
        let jumped = !trackChanged && !playChanged && fresh.map { fresh in
            now.map { abs(fresh.playback.position(at: .now) - $0.playback.position(at: .now)) > 1_500 } ?? false
        } ?? false
        if trackChanged || playChanged {
            if let fresh {
                let ms = fresh.playback.position(at: .now)
                note("\(fresh.playback.isPlaying ? "Playing" : "Paused") at \(ms / 60_000):\(String(format: "%02d", ms / 1000 % 60)) · \(fresh.title)")
            } else {
                note("Nothing playing")
            }
        }
        now = fresh
        if let fresh, trackChanged || availability == .offline { loadLyrics(for: fresh) }
        if trackChanged, fresh != nil, running == .spotify { refreshUpNext() }
        if trackChanged, let fresh { loadArt(for: fresh) }
        if trackChanged || playChanged || jumped { publishWidget() }
        reschedule()  // always: a fresh sample corrects timing drift, and push() skips no-op updates
    }

    /// Saves what the lyrics widget needs to step through the song by itself, and asks iOS to redraw it.
    /// Called on every change the widget can't predict: song, play or pause, seek, lyrics, art, appearance.
    /// While the silent audio runs, Apple doesn't count these reloads against the widget's daily budget.
    private func publishWidget() {
        guard running != nil else { return }
        let position = now.map(displayPosition) ?? 0
        let snapshot = now.map { now in
            WidgetSnapshot(title: now.title, artist: now.artist, lines: lines.map { .init(start: $0.start, end: $0.end, text: $0.text) },
                           durationMs: now.durationMs,
                           songStart: now.playback.isPlaying ? Date.now.addingTimeInterval(-Double(position) / 1000) : nil,
                           positionMs: position, lyrics: availability, style: .saved,
                           art: art?.trackID == now.trackID ? art?.data : nil, album: now.album,
                           live: UserDefaults.standard.object(forKey: "liveWidget") as? Bool ?? true,
                           carPlayLeadMs: UserDefaults.standard.integer(forKey: "carPlayLeadMs"),
                           widgetLeadMs: UserDefaults.standard.integer(forKey: "widgetLeadMs"))
        } ?? WidgetSnapshot(title: "Nothing playing", artist: "", lines: [], durationMs: 0, songStart: nil, positionMs: 0,
                            lyrics: .waiting, style: .saved, art: nil)
        WidgetSnapshot.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Fetches the song's album art once and shrinks it to 12×12 for the blurred backdrop.
    /// ponytail: fetched for every song (a few KB from Spotify) so switching to the art backdrop is instant.
    private func loadArt(for track: NowPlaying) {
        artTask?.cancel()
        artTask = Task {
            var image: CGImage?
            if let url = track.artworkURL, let (data, _) = try? await URLSession.shared.data(from: url) {
                image = UIImage(data: data)?.cgImage
            } else if running == .appleMusic {
                image = AppleMusic.artwork()
            }
            guard !Task.isCancelled, now?.trackID == track.trackID, let image, let thumbnail = Artwork.thumbnail(of: image) else { return }
            art = (track.trackID, thumbnail)
            reschedule()
            publishWidget()
        }
    }

    /// Checks the next queued songs on LRCLIB (10, or 20 in Road trip mode) and saves their lyrics on the phone ahead of
    /// time, so a playlist keeps its lyrics through a dead zone. Songs already saved cost no request.
    /// ponytail: Apple's MediaPlayer exposes no queue to read, so Apple Music relies on saving the library instead.
    private func refreshUpNext() {
        prefetchTask?.cancel()
        prefetchTask = Task {
            let ahead = UserDefaults.standard.bool(forKey: "roadTrip") ? 20 : 10  // 20 is all Spotify's queue lists
            guard let queue = try? await spotify.queue().prefix(ahead) else { return }
            for track in queue where cache[track.trackID] == nil { cache[track.trackID] = LyricsLookup.saved(track) }
            var checks = queue.map { SongCheck(id: $0.trackID, title: $0.title, artist: $0.artist,
                                               lyrics: cache[$0.trackID]?.availability ?? .searching) }
            upNext = checks
            for (index, track) in queue.enumerated() where cache[track.trackID] == nil {
                let result = await LyricsLookup.find(track)
                if Task.isCancelled { return }
                if result.availability != .offline { cache[track.trackID] = result }
                LyricsLookup.save(result, for: track)  // so the playlist keeps its lyrics through a dead zone
                checks[index].lyrics = result.availability
                upNext = checks
            }
        }
    }

    private func record(_ track: NowPlaying, _ lyrics: LyricsAvailability) {
        history.removeAll { $0.id == track.trackID }
        history.insert(SongCheck(id: track.trackID, title: track.title, artist: track.artist, lyrics: lyrics), at: 0)
        if history.count > 30 { history.removeLast(history.count - 30) }
    }

    private func demoNowPlaying() -> NowPlaying {
        let elapsed = Int(Date.now.timeIntervalSince(demoStart) * 1000) % DemoSong.durationMs
        return NowPlaying(trackID: "demo", title: DemoSong.title, artists: [DemoSong.artist], album: "",
                          durationMs: DemoSong.durationMs,
                          playback: PlaybackSnapshot(progressMs: elapsed, sampledAt: .now, isPlaying: true, durationMs: DemoSong.durationMs))
    }

    // MARK: Lyrics

    private func loadLyrics(for track: NowPlaying) {
        if cache[track.trackID] == nil, let saved = LyricsLookup.saved(track) { cache[track.trackID] = saved }  // works offline
        if let hit = cache[track.trackID] {
            lines = hit.lines; availability = hit.availability; record(track, hit.availability); return
        }
        if lyricsTask != nil && availability == .offline { return }  // a retry is already running
        lines = []; availability = .searching
        lyricsTask?.cancel()
        lyricsTask = Task {
            let result = track.trackID == "demo"
                ? LyricsLookup.Result(synced: DemoSong.lrc, durationMs: DemoSong.durationMs)
                : await LyricsLookup.find(track)
            lyricsTask = nil
            guard !Task.isCancelled, now?.trackID == track.trackID else { return }
            lines = result.lines; availability = result.availability
            if result.availability != .offline { cache[track.trackID] = result }  // offline: retry next poll
            if track.trackID != "demo" { LyricsLookup.save(result, for: track) }
            record(track, result.availability)
            note("\(track.title): \(result.lines.isEmpty ? result.availability.label : "\(result.lines.count) synced lines")")
            reschedule()
            publishWidget()
        }
    }

    // MARK: Rendering

    private func reschedule() {
        renderTask?.cancel()
        renderTask = Task { await renderLoop() }
    }

    /// Push the current line, then sleep exactly until the line changes.
    private func renderLoop() async {
        while !Task.isCancelled {
            await push()
            guard let now, now.playback.isPlaying,
                  let change = LyricSync.nextChange(lines, after: displayPosition(now)) else { return }
            // Zero tolerance: without it the system may fire the timer late to batch wakeups.
            try? await Task.sleep(for: .milliseconds(max(1, change - displayPosition(now))), tolerance: .zero)
            let late = displayPosition(now) - change
            if !Task.isCancelled, late > 50 { note("Line change woke \(late) ms late") }
        }
    }

    /// Playback position plus the "show lines early" lead, which covers the lag between an
    /// activity update and the card changing on screen. ponytail: one value for Lock Screen and CarPlay.
    private func displayPosition(_ track: NowPlaying) -> Int {
        track.playback.position(at: .now) + UserDefaults.standard.integer(forKey: "leadMs")
    }

    /// 10 s after the next expected line change. If no update has come by then (the app was suspended,
    /// killed or crashed), the card shows itself as paused instead of a wrong lyric.
    private func staleDate() -> Date? {
        guard let now, now.playback.isPlaying, !lines.isEmpty,
              let change = LyricSync.nextChange(lines, after: displayPosition(now)) else { return nil }
        return Date.now.addingTimeInterval(Double(change - displayPosition(now)) / 1000 + 10)
    }

    private func push() async {
        var state = displayState()
        state.style = .saved
        if let art, art.trackID == now?.trackID { state.art = art.data }  // the backdrop and the island's album tile
        // ActivityKit refuses updates over 4 KB. Very long non-Latin lines plus art could get close, so drop the art then.
        if state.art != nil, ((try? JSONEncoder().encode(state))?.count ?? 0) > 3_800 { state.art = nil }
        if let card, Self.sameDisplay(state, card) { return }
        let reason = Self.reason(state, card)
        state.seq = (card?.seq ?? 0) + 1
        card = state
        let sent = Date.now
        await activity?.update(.init(state: state, staleDate: staleDate()))
        pushesSinceBeat += 1
        // Only once iOS has reported at least one applied update, so a phone that never reports can't cause a false alarm.
        if appliedSeq > 0 {
            let behind = state.seq - appliedSeq
            if behind > 5, !reportedLag { reportedLag = true; note("iOS isn't applying card updates: sent #\(state.seq), applied #\(appliedSeq)") }
            if behind <= 1, reportedLag { reportedLag = false; note("iOS is applying card updates again (#\(appliedSeq))") }
        }
        let took = Int(Date.now.timeIntervalSince(sent) * 1000)
        if took > 200 { note("Live Activity update took \(took) ms") }
        diagnostics.sent(state.seq, at: sent, reason: reason, updateMs: took)
    }

    /// Why an update was sent, for the update diagnostics. If iOS allows each card a fixed number of updates,
    /// the ones that only re-time the progress bar ("timing") are the first to cut.
    private static func reason(_ new: LyricsActivityAttributes.ContentState, _ old: LyricsActivityAttributes.ContentState?) -> String {
        guard let old else { return "first" }
        if new.title != old.title || new.artist != old.artist { return "song" }
        if new.current != old.current || new.next != old.next || new.instrumental != old.instrumental { return "line" }
        if new.lyrics != old.lyrics { return "lyrics" }
        if (new.lineStart == nil) != (old.lineStart == nil) { return "play/pause" }
        if new.style != old.style || new.art != old.art { return "look" }
        return "timing"
    }

    /// Equal apart from seq, with line times allowed to drift a little. Each poll re-measures
    /// playback, so the progress-bar dates move by a few ms; that alone shouldn't cost an update.
    private static func sameDisplay(_ a: LyricsActivityAttributes.ContentState, _ b: LyricsActivityAttributes.ContentState) -> Bool {
        func close(_ x: Date?, _ y: Date?) -> Bool {
            switch (x, y) {
            case (nil, nil): true
            case let (x?, y?): abs(x.timeIntervalSince(y)) < 0.4
            default: false
            }
        }
        var a = a, b = b
        guard close(a.lineStart, b.lineStart), close(a.lineEnd, b.lineEnd) else { return false }
        a.lineStart = nil; a.lineEnd = nil; a.seq = 0
        b.lineStart = nil; b.lineEnd = nil; b.seq = 0
        return a == b
    }

    private func displayState() -> LyricsActivityAttributes.ContentState {
        guard let now else {
            return .init(title: "Lyrics Dash", artist: "", current: "Play something on \(running == .appleMusic ? "Apple Music" : "Spotify")",
                         next: "", lyrics: .waiting, seq: 0)
        }
        // ActivityKit caps an update at 4 KB.
        let title = String(now.title.prefix(120)), artist = String(now.artist.prefix(120))
        guard !lines.isEmpty else {
            // No lyrics to follow: show what's playing, and why there are no lyrics.
            let reason = switch availability {
            case .searching: "Finding lyrics…"
            case .unsynced: "Only unsynced lyrics on LRCLIB"
            case .instrumental: "Instrumental"
            case .offline: "Can't reach LRCLIB"
            default: "No synced lyrics on LRCLIB"
            }
            return .init(title: title, artist: artist, current: title, next: reason, lyrics: availability, seq: 0)
        }
        let position = displayPosition(now)
        let index = LyricSync.activeIndex(lines, at: position)
        let current = index.map { lines[$0].text } ?? ""
        let sung = { (line: LyricLine) in !LyricsActivityAttributes.ContentState.isInstrumental(line.text) }
        let next = lines.first { $0.start > position && sung($0) }?.text ?? ""
        let previous = lines.last { $0.end <= position && sung($0) }?.text ?? ""
        // When display position reaches the line's start/end, so the card's bar runs in step with the lead.
        // Before the first line, the intro counts as one, so the progress bar runs then too.
        var lineStart: Date?, lineEnd: Date?
        if now.playback.isPlaying {
            let span = index.map { (lines[$0].start, lines[$0].end) }
                ?? (lines.last { $0.start <= position }?.end ?? 0, lines.first { $0.start > position }?.start ?? now.durationMs)
            lineStart = Date.now.addingTimeInterval(Double(span.0 - position) / 1000)
            lineEnd = Date.now.addingTimeInterval(Double(span.1 - position) / 1000)
        }
        let instrumental = LyricsActivityAttributes.ContentState.isInstrumental(current)
        return .init(title: title, artist: artist, current: instrumental ? "" : String(current.prefix(300)), next: String(next.prefix(300)),
                     previous: String(previous.prefix(300)), album: String(now.album.prefix(120)), instrumental: instrumental,
                     lyrics: .synced, lineStart: lineStart, lineEnd: lineEnd, seq: 0)
    }

    private func note(_ message: String) {
        log.append("\(Date.now.formatted(.dateTime.month().day().hour().minute().second())) \(message)")
        if log.count > 500 { log.removeFirst(log.count - 500) }
        try? log.joined(separator: "\n").write(to: Self.logFile, atomically: true, encoding: .utf8)
        diagnostics.event(message)
    }
}

/// LRCLIB lookup: exact match first, then a matched search.
enum LyricsLookup {
    struct Result: Sendable {
        let lines: [LyricLine]
        let availability: LyricsAvailability  // .offline: network trouble, so don't cache it
        /// The LRC the lines came from, kept so the result can be saved for offline use.
        var lrc: String?

        init(lines: [LyricLine], availability: LyricsAvailability) { self.lines = lines; self.availability = availability }
        init(synced: String, durationMs: Int) {
            let lines = LRC.parse(synced, durationMs: durationMs)
            self.init(lines: lines, availability: lines.isEmpty ? .missing : .synced)
            lrc = synced
        }
    }

    /// Synced and instrumental results are kept on the phone for good. "Not found" isn't, since LRCLIB may add it later.
    static let diskFolder = URL.applicationSupportDirectory.appending(path: "Lyrics", directoryHint: .isDirectory)
    static let disk = LyricsDiskCache(folder: diskFolder)

    static func saved(_ track: NowPlaying) -> Result? {
        guard let entry = disk.load(track.trackID) else { return nil }
        return entry.instrumental ? Result(lines: [], availability: .instrumental) : Result(synced: entry.lrc, durationMs: track.durationMs)
    }

    static func save(_ result: Result, for track: NowPlaying) {
        switch result.availability {
        case .synced: if let lrc = result.lrc { disk.save(.init(lrc: lrc, instrumental: false), for: track.trackID) }
        case .instrumental: disk.save(.init(lrc: "", instrumental: true), for: track.trackID)
        default: break
        }
    }

    static func find(_ track: NowPlaying) async -> Result {
        do {
            var hasPlain = false
            if let exact: LRCLIB.Record = try await fetch(LRCLIB.getURL(for: track)) {
                if exact.instrumental == true { return Result(lines: [], availability: .instrumental) }
                if let synced = exact.syncedLyrics, !synced.isEmpty { return Result(synced: synced, durationMs: track.durationMs) }
                hasPlain = !(exact.plainLyrics ?? "").isEmpty
            }
            if let rows: [LRCLIB.Record] = try await fetch(LRCLIB.searchURL(for: track)),
               let best = LRCLIB.best(rows, for: track) {
                return Result(synced: best.syncedLyrics ?? "", durationMs: track.durationMs)
            }
            return Result(lines: [], availability: hasPlain ? .unsynced : .missing)
        } catch {
            return Result(lines: [], availability: .offline)
        }
    }

    /// Songs for the app's "check any song" box; check each one with `find`, the lookup used while playing.
    static func search(_ query: String) async throws -> [NowPlaying] {
        let (data, response) = try await URLSession.shared.data(from: ITunesSearch.url(query))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LookupError.http("Song search", status) }
        return try ITunesSearch.decode(data)
    }

    private static func fetch<T: Decodable>(_ url: URL, attempt: Int = 1) async throws -> T? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("LyricsDash/0.1 (personal use)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return try JSONDecoder().decode(T.self, from: data)
        case 404: return nil
        case 429, 503:
            // LRCLIB answers 503 "The server is busy, please retry in a moment" when overloaded.
            guard attempt < 3 else { throw LookupError.busy }
            try await Task.sleep(for: .seconds(attempt))
            return try await fetch(url, attempt: attempt + 1)
        case let status: throw LookupError.http("LRCLIB", status)
        }
    }

    enum LookupError: LocalizedError {
        case busy, http(String, Int)

        var errorDescription: String? {
            switch self {
            case .busy: "LRCLIB is busy right now. Try again in a minute."
            case .http(let service, let status): "\(service) returned HTTP \(status)"
            }
        }
    }
}

extension CardStyle {
    /// The Appearance screen's choice. Only the app can read it, so it travels inside each update.
    /// Saved values are laid over the defaults, so settings added in later versions don't reset the rest.
    static var saved: CardStyle {
        get { UserDefaults.standard.data(forKey: "cardStyle").flatMap(load) ?? CardStyle() }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "cardStyle") }
    }

    /// A saved style laid over the defaults, so settings added in later versions don't reset the rest.
    /// Also reads Appearance's saved and unsaved looks.
    static func load(_ data: Data) -> CardStyle? {
        guard var saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(CardStyle())) as? [String: Any]
        else { return nil }
        if saved["autoText"] == nil, let text = saved["text"] as? [String: Double] {
            // Saved before automatic text colour existed: keep a colour the user picked, otherwise go automatic.
            saved["autoText"] = text == ["red": 1, "green": 1, "blue": 1]
        }
        guard let merged = try? JSONSerialization.data(withJSONObject: defaults.merging(saved) { _, new in new }) else { return nil }
        return try? JSONDecoder().decode(CardStyle.self, from: merged)
    }
}
