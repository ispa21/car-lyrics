@preconcurrency import ActivityKit
import AuthenticationServices
import CoreLocation
import LyricsCore
@preconcurrency import MediaPlayer
import SwiftUI
import WidgetKit

@main
struct LyricsDashApp: App {
    @State private var engine = LyricsEngine()

    var body: some Scene {
        WindowGroup { HomeView(engine: engine) }
    }
}

/// The screens Home leads to. The card opens Appearance; the gear opens Settings, which links to the rest.
enum Route: String, Hashable { case appearance, settings, status, offline, keepRunning, troubleshooting, eventLog }

/// What iOS allows right now. Read again whenever the app comes back to the front, since these change in Settings.
struct Permissions {
    var liveActivities = ActivityAuthorizationInfo().areActivitiesEnabled
    var appleMusic = MPMediaLibrary.authorizationStatus()
    var locationDenied = [.denied, .restricted].contains(CLLocationManager().authorizationStatus)
}

/// The session screen: choose a source, start, see that it's working, fix what isn't, stop.
/// The bottom button always shows the next step, so the main action never scrolls away.
struct HomeView: View {
    let engine: LyricsEngine
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    /// Also what the widget's start button follows.
    @AppStorage("lastSource") private var source = PlaybackSourceKind.spotify
    @AppStorage("keepAliveAudio") private var keepAliveAudio = true
    @AppStorage("keepAliveLocation") private var keepAliveLocation = true
    @AppStorage("cardStyle") private var savedStyle: Data?
    @AppStorage("userPresets") private var userPresets: Data?
    @State private var path: [Route] = []
    @State private var permissions = Permissions()
    @State private var loginError: String?
    @State private var showAllPlayed = false
    @State private var statusItems: [StatusItem] = []

    /// The Start button's coral: darker than the dark-mode accent, so its white label stays readable (5.2:1).
    private static let startFill = Color(red: 199 / 255, green: 56 / 255, blue: 31 / 255)

    private enum Step { case stop, connectSpotify, allowAppleMusic, openSettings, turnOnLiveActivities, start }

    /// What the bottom button does: whatever stands between you and lyrics, else Start, else Stop.
    private var step: Step {
        if engine.running != nil { return .stop }
        if source == .spotify, !engine.spotify.connected { return .connectSpotify }
        if source == .appleMusic, permissions.appleMusic == .notDetermined { return .allowAppleMusic }
        if source == .appleMusic, permissions.appleMusic != .authorized { return .openSettings }
        if !permissions.liveActivities { return .turnOnLiveActivities }
        return .start
    }

    private var style: CardStyle { savedStyle.flatMap(CardStyle.load) ?? CardStyle() }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                notices
                cardSection
                if engine.running != nil { sessionSection } else { sourceSection }
                if engine.offline.running {
                    Section {
                        NavigationLink(value: Route.offline) {
                            LabeledContent("Saving lyrics", value: "\(engine.offline.done) of \(engine.offline.total)")
                        }
                    }
                }
                if engine.running != nil { songLists }
            }
            .navigationTitle("Lyrics Dash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button { path.append(.settings) } label: { Label("Settings", systemImage: "gearshape") }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .appearance: AppearanceView(engine: engine)
                case .settings: SettingsView(engine: engine)
                case .status: StatusView(engine: engine)
                case .offline: OfflineView(engine: engine)
                case .keepRunning: BackgroundView(engine: engine)
                case .troubleshooting: TroubleshootingView(engine: engine)
                case .eventLog: EventLogView(engine: engine)
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
        }
        // From the widget: lyricsdash://start starts the chosen source when it's ready; lyricsdash://open only opens.
        .onOpenURL { url in
            guard let host = url.host(), ["start", "open"].contains(host) else { return }
            path = []
            if host == "start", step == .start { Task { await engine.start(source) } }
        }
        .onChange(of: scenePhase) { if scenePhase == .active { permissions = Permissions() } }
        .onChange(of: source) {
            SharedKeychain.write(Data(source.rawValue.utf8), account: "source")
            WidgetCenter.shared.reloadAllTimelines()
        }
        .onChange(of: status.text) { if engine.running != nil { AccessibilityNotification.Announcement(status.text).post() } }
        #if DEBUG
        // Screenshots from the command line: simctl launch <device> com.ishanpatil.lyricsdash -demo YES -screen settings
        .task {
            if UserDefaults.standard.bool(forKey: "demo"), engine.running == nil { await engine.start(.demo) }
            if let route = UserDefaults.standard.string(forKey: "screen").flatMap(Route.init) { path = [route] }
        }
        #endif
    }

    // MARK: Sections

    /// Problems and heads-ups, each with its fix. Only shown when there's something to say.
    @ViewBuilder private var notices: some View {
        let idle = engine.running == nil
        let activitiesOff = idle && (!permissions.liveActivities || engine.issue == .liveActivitiesOff)
        let appleMusicOff = idle && source == .appleMusic && [.denied, .restricted].contains(permissions.appleMusic)
        let keepRunningOff = !keepAliveAudio && (!keepAliveLocation || permissions.locationDenied)
        let issue = engine.issue.flatMap { $0 == .liveActivitiesOff ? nil : $0 }
        if activitiesOff || appleMusicOff || keepRunningOff || loginError != nil || issue != nil {
            Section {
                if activitiesOff {
                    Notice(title: "Live Activities are off for Lyrics Dash",
                           message: "Lyrics can't show on the Lock Screen or in CarPlay until you turn them on.", tone: .red)
                }
                if appleMusicOff {
                    Notice(title: "Lyrics Dash can't see what Apple Music is playing",
                           message: "Turn on Media & Apple Music for Lyrics Dash in Settings.", tone: .red)
                }
                if let loginError {
                    Notice(title: "Spotify login didn't work", message: loginError, tone: .red) {
                        Button("Dismiss") { self.loginError = nil }
                    }
                }
                if let issue { notice(for: issue) }
                if keepRunningOff {
                    Notice(title: "Lyrics will stop when you lock your phone",
                           message: "Both ways of keeping Lyrics Dash running are off or not allowed.") {
                        Button("Keep running") { path.append(.keepRunning) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func notice(for issue: SessionIssue) -> some View {
        switch issue {
        case .liveActivitiesOff:
            EmptyView()  // shown with the permissions above
        case .startFailed(let reason):
            Notice(title: "Lyrics couldn't start", message: reason, tone: .red) { dismiss }
        case .spotifyRefused:
            Notice(title: "Spotify refused access", message: "The account needs Premium, and it has to be listed under "
                   + "User Management in the Spotify developer app.", tone: .red)
        case .spotifyLoggedOut:
            Notice(title: "Spotify login expired", message: "Connect again to keep following Spotify.", tone: .red) {
                Button("Reconnect") { Task { loginError = await engine.spotify.login(with: webAuthenticationSession) } }
            }
        case .spotifyWait(let seconds):
            Notice(title: "Spotify asked Lyrics Dash to wait",
                   message: "Checking again in \(seconds) s. Lyrics keep running on the last known timing.", symbol: "hourglass")
        case .noConnection:
            Notice(title: "No connection", message: "Lyrics keep running on the last known timing. Songs you've played "
                   + "or saved still have lyrics.", symbol: "wifi.slash")
        case .spotifyFailed(let reason):
            Notice(title: "Spotify isn't answering", message: reason)
        case .suspended(let seconds):
            Notice(title: "Lyrics were paused for \(seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min")",
                   message: "iOS stopped Lyrics Dash while the phone was locked. They're moving again now.") {
                Button("Keep running") { path.append(.keepRunning) }
                if let log = engine.diagnostics.session ?? engine.diagnostics.sessions.first { ShareLink("Share log", item: log) }
                dismiss
            }
        case .autoStopped(let minutes):
            Notice(title: "Stopped after \(minutes) minutes with nothing playing", tone: .gray, symbol: "moon.zzz.fill") { dismiss }
        }
    }

    private var dismiss: some View { Button("Dismiss") { engine.dismissIssue() } }

    /// The card: what's on the Lock Screen and CarPlay now, or your look while stopped. Tapping it opens Appearance.
    private var cardSection: some View {
        Section {
            Button { path.append(.appearance) } label: { CardMirror(state: engine.card, style: style) }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .accessibilityLabel(engine.card.map { "Lyrics card: \($0.instrumental ? $0.title : $0.current)" } ?? "Lyrics card preview")
                .accessibilityHint("Opens Appearance")
        } header: {
            if engine.running != nil {
                Label { Text(status.text) } icon: { Image(systemName: status.symbol).foregroundStyle(status.tone) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }
        } footer: {
            HStack {
                Text(CardPreset.lookName(style, mine: UserPreset.list(userPresets)))
                Spacer()
                Button("Edit card") { path.append(.appearance) }.fontWeight(.semibold)
            }
            .font(.footnote)
        }
    }

    private var status: (text: String, symbol: String, tone: Color) {
        let name = switch engine.running {
        case .appleMusic: "Apple Music"
        case .demo: "the demo song"
        default: "Spotify"
        }
        return switch engine.card?.lyrics {
        case nil: ("Starting…", "hourglass", .gray)
        case .waiting: ("Waiting for \(name)", "pause.circle.fill", .orange)
        case .searching: ("Finding lyrics…", "magnifyingglass", .gray)
        case .synced: ("Live · following \(name)", "dot.radiowaves.left.and.right", .green)
        case .missing, .unsynced: ("Live · no synced lyrics for this song", "text.badge.xmark", .gray)
        case .instrumental: ("Live · instrumental", "music.note", .gray)
        case .offline: ("Can't reach LRCLIB, retrying", "wifi.slash", .orange)
        }
    }

    private var sessionSection: some View {
        Section {
            NavigationLink(value: Route.status) {
                HStack {
                    Text("Status")
                    Spacer()
                    StatusSummary(items: statusItems, running: true).foregroundStyle(.secondary)
                }
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            }
            // The probes behind Status aren't observable, so the summary re-reads them every couple of seconds.
            .task(id: engine.running) {
                while engine.running != nil, !Task.isCancelled {
                    statusItems = StatusItem.all(engine)
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            if let card = engine.card, card.lyrics != .waiting {
                SongRow(title: card.title, artist: card.artist, lyrics: card.lyrics)
            }
            if engine.card?.lyrics == .waiting, engine.running != .demo {
                Button(engine.running == .appleMusic ? "Open Music" : "Open Spotify") {
                    openURL(URL(string: engine.running == .appleMusic ? "music://" : "spotify:")!)
                }
            }
            TimingRow(engine: engine)
        } footer: {
            Text(engine.card?.lyrics == .offline ? "Songs you've played or saved still have lyrics."
                 : "Lyrics late? Tap + until each line changes as it's sung.")
        }
    }

    private var sourceSection: some View {
        Section {
            Picker("Listen with", selection: $source) {
                Text("Spotify").tag(PlaybackSourceKind.spotify)
                Text("Apple Music").tag(PlaybackSourceKind.appleMusic)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } header: {
            Text("Listen with")
        } footer: {
            let (text, symbol, tone): (String, String, Color) = switch source {
            case .appleMusic:
                switch permissions.appleMusic {
                case .authorized: ("Apple Music access allowed", "checkmark.circle.fill", .green)
                case .notDetermined: ("Lyrics Dash will ask to see what's playing", "circle", .gray)
                default: ("Apple Music access is off", "xmark.circle.fill", .red)
                }
            default:
                engine.spotify.connected ? ("Spotify connected", "checkmark.circle.fill", .green)
                    : ("Not connected yet", "circle", .gray)
            }
            Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(tone) }
        }
    }

    @ViewBuilder private var songLists: some View {
        if !engine.upNext.isEmpty {
            Section {
                ForEach(engine.upNext.prefix(5)) { SongRow(title: $0.title, artist: $0.artist, lyrics: $0.lyrics) }
            } header: {
                Text("Up next on Spotify")
            } footer: {
                if engine.upNext.count > 5 { Text("Lyrics are saved ahead for the next \(engine.upNext.count) songs.") }
            }
        }
        if !engine.history.isEmpty {
            Section("Played") {
                ForEach(engine.history.prefix(showAllPlayed ? engine.history.count : 5)) {
                    SongRow(title: $0.title, artist: $0.artist, lyrics: $0.lyrics)
                }
                if engine.history.count > 5, !showAllPlayed {
                    Button("Show all \(engine.history.count)") { showAllPlayed = true }
                }
            }
        }
    }

    // MARK: Bottom button

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if step == .stop {
                Button { Task { await engine.stop() } } label: {
                    Label("Stop lyrics", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.primary)
            } else {
                Button { Task { await perform() } } label: {
                    Label(stepLabel.title, systemImage: stepLabel.symbol).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Self.startFill)
                HStack(spacing: 4) {
                    Text(caption).foregroundStyle(.secondary)
                    if permissions.liveActivities {
                        Button("Try the demo song") { Task { await engine.start(.demo) } }
                            .fontWeight(.semibold)
                            .foregroundStyle(.tint)
                    }
                }
                .font(.footnote)
            }
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var stepLabel: (title: String, symbol: String) {
        switch step {
        case .stop: ("Stop lyrics", "stop.fill")
        case .connectSpotify: ("Connect Spotify", "person.crop.circle.badge.plus")
        case .allowAppleMusic: ("Allow Apple Music", "music.note")
        case .openSettings: ("Open Settings", "gear")
        case .turnOnLiveActivities: ("Turn on Live Activities", "gear")
        case .start: ("Start lyrics", "play.fill")
        }
    }

    private var caption: String {
        switch step {
        case .connectSpotify: "Needs Spotify Premium."
        case .allowAppleMusic: "Lets Lyrics Dash see what's playing."
        case .openSettings: "Turn on Media & Apple Music."
        case .turnOnLiveActivities: "Lyrics show as a Live Activity."
        default: "Then lock your phone."
        }
    }

    private func perform() async {
        switch step {
        case .stop: await engine.stop()
        case .connectSpotify: loginError = await engine.spotify.login(with: webAuthenticationSession)
        case .allowAppleMusic: _ = await AppleMusic.authorize(); permissions = Permissions()
        case .openSettings, .turnOnLiveActivities: openURL(URL(string: UIApplication.openSettingsURLString)!)
        case .start: loginError = nil; await engine.start(source)
        }
    }
}

/// The lyrics card as it looks now: what's on the Lock Screen and CarPlay while running, your look with a sample line
/// otherwise. It's the same LyricsCard, so it keeps the card's rules: no animation, and the lyric is never cut off.
struct CardMirror: View {
    let state: LyricsActivityAttributes.ContentState?
    let style: CardStyle

    var body: some View {
        Group {
            if let state {
                LyricsCard(state: state)
            } else {
                TimelineView(.periodic(from: .now, by: 4)) { _ in LyricsCard(state: .sample(style)) }  // loops the sample's bar
            }
        }
        .frame(height: 150)
        .clipShape(.rect(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(.secondary.opacity(0.3), lineWidth: 1) }  // edge for black cards on black
    }
}

/// A problem or heads-up on Home: what happened, what it means, and at most a few fixes.
struct Notice<Actions: View>: View {
    let title: String
    var message: String? = nil
    var tone: Color = .orange
    var symbol = "exclamationmark.triangle.fill"
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label { Text(title).font(.subheadline.weight(.semibold)) } icon: { Image(systemName: symbol).foregroundStyle(tone) }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            HStack(spacing: 18) { actions() }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
        .listRowBackground(tone.opacity(0.12))
    }
}

extension Notice where Actions == EmptyView {
    init(title: String, message: String? = nil, tone: Color = .orange, symbol: String = "exclamationmark.triangle.fill") {
        self.init(title: title, message: message, tone: tone, symbol: symbol) { EmptyView() }
    }
}

/// "Show lines early", applied at once so you can watch the card while you adjust it.
struct TimingRow: View {
    let engine: LyricsEngine
    @AppStorage("leadMs") private var leadMs = 0

    var body: some View {
        Stepper(value: $leadMs, in: -1000...3000, step: 100) {
            LabeledContent("Timing", value: LyricsTiming.label(leadMs: leadMs))
        }
        .onChange(of: leadMs) { engine.refreshCard() }
    }
}

struct SongRow: View {
    let title: String
    let artist: String
    let lyrics: LyricsAvailability?  // nil: not checked yet

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Label(lyrics?.label ?? "Check", systemImage: lyrics?.symbol ?? "magnifyingglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(lyrics?.tone ?? .accentColor)
        }
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }
}

extension LyricsAvailability {
    /// In the app's lists: green when synced, orange while it may still sort itself out, grey for information.
    /// (The card keeps its own badge colours.)
    var tone: Color {
        switch self {
        case .synced: .green
        case .searching, .offline: .orange
        case .waiting, .unsynced, .missing, .instrumental: .gray
        }
    }

    var symbol: String {
        switch self {
        case .synced: "checkmark.circle.fill"
        case .searching: "ellipsis.circle"
        case .offline: "wifi.slash"
        case .instrumental: "music.note"
        case .unsynced: "text.alignleft"
        case .missing: "xmark.circle"
        case .waiting: "clock"
        }
    }
}
