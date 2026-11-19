import ActivityKit
import Foundation
import notify
import SwiftUI
import UIKit

/// Detailed logs, one file per session (each Start to Stop), for sharing when something goes wrong with the lyrics card.
/// Written for "the card freezes after about 250 updates" first. A session file holds:
/// - a header with the iOS version and the settings that matter;
/// - one line per card update: why it was sent, the newest update iOS reported taking (contentUpdates), the newest the
///   widget drew at CarPlay and Lock Screen size (DrawProbe), and whether the screen was on;
/// - everything the main log says during the session (songs, pauses, locking, Spotify errors, status every 5 minutes);
/// - a summary at the end.
@MainActor @Observable
final class UpdateDiagnostics {
    static let folder = URL.documentsDirectory.appending(path: "Update diagnostics", directoryHint: .isDirectory)
    /// Newest first. ponytail: the last 30 sessions are kept, a few MB at most.
    private(set) var sessions: [URL] = UpdateDiagnostics.list()
    /// The session being recorded, if any.
    private(set) var session: URL?

    @ObservationIgnored private var started = Date.now
    @ObservationIgnored private var sentAt: [Int: Date] = [:]
    @ObservationIgnored private var lastSent = 0
    @ObservationIgnored private var taken = (seq: 0, at: Date.distantPast)
    @ObservationIgnored private var firstTookLag: Int?
    @ObservationIgnored private var firstCarPlayLag: Int?
    @ObservationIgnored private var longestCarPlayWait = (seconds: 0.0, seq: 0)
    @ObservationIgnored private var reasons: [String: Int] = [:]
    /// Nil when iOS doesn't say.
    @ObservationIgnored private var screenOff: Bool?

    init() {
        // ponytail: SpringBoard's "screen blanked" notification isn't public API, which is fine for a personal build.
        // If iOS stops posting it, lines say "screen ?" and the lock state still shows.
        var token: Int32 = 0
        let status = notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &token, .main) { [weak self] token in
            var state: UInt64 = 0
            notify_get_state(token, &state)
            MainActor.assumeIsolated { self?.screenChanged(off: state != 0) }
        }
        if status == 0 {
            var state: UInt64 = 0
            if notify_get_state(token, &state) == 0 { screenOff = state != 0 }
        }
    }

    func runStarted(_ source: String) {
        started = .now; sentAt = [:]; lastSent = 0; taken = (0, .distantPast)
        firstTookLag = nil; firstCarPlayLag = nil; longestCarPlayWait = (0, 0); reasons = [:]
        DrawProbe.reset()
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        for old in Self.list().dropFirst(29) { try? FileManager.default.removeItem(at: old) }
        session = Self.folder.appending(path: "\(Self.fileDate.string(from: .now)) \(source).txt")
        let defaults = UserDefaults.standard
        let on = { (key: String) in defaults.object(forKey: key) as? Bool ?? true ? "on" : "off" }
        write("=== \(source) session started \(Date.now.formatted(date: .abbreviated, time: .standard)) ===")
        write("iOS \(UIDevice.current.systemVersion) · More Frequent Updates \(ActivityAuthorizationInfo().frequentPushesEnabled ? "on" : "off") "
              + "· silent audio \(on("keepAliveAudio")) · location \(on("keepAliveLocation")) "
              + "· lines \(Double(defaults.integer(forKey: "leadMs")) / 1000) s early · stops after \(defaults.object(forKey: "idleMinutes") as? Int ?? 20) min idle "
              + "· road trip \(defaults.bool(forKey: "roadTrip") ? "on" : "off") · layout \(CardStyle.saved.layout) · \(deviceState)")
        sessions = Self.list()
    }

    /// iOS reported taking update `seq` (Activity.contentUpdates).
    func took(_ seq: Int) { taken = (seq, .now) }

    /// A main-log message, copied into the session so one file tells the whole story.
    func event(_ message: String) {
        if session != nil { write("\(Self.clock.string(from: .now)) \(message)") }
    }

    /// The app sent update `seq` at `time`, for `reason`; `updateMs` is how long Activity.update took to return.
    func sent(_ seq: Int, at time: Date, reason: String, updateMs: Int) {
        guard session != nil else { return }
        sentAt[seq] = time; sentAt[seq - 200] = nil
        lastSent = seq
        reasons[reason, default: 0] += 1
        let carPlay = DrawProbe.read(.carPlay), lockScreen = DrawProbe.read(.lockScreen)
        let tookBehind = seq - taken.seq
        let carPlayBehind = carPlay.map { seq - $0.seq } ?? 0
        if firstTookLag == nil, tookBehind > 5 { firstTookLag = seq }
        if firstCarPlayLag == nil, carPlayBehind > 5 { firstCarPlayLag = seq }
        // How long the oldest update CarPlay hasn't drawn has been waiting.
        if let carPlay, carPlayBehind > 1, let since = sentAt[carPlay.seq + 1] {
            let wait = Date.now.timeIntervalSince(since)
            if wait > longestCarPlayWait.seconds { longestCarPlayWait = (wait, carPlay.seq + 1) }
        }
        let tookText = taken.seq == 0 ? "nothing yet"
            : "#\(taken.seq)\(behind(tookBehind))" + (sentAt[taken.seq].map { ", \(seconds(taken.at.timeIntervalSince($0))) after sending" } ?? "")
        write("\(Self.clock.string(from: time)) #\(seq) \(reason) · took \(tookText) · CarPlay \(drawn(carPlay, seq)) · "
              + "Lock Screen \(drawn(lockScreen, seq)) · \(deviceState) · \(updateMs) ms")
    }

    func runEnded() {
        guard session != nil else { return }
        let minutes = Int(Date.now.timeIntervalSince(started) / 60)
        let first = { (seq: Int?) in seq.map { "#\($0)" } ?? "never" }
        let wait = longestCarPlayWait.seq == 0 ? "none" : "\(seconds(longestCarPlayWait.seconds)) (#\(longestCarPlayWait.seq))"
        let counts = reasons.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        write("=== Session ended after \(minutes) min · sent #\(lastSent) · took #\(taken.seq) · CarPlay drew \(drawn(DrawProbe.read(.carPlay), lastSent)) · "
              + "Lock Screen drew \(drawn(DrawProbe.read(.lockScreen), lastSent)) · first 6+ behind: took \(first(firstTookLag)), "
              + "CarPlay \(first(firstCarPlayLag)) · longest CarPlay wait \(wait) · updates by reason: \(counts) ===")
        session = nil
    }

    /// Deletes every session except the one being recorded.
    func clear() {
        for url in sessions where url != session { try? FileManager.default.removeItem(at: url) }
        sessions = Self.list()
    }

    private static func list() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }  // names start with the date
    }

    private func screenChanged(off: Bool) {
        guard off != screenOff else { return }
        screenOff = off
        event("Screen \(off ? "off" : "on")")
    }

    private var deviceState: String {
        let screen = screenOff.map { $0 ? "screen off" : "screen on" } ?? "screen ?"
        let lock = UIApplication.shared.isProtectedDataAvailable ? "unlocked" : "locked"
        let app = switch UIApplication.shared.applicationState {
        case .active: "app open"
        case .inactive: "app inactive"
        case .background: "app in background"
        @unknown default: "app ?"
        }
        return "\(screen), \(lock), \(app)"
    }

    private func drawn(_ draw: DrawProbe.Draw?, _ seq: Int) -> String {
        guard let draw else { return "nothing drawn" }
        let delay = sentAt[draw.seq].map { ", \(seconds(draw.at.timeIntervalSince($0))) after sending" } ?? ""
        return "#\(draw.seq)\(behind(seq - draw.seq))\(delay)"
    }

    private func behind(_ count: Int) -> String { count > 0 ? " (\(count) behind)" : "" }

    private func seconds(_ interval: TimeInterval) -> String { String(format: "%.1f s", interval) }

    private func write(_ line: String) {
        guard let session, let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: session) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: session)
        }
    }

    /// "Today, 10:39 · Demo · 3 min" for a session file named "2026-10-12 10.39.32 Demo.txt".
    static func title(of file: URL) -> String {
        let name = file.deletingPathExtension().lastPathComponent
        guard let start = fileDate.date(from: String(name.prefix(19))) else { return name }
        let calendar = Calendar.current
        let day = calendar.isDateInToday(start) ? "Today" : calendar.isDateInYesterday(start) ? "Yesterday"
            : start.formatted(.dateTime.day().month())
        var title = "\(day), \(start.formatted(date: .omitted, time: .shortened)) · \(name.dropFirst(20))"
        if let end = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            let minutes = Int(end.timeIntervalSince(start) / 60)
            title += minutes < 1 ? " · under a minute" : " · \(minutes) min"
        }
        return title
    }

    private static let clock = formatter("HH:mm:ss.S")
    private static let fileDate = formatter("yyyy-MM-dd HH.mm.ss")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter
    }
}

/// For when something broke: the latest session log one tap from sharing, every session's log, the app-wide event log,
/// and the testing switches.
struct TroubleshootingView: View {
    let engine: LyricsEngine
    @AppStorage("cardStyle") private var savedStyle: Data?
    @State private var confirmClear = false

    private var diagnostics: UpdateDiagnostics { engine.diagnostics }

    var body: some View {
        List {
            if let latest = diagnostics.sessions.first {
                Section {
                    ShareLink("Share latest session log", item: latest)
                } footer: {
                    Text("If the lyrics card misbehaved, send this file.")
                }
            }
            Section {
                if diagnostics.sessions.isEmpty {
                    Text("No sessions yet. Each time you tap Start, a new one is recorded here.").foregroundStyle(.secondary)
                }
                ForEach(diagnostics.sessions, id: \.self) { file in
                    NavigationLink { DiagnosticsSessionView(file: file) } label: {
                        HStack {
                            Text(UpdateDiagnostics.title(of: file))
                            Spacer()
                            if file == diagnostics.session { Text("Recording").font(.caption.weight(.semibold)).foregroundStyle(.red) }
                        }
                    }
                }
            } header: {
                Text("Session logs")
            } footer: {
                Text("One per session, from Start to Stop. The last 30 are kept.")
            }
            Section {
                NavigationLink("Event log") { EventLogView(engine: engine) }
            } footer: {
                Text("Everything Lyrics Dash noted, across sessions.")
            }
            Section {
                Toggle("Show update counter on card", isOn: counter)
            } header: {
                Text("Testing")
            } footer: {
                Text("Numbers each card update, to spot dropped ones. It shows in the Detailed and Karaoke layouts with song info, and as a dial on the widget.")
            }
            Section {
                Button("Clear session logs", role: .destructive) { confirmClear = true }
                    .disabled(diagnostics.sessions.allSatisfy { $0 == diagnostics.session })
            }
        }
        .navigationTitle("Troubleshooting")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete all recorded sessions?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete sessions", role: .destructive) { diagnostics.clear() }
        } message: {
            Text("The session being recorded now is kept.")
        }
    }

    /// The card's update counter lives in its style, which travels with every update.
    private var counter: Binding<Bool> {
        Binding(get: { (savedStyle.flatMap(CardStyle.load) ?? CardStyle()).showCounter }, set: { on in
            var style = CardStyle.saved
            style.showCounter = on
            CardStyle.saved = style
            engine.refreshCard()
        })
    }
}

/// The app-wide log, newest first.
struct EventLogView: View {
    let engine: LyricsEngine

    var body: some View {
        List(Array(engine.log.reversed().enumerated()), id: \.offset) { _, line in
            Text(line).font(.caption.monospaced())
        }
        .navigationTitle("Event log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ShareLink(item: engine.log.joined(separator: "\n")) }
    }
}

/// One session, newest line first, with a Share button for the file.
struct DiagnosticsSessionView: View {
    let file: URL
    @State private var lines: [String] = []

    var body: some View {
        List(Array(lines.enumerated().reversed()), id: \.offset) { _, line in
            Text(line).font(.caption.monospaced())
        }
        .navigationTitle(UpdateDiagnostics.title(of: file))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ShareLink(item: file) }
        .task { load() }
        .refreshable { load() }  // a session still recording grows; pull down to see the newest lines
    }

    private func load() {
        lines = (try? String(contentsOf: file, encoding: .utf8)).map { $0.split(separator: "\n").map(String.init) } ?? []
    }
}
