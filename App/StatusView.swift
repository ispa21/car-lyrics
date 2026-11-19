@preconcurrency import ActivityKit
import AVFAudio
import LyricsCore
import SwiftUI

/// Whether everything is working, in plain words: one row for each place lyrics show, each with a coloured symbol and a
/// label so it isn't colour alone. The logs (Troubleshooting) keep the detail; this screen has no update numbers.
struct StatusView: View {
    let engine: LyricsEngine

    var body: some View {
        // The probes live in the keychain and aren't observable, so this re-reads them every second.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let items = StatusItem.all(engine)
            List {
                Section {
                    StatusSummary(items: items, running: engine.running != nil).font(.headline)
                }
                Section {
                    ForEach(items) { item in
                        NavigationLink(value: item.route) { StatusRow(item: item) }
                    }
                } footer: {
                    Text("Widgets can't tell Lyrics Dash whether they're on screen, so they say when iOS last asked them for "
                         + "lyrics. The Dynamic Island doesn't show while Lyrics Dash is open, so it updates again once you leave.")
                }
            }
        }
        .navigationTitle("Status")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One place lyrics show, and how it's doing.
struct StatusItem: Identifiable {
    enum Health { case good, attention, problem, off }

    let title: String
    let value: String
    var detail: String? = nil
    let health: Health
    let route: Route
    var id: String { title }

    @MainActor static func all(_ engine: LyricsEngine) -> [StatusItem] {
        [lyrics(engine), lockScreen(engine), island(engine), carPlay(engine),
         widget("Home Screen widget", kind: "LyricsWidget", engine), widget("CarPlay widget", kind: "LyricsCarPlayWidget", engine),
         keepRunning(engine)]
    }

    @MainActor private static func lyrics(_ engine: LyricsEngine) -> StatusItem {
        let title = "Lyrics"
        guard let running = engine.running else { return .init(title: title, value: "Off", health: .off, route: .eventLog) }
        let source = running == .appleMusic ? "Apple Music" : running == .demo ? "the demo song" : "Spotify"
        let trouble: String? = switch engine.issue {
        case .spotifyRefused: "Spotify refused access"
        case .spotifyLoggedOut: "Spotify login expired"
        case .spotifyWait: "Spotify asked to wait"
        case .noConnection: "no connection"
        case .spotifyFailed: "Spotify isn't answering"
        default: nil
        }
        if let trouble { return .init(title: title, value: "Following \(source) · \(trouble)", health: .attention, route: .eventLog) }
        guard let card = engine.card else { return .init(title: title, value: "Starting…", health: .off, route: .eventLog) }
        let (state, health): (String, Health) = switch card.lyrics {
        case .waiting: ("nothing playing", .off)
        case .synced: ("\(card.title) · synced lyrics", .good)
        case .instrumental: ("\(card.title) · instrumental", .good)
        case .searching: ("finding lyrics", .attention)
        case .missing, .unsynced: ("\(card.title) · no synced lyrics", .attention)
        case .offline: ("can't reach the lyrics site", .attention)
        }
        return .init(title: title, value: "Following \(source) · \(state)", health: health, route: .eventLog)
    }

    @MainActor private static func lockScreen(_ engine: LyricsEngine) -> StatusItem {
        let title = "Lock Screen card"
        guard engine.running != nil, let card = engine.card else {
            return .init(title: title, value: "Off", health: .off, route: .troubleshooting)
        }
        switch engine.activityState {
        case .dismissed?: return .init(title: title, value: "Closed on the Lock Screen", health: .problem, route: .troubleshooting)
        case .ended?: return .init(title: title, value: "Ended", health: .problem, route: .troubleshooting)
        case .stale?: return .init(title: title, value: "Paused · lyrics stopped updating", health: .attention, route: .troubleshooting)
        default: break
        }
        let detail = DrawProbe.read(.lockScreen).map { "Updated \(ago($0.at))" } ?? "Hasn't updated yet"
        // iOS reports each update it takes. Several behind means it's holding them back.
        let behind = engine.appliedSeq > 0 ? card.seq - engine.appliedSeq : 0
        return behind >= 3
            ? .init(title: title, value: "Behind by \(behind) lines", detail: detail, health: .attention, route: .troubleshooting)
            : .init(title: title, value: "Up to date", detail: detail, health: .good, route: .troubleshooting)
    }

    /// Never needs attention: the island hides while Lyrics Dash is open, and some iPhones don't have one.
    @MainActor private static func island(_ engine: LyricsEngine) -> StatusItem {
        let title = "Dynamic Island"
        guard engine.running != nil else { return .init(title: title, value: "Off", health: .off, route: .troubleshooting) }
        guard let draw = DrawProbe.read(.island) else {
            return .init(title: title, value: "Hasn't updated yet", health: .off, route: .troubleshooting)
        }
        return .init(title: title, value: "Updated \(ago(draw.at))", health: .good, route: .troubleshooting)
    }

    @MainActor private static func carPlay(_ engine: LyricsEngine) -> StatusItem {
        let title = "CarPlay card"
        guard AVAudioSession.sharedInstance().currentRoute.outputs.contains(where: { $0.portType == .carAudio }) else {
            return .init(title: title, value: "CarPlay not connected", health: .off, route: .troubleshooting)
        }
        guard engine.running != nil, let card = engine.card else {
            return .init(title: title, value: "Off", health: .off, route: .troubleshooting)
        }
        // iOS only redraws the CarPlay card while it's on the CarPlay screen, so a card that's behind may just be out of
        // sight (Maps, Now Playing). Say when it last updated instead of flagging it.
        guard let draw = DrawProbe.read(.carPlay) else {
            return .init(title: title, value: "Hasn't updated yet", detail: "It updates while it's on the CarPlay screen",
                         health: .off, route: .troubleshooting)
        }
        let current = card.seq - draw.seq < 3
        return .init(title: title, value: current ? "Up to date" : "Updated \(ago(draw.at))",
                     detail: current ? "Updated \(ago(draw.at))" : "It catches up while it's on the CarPlay screen",
                     health: .good, route: .troubleshooting)
    }

    /// "Ready", never "showing": iOS draws widgets from an archive without running Lyrics Dash's code.
    @MainActor private static func widget(_ title: String, kind: String, _ engine: LyricsEngine) -> StatusItem {
        guard let probe = TimelineProbe.read(kind: kind) else {
            return .init(title: title, value: "Not added yet", health: .off, route: .settings)
        }
        let ready = "Ready \(ago(probe.at))"
        guard engine.running != nil else {
            return .init(title: title, value: "Added · shows the start button", detail: ready, health: .off, route: .settings)
        }
        // CarPlay keeps widgets still while they're on screen, so its widget steps line by line, never real time.
        let value = kind == "LyricsCarPlayWidget"
            ? "Line by line · \(LyricsTiming.label(leadMs: UserDefaults.standard.integer(forKey: "carPlayLeadMs")).lowercased())"
            : "\(probe.live ? "Real time" : "Line by line") · \(LyricsTiming.label(leadMs: UserDefaults.standard.integer(forKey: "widgetLeadMs")).lowercased())"
        // The app asks iOS to refresh widgets at every song change, so a timeline older than a song while lyrics play
        // means iOS has stopped refreshing it. ponytail: 10 min covers long songs; a longer track can flag it wrongly.
        if engine.card?.lineStart != nil, Date.now.timeIntervalSince(probe.at) > 600 {
            return .init(title: title, value: "iOS hasn't refreshed it lately", detail: ready, health: .attention, route: .settings)
        }
        return .init(title: title, value: value, detail: ready, health: .good, route: .settings)
    }

    @MainActor private static func keepRunning(_ engine: LyricsEngine) -> StatusItem {
        let title = "Keep running"
        let defaults = UserDefaults.standard
        let wanted = (audio: defaults.object(forKey: "keepAliveAudio") as? Bool ?? true,
                      location: defaults.object(forKey: "keepAliveLocation") as? Bool ?? true)
        guard engine.running != nil else {
            return wanted.audio || wanted.location
                ? .init(title: title, value: "Starts with lyrics · \(names(wanted))", health: .off, route: .keepRunning)
                : .init(title: title, value: "Off · lyrics stop when the phone locks", health: .attention, route: .keepRunning)
        }
        let now = engine.keepAliveStatus
        if !now.audio && !now.location {
            return .init(title: title, value: "Not running · lyrics stop when the phone locks", health: .problem, route: .keepRunning)
        }
        if (wanted.audio && !now.audio) || (wanted.location && !now.location) {
            let missing = names((wanted.audio && !now.audio, wanted.location && !now.location))
            return .init(title: title, value: "Kept alive by \(names(now)) only", detail: missing.prefix(1).uppercased() + missing.dropFirst() + " isn't running",
                         health: .attention, route: .keepRunning)
        }
        return .init(title: title, value: "Kept alive by \(names(now))", health: .good, route: .keepRunning)
    }

    private static func names(_ ways: (audio: Bool, location: Bool)) -> String {
        [ways.audio ? "silent audio" : nil, ways.location ? "location" : nil].compactMap { $0 }.joined(separator: " + ")
    }

    private static func ago(_ date: Date) -> String {
        let seconds = Int(Date.now.timeIntervalSince(date))
        return switch seconds {
        case ..<5: "just now"
        case ..<60: "\(seconds) s ago"
        case ..<3600: "\(seconds / 60) min ago"
        default: "\(seconds / 3600) h ago"
        }
    }
}

extension StatusItem.Health {
    var symbol: String {
        switch self {
        case .good: "checkmark.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .problem: "xmark.octagon.fill"
        case .off: "minus.circle.fill"
        }
    }

    var tone: Color {
        switch self {
        case .good: .green
        case .attention: .orange
        case .problem: .red
        case .off: .gray
        }
    }
}

/// "Everything's working", "1 thing needs attention", or "Lyrics are off".
struct StatusSummary: View {
    let items: [StatusItem]
    let running: Bool

    var body: some View {
        let count = items.filter { $0.health == .attention || $0.health == .problem }.count
        let health: StatusItem.Health = items.contains { $0.health == .problem } ? .problem : count > 0 ? .attention : running ? .good : .off
        let text = count > 0 ? "\(count) \(count == 1 ? "thing needs" : "things need") attention"
            : running ? "Everything's working" : "Lyrics are off"
        Label { Text(text) } icon: { Image(systemName: health.symbol).foregroundStyle(health.tone) }
    }
}

struct StatusRow: View {
    let item: StatusItem

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(item.value).font(.subheadline).foregroundStyle(.secondary)
                if let detail = item.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        } icon: {
            Image(systemName: item.health.symbol).foregroundStyle(item.health.tone)
        }
        .accessibilityElement(children: .combine)
    }
}
