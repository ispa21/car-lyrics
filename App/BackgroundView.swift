import CoreLocation
import SwiftUI

/// Keep running: how Lyrics Dash stays alive while the phone is locked, and when it stops by itself.
struct BackgroundView: View {
    let engine: LyricsEngine
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @AppStorage("keepAliveAudio") private var audio = true
    @AppStorage("keepAliveLocation") private var location = true
    @AppStorage("idleMinutes") private var idleMinutes = 20
    @State private var locationDenied = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $audio) {
                    option("Silent audio", "Plays silence alongside your music. Your car's controls keep working.")
                }
                Toggle(isOn: $location) {
                    option("Location", "Approximate, the way navigation apps keep running. Shows the location arrow.")
                }
                if location && locationDenied {
                    LabeledContent {
                        Button("Open Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                    } label: {
                        Label("Location is off for Lyrics Dash", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                if engine.running != nil {
                    // The keep-alives aren't observable, so this checks them every couple of seconds.
                    TimelineView(.periodic(from: .now, by: 2)) { _ in
                        let now = engine.keepAliveStatus
                        LabeledContent("Now", value: "Silent audio \(now.audio ? "on" : "off") · location \(now.location ? "on" : "off")")
                    }
                }
            } header: {
                Text("Keep lyrics moving when locked")
            } footer: {
                Text(advice)
            }
            Section {
                Picker("When nothing plays for", selection: $idleMinutes) {
                    ForEach([2, 5, 10, 20], id: \.self) { Text("\($0) min").tag($0) }
                }
            } header: {
                Text("Auto-stop")
            } footer: {
                Text("Lyrics Dash stops and the lyrics card closes. Shorter saves battery; you can always stop sooner.")
            }
            Section {
                DisclosureGroup("How this works") {
                    Group {
                        Text("iOS pauses apps you aren't using. Without one of these, the lyrics on your Lock Screen and in CarPlay stop moving once you switch apps or lock your phone.")
                        Text("Silent audio plays an inaudible track alongside your music. Spotify isn't interrupted and still works with your car's controls. A phone call pauses it; it restarts by itself afterwards.")
                        Text("Location uses your rough location to stay running. It uses little battery, and almost none while Google Maps is open.")
                        Text("Both stop when you tap Stop, or when nothing has played for the time set above.")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Keep running")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { checkLocation() }
        .onChange(of: scenePhase) { checkLocation() }
        .onChange(of: audio) { engine.updateKeepAlive() }
        .onChange(of: location) { engine.updateKeepAlive() }
    }

    private func checkLocation() {
        locationDenied = [.denied, .restricted].contains(CLLocationManager().authorizationStatus)
    }

    private var advice: String {
        switch (audio, location) {
        case (true, true): "Both on is the most reliable: if a call or an audio change stops one, the other keeps going."
        case (true, false): "If your car turns the radio down while Lyrics Dash is running, use Location instead."
        case (false, true): "Works through phone calls and never touches your car's audio."
        case (false, false): "Lyrics will stop moving when you leave the app or lock your phone."
        }
    }

    private func option(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// One phrase for the Keep running row in Settings.
enum KeepAliveSummary {
    static func text(audio: Bool, location: Bool) -> String {
        switch (audio, location) {
        case (true, true): "Recommended"
        case (true, false): "Silent audio only"
        case (false, true): "Location only"
        case (false, false): "Off"
        }
    }
}
