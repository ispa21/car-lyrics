import AVFAudio

/// Plays silence mixed with other audio so iOS keeps the app running in the background (UIBackgroundModes audio).
/// Mixing means it never interrupts or lowers Spotify, which stays the Now Playing app and keeps the car's controls.
/// Recovers from what stops it: calls, Siri and alarms (interruptions), route changes, and audio services resets.
/// ponytail: personal-build keep-alive; App Review would reject it. Upgrade path: server + APNs pushes.
@MainActor
final class SilentAudio {
    private let log: (String) -> Void
    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []
    private var retryTask: Task<Void, Never>?
    private var wanted = false
    private var failing = false

    init(log: @escaping (String) -> Void) { self.log = log }

    var isRunning: Bool { player?.isPlaying == true }

    func start() {
        guard !wanted else { return }
        wanted = true
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
                let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let began = type == AVAudioSession.InterruptionType.began.rawValue
                Task { @MainActor in self?.interrupted(began: began) }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.check() }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.servicesReset() }
            },
        ]
        resume()
    }

    func stop() {
        guard wanted else { return }
        wanted = false
        retryTask?.cancel()
        retryTask = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Restarts the silence if something stopped it. The engine calls this on every poll as a watchdog,
    /// because iOS doesn't promise an "interruption ended" for every interruption.
    func check() {
        guard wanted, retryTask == nil, player?.isPlaying != true else { return }
        log("Silent audio had stopped; restarting it")
        resume()
    }

    private func interrupted(began: Bool) {
        guard wanted else { return }
        if began {
            log("Silent audio interrupted (call, Siri or alarm)")
        } else {
            // Resume even without .shouldResume: silence can't bother anyone.
            log("Interruption over; restarting silent audio")
            resume()
        }
    }

    private func servicesReset() {
        guard wanted else { return }
        log("iOS audio services reset; rebuilding silent audio")
        player = nil
        resume()
    }

    /// Starts the silence, retrying every 5 s while something (a call, say) still holds the audio.
    private func resume() {
        retryTask?.cancel()
        retryTask = nil
        guard wanted else { return }
        var problem: String?
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            if player == nil {
                player = try AVAudioPlayer(data: Self.silence)
                player?.numberOfLoops = -1
            }
            if player?.play() != true { problem = "the player didn't start" }
        } catch {
            problem = error.localizedDescription
        }
        guard let problem else {
            if failing { log("Silent audio running again") }
            failing = false
            return
        }
        if !failing { log("Silent audio couldn't start (\(problem)); retrying every 5 s") }
        failing = true
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.retryTask = nil
            self?.resume()
        }
    }

    /// One second of 8 kHz, 16-bit mono silence as a WAV file, looped forever.
    static let silence: Data = {
        let byteCount = 8_000 * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))  // PCM, mono
        append(UInt32(8_000)); append(UInt32(16_000)); append(UInt16(2)); append(UInt16(16))  // rate, bytes/s, block, bits
        data.append(contentsOf: Array("data".utf8)); append(UInt32(byteCount))
        data.append(Data(count: byteCount))
        return data
    }()
}
