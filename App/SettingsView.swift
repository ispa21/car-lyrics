import AuthenticationServices
import LyricsCore
@preconcurrency import MediaPlayer
import SwiftUI

/// Everything set once: music accounts, timing, the card, offline lyrics, keeping running, the widgets, and help.
/// Each row shows its current state, so it rarely needs opening.
struct SettingsView: View {
    let engine: LyricsEngine
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @AppStorage("liveWidget") private var liveWidget = true
    @AppStorage("carPlayLeadMs") private var carPlayLeadMs = 0
    @AppStorage("widgetLeadMs") private var widgetLeadMs = 0
    @AppStorage("userPresets") private var userPresets: Data?
    @AppStorage("keepAliveAudio") private var keepAliveAudio = true
    @AppStorage("keepAliveLocation") private var keepAliveLocation = true
    @AppStorage("cardStyle") private var savedStyle: Data?
    @State private var appleMusic = MPMediaLibrary.authorizationStatus()
    @State private var error: String?
    @State private var confirmDisconnect = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Spotify", value: engine.spotify.connected ? "Connected" : "Not connected")
                if !engine.spotify.connected {
                    Button("Connect Spotify") { Task { error = await engine.spotify.login(with: webAuthenticationSession) } }
                } else {
                    if !engine.spotify.canReadLibrary {
                        Button("Allow Liked Songs and playlists") { Task { error = await engine.spotify.login(with: webAuthenticationSession) } }
                    }
                    Button("Disconnect Spotify", role: .destructive) { confirmDisconnect = true }
                }
                LabeledContent("Apple Music", value: appleMusic == .authorized ? "Allowed" : appleMusic == .notDetermined ? "Not asked yet" : "Not allowed")
                if appleMusic == .notDetermined {
                    Button("Allow Apple Music") {
                        Task { _ = await AppleMusic.authorize(); appleMusic = MPMediaLibrary.authorizationStatus() }
                    }
                } else if appleMusic != .authorized {
                    Button("Open Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                }
                if let error { Text(error).foregroundStyle(.red) }
            } header: {
                Text("Music")
            } footer: {
                Text("Spotify needs a Premium account. Apple Music needs no login.")
            }

            Section {
                NavigationLink(value: Route.appearance) {
                    LabeledContent("Card appearance", value: CardPreset.lookName(savedStyle.flatMap(CardStyle.load) ?? CardStyle(),
                                                                                 mine: UserPreset.list(userPresets)))
                }
                TimingRow(engine: engine)
                NavigationLink(value: Route.offline) {
                    LabeledContent("Offline lyrics", value: engine.offline.running ? "Saving…" : "\(engine.offline.usage.songs.formatted()) songs")
                }
            } header: {
                Text("Lyrics")
            } footer: {
                Text("Lyrics late? Tap + until each line changes as it's sung.")
            }

            Section("When locked") {
                NavigationLink(value: Route.keepRunning) {
                    LabeledContent("Keep running", value: KeepAliveSummary.text(audio: keepAliveAudio, location: keepAliveLocation))
                }
            }

            Section {
                Toggle("Real-time lines", isOn: $liveWidget)
                    .onChange(of: liveWidget) { engine.refreshCard() }
                // Can go later too: the real-time widget has no lag, so the Live Activity's "lines early" can make it early.
                Stepper(value: $widgetLeadMs, in: -3000...3000, step: 100) {
                    LabeledContent("Home Screen widget", value: LyricsTiming.label(leadMs: widgetLeadMs))
                }
                .onChange(of: widgetLeadMs) { engine.refreshCard() }
                Stepper(value: $carPlayLeadMs, in: 0...5000, step: 100) {
                    LabeledContent("CarPlay widget", value: LyricsTiming.label(leadMs: carPlayLeadMs))
                }
                .onChange(of: carPlayLeadMs) { engine.refreshCard() }
            } header: {
                Text("Widgets")
            } footer: {
                Text("Real-time lines change Home Screen and StandBy widget lines exactly on time; turn it off if the widget stops moving. "
                     + "Move each widget earlier or later until its lines change as they're sung. The Lyrics for CarPlay widget "
                     + "switches lines late, so it usually needs to be earlier.")
            }

            Section("Help") {
                NavigationLink("Status", value: Route.status)
                NavigationLink("Troubleshooting", value: Route.troubleshooting)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Disconnect Spotify?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { engine.spotify.disconnect() }
        } message: {
            Text("You'll need to log in again to follow Spotify.")
        }
        .onChange(of: scenePhase) { appleMusic = MPMediaLibrary.authorizationStatus() }
    }
}

extension Spotify {
    /// Logs in and returns what went wrong, for the screen to show; nil when it worked or you cancelled.
    func login(with session: WebAuthenticationSession) async -> String? {
        do {
            try await connect(with: session)
            return nil
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
