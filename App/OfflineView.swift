import AuthenticationServices
import LyricsCore
@preconcurrency import MediaPlayer
import SwiftUI

/// Lyrics for driving without signal: what's saved, checking a song, saving whole libraries over Wi-Fi, and Road trip mode.
struct OfflineView: View {
    let engine: LyricsEngine
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @AppStorage("roadTrip") private var roadTrip = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var appleMusic = MPMediaLibrary.authorizationStatus()
    @State private var query = ""
    @State private var results: [NowPlaying] = []
    @State private var checked: [String: LyricsAvailability] = [:]
    @State private var searching = false

    private var offline: OfflineLyrics { engine.offline }

    var body: some View {
        Form {
            if searching || !results.isEmpty {
                Section {
                    if searching { ProgressView() }
                    ForEach(results, id: \.trackID) { song in
                        Button { Task { await check(song) } } label: {
                            SongRow(title: song.title, artist: song.artist, lyrics: checked[song.trackID])
                        }
                        .tint(.primary)
                    }
                } header: {
                    Text("Check a song")
                } footer: {
                    Text("Tap a song to see if LRCLIB has synced lyrics for it. It's the same lookup used while it plays.")
                }
            }
            Section("On this phone") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(offline.usage.songs.formatted()) songs").font(.title2.weight(.bold))
                    Text("\(offline.usage.bytes.formatted(.byteCount(style: .file))) · every song you play is saved too")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if offline.running || !offline.summary.isEmpty {
                Section(offline.label) {
                    if offline.running {
                        ProgressView(value: Double(offline.done), total: Double(max(offline.total, 1)))
                        Text(offline.waitingForWiFi ? "Waiting for Wi-Fi…" : "\(offline.done) of \(offline.total) · \(offline.current)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("Stop", role: .destructive) { offline.stop() }
                    } else {
                        Text(offline.summary).font(.footnote)
                    }
                }
            }
            Section {
                if [.denied, .restricted].contains(appleMusic) {
                    LabeledContent("Apple Music library") {
                        Button("Open Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                    }
                } else {
                    Button("Apple Music library") {
                        Task {
                            if await AppleMusic.authorize() { offline.save("Apple Music library") { AppleMusic.librarySongs() } }
                            appleMusic = MPMediaLibrary.authorizationStatus()
                        }
                    }
                }
                if !engine.spotify.connected {
                    LabeledContent("Spotify Liked Songs and playlists") {
                        Button("Connect Spotify") { Task { error = await engine.spotify.login(with: webAuthenticationSession) } }
                    }
                } else if engine.spotify.canReadLibrary {
                    Button("Spotify Liked Songs") { offline.save("Spotify Liked Songs") { try await engine.spotify.likedSongs() } }
                    NavigationLink("Spotify playlists") { PlaylistsView(engine: engine) }
                } else {
                    Button("Allow Liked Songs and playlists") { Task { error = await engine.spotify.login(with: webAuthenticationSession) } }
                }
            } header: {
                Text("Save ahead · Wi-Fi only")
            } footer: {
                Text(engine.spotify.connected && !engine.spotify.canReadLibrary
                     ? "Spotify asks you to log in once more to let Lyrics Dash read your Liked Songs and playlists."
                     : "Waits while on mobile data and skips songs already saved. Keep Lyrics Dash open until it finishes; the screen stays on.")
            }
            .disabled(offline.running)
            Section {
                Toggle("Road trip mode", isOn: $roadTrip)
            } header: {
                Text("Spotify queue")
            } footer: {
                Text("While lyrics run, saves the next 20 songs in your Spotify queue instead of 10, even on mobile data, "
                     + "so a playlist keeps its lyrics through dead zones.")
            }
            Section {
                Button("Delete saved lyrics", role: .destructive) { confirmDelete = true }
                    .disabled(offline.usage.songs == 0 || offline.running)
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .searchable(text: $query, prompt: "Check a song")
        .autocorrectionDisabled()
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: query) { if query.isEmpty { results = []; checked = [:] } }
        .navigationTitle("Offline lyrics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { offline.refreshUsage() }
        .onChange(of: scenePhase) { appleMusic = MPMediaLibrary.authorizationStatus() }
        .confirmationDialog("Delete all saved lyrics?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete \(offline.usage.songs) songs' lyrics", role: .destructive) { offline.deleteAll() }
        } message: {
            Text("Songs will need signal again to get their lyrics.")
        }
    }

    /// Song search by title, artist or both. Results are checked one at a time, by tapping.
    /// They can't be saved: search IDs don't match Spotify's or Apple Music's, so a saved copy would never be found.
    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        do { results = try await LyricsLookup.search(text); error = nil }
        catch { self.error = "Search failed: \(error.localizedDescription)" }
        searching = false
    }

    private func check(_ song: NowPlaying) async {
        guard checked[song.trackID] != .searching else { return }
        checked[song.trackID] = .searching
        checked[song.trackID] = await LyricsLookup.find(song).availability
    }
}

/// The user's Spotify playlists whose songs can be read, each with a button to save its lyrics.
struct PlaylistsView: View {
    let engine: LyricsEngine
    @State private var playlists: [SpotifyLibrary.Playlist]?
    @State private var error: String?

    var body: some View {
        List {
            if let playlists {
                Section {
                    ForEach(playlists) { playlist in
                        Button {
                            engine.offline.save(playlist.name) { try await engine.spotify.playlistSongs(playlist.id) }
                        } label: {
                            LabeledContent(playlist.name, value: "\(playlist.total) songs")
                        }
                        .tint(.primary)
                    }
                } footer: {
                    Text("Tap a playlist to save its lyrics; progress shows on the previous screen. Spotify only lets apps read playlists you made or collaborate on, so ones you only follow aren't listed.")
                }
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Spotify playlists")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(engine.offline.running)
        .task {
            do { playlists = try await engine.spotify.playlists() }
            catch { self.error = "Couldn't load playlists: \(error.localizedDescription)" }
        }
    }
}
