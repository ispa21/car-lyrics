import Foundation
import LyricsCore
import Network
import Observation
import UIKit

/// Saves lyrics for many songs ahead of time, for driving without signal. Uses Wi-Fi only (it waits while on
/// mobile data), skips songs already saved, and paces itself so LRCLIB, a free community service, isn't flooded.
@MainActor @Observable
final class OfflineLyrics {
    private(set) var label = ""
    private(set) var done = 0
    private(set) var total = 0
    private(set) var current = ""
    private(set) var waitingForWiFi = false
    private(set) var summary = ""
    private(set) var usage = OfflineLyrics.measure()
    private var task: Task<Void, Never>?
    private var onWiFi = true
    @ObservationIgnored private let monitor = NWPathMonitor()

    var running: Bool { task != nil }

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.status == .satisfied && !path.isExpensive
            Task { @MainActor in self?.onWiFi = wifi }
        }
        monitor.start(queue: .main)
    }

    /// Saves lyrics for every song `songs` returns. One run at a time.
    func save(_ label: String, _ songs: @escaping @MainActor () async throws -> [NowPlaying]) {
        guard task == nil else { return }
        self.label = label
        done = 0; total = 0; summary = ""; current = "Finding songs…"
        // While the screen stays on, iOS keeps the app running, so the download isn't paused halfway.
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            var saved = 0, already = 0, missing = 0, failed = 0
            do {
                let list = try await songs()
                total = list.count
                for song in list {
                    if Task.isCancelled { break }
                    current = song.title
                    if LyricsLookup.disk.load(song.trackID) != nil { already += 1; done += 1; continue }
                    while !onWiFi, !Task.isCancelled {
                        waitingForWiFi = true
                        try? await Task.sleep(for: .seconds(2))
                    }
                    waitingForWiFi = false
                    if Task.isCancelled { break }
                    let result = await LyricsLookup.find(song)
                    LyricsLookup.save(result, for: song)
                    switch result.availability {
                    case .synced, .instrumental: saved += 1
                    case .offline: failed += 1
                    default: missing += 1
                    }
                    done += 1
                    try? await Task.sleep(for: .milliseconds(300))
                }
                var parts = ["\(saved) saved", "\(already) already saved", "\(missing) without synced lyrics"]
                if failed > 0 { parts.append("\(failed) couldn't reach LRCLIB (try again later)") }
                summary = parts.joined(separator: " · ") + (Task.isCancelled ? " · stopped" : "")
            } catch {
                summary = "Couldn't get the songs: \(error.localizedDescription)"
            }
            finish()
        }
    }

    func stop() { task?.cancel() }

    func deleteAll() {
        try? FileManager.default.removeItem(at: LyricsLookup.diskFolder)
        refreshUsage()
    }

    func refreshUsage() { usage = Self.measure() }

    private func finish() {
        task = nil
        waitingForWiFi = false
        UIApplication.shared.isIdleTimerDisabled = false
        refreshUsage()
    }

    /// How many songs have saved lyrics and the space they take.
    private static func measure() -> (songs: Int, bytes: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(at: LyricsLookup.diskFolder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return (files.count, files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) })
    }
}
