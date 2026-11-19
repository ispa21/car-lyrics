# Lyrics Dash: developer notes

Setup: see [SETUP.md](SETUP.md). Why it's built this way: [FEASIBILITY.md](FEASIBILITY.md).

Synced lyrics on CarPlay through an iOS 26+ Live Activity. See [FEASIBILITY.md](FEASIBILITY.md) for why it's done this way.

## Put it on your iPhone
1. `xcodegen` in this folder, then open `LyricsDash.xcodeproj`. Rerun `xcodegen` after adding files.
2. Connect the iPhone by USB and tap **Trust** on the phone. The phone needs iOS 26 or later.
3. On the iPhone, turn on Settings → Privacy & Security → **Developer Mode**. The phone restarts.
4. In Xcode, pick your iPhone as the run destination and press **Run**. Signing uses the team in your `Local.xcconfig` (see SETUP.md step 1b). If Xcode says a bundle ID is taken, change `com.ishanpatil` in `project.yml`.
5. With a free Apple ID, trust the developer on the first launch: Settings → General → VPN & Device Management. A free-account build expires after **7 days**; press Run again to renew it. A paid account lasts a year.

After the first wired run you can deploy over Wi-Fi: Xcode → Window → Devices and Simulators → "Connect via network".

## Milestone 1 test (go/no-go)
1. Connect to CarPlay (the car, or Simulator → I/O → External Displays → CarPlay).
2. Open Lyrics Dash and tap **Try the demo song** (under the button at the bottom of Home). It's a 60-second original test song that loops.
3. Lock the phone. Watch the card on the CarPlay Home Screen.
4. **Pass:** each line changes on time for at least 3 minutes, and the small `#seq` number never skips. **Fail:** lines lag, skip, or freeze. Note it in FEASIBILITY.md; the fallback is a widget, or a server sending push updates.

## Real Spotify
1. Go to [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard), log in, and choose **Create app**.
   - Redirect URI: `lyricsdash://callback`
   - API: tick **Web API**
   - Save.
2. Open the app's **Settings** and copy the **Client ID** into `Local.xcconfig` as `SPOTIFY_CLIENT_ID`. It isn't a secret, but it's tied to your Spotify app.
3. Spotify requires the developer app's owner to have **Premium**. If you get a 403, add your Spotify email under **User Management**.
4. Run from Xcode. On the phone: **Connect Spotify**, log in, **Start with Spotify**, play a song, then lock the phone.

Lyrics come from LRCLIB. Songs without synced lyrics there show "No synced lyrics for this song".

## Apple Music
No setup. Run from Xcode, tap **Start with Apple Music**, allow access when asked, play a song in the Music app, then lock the phone. It reads the Music app's player on the phone, so no login or network is needed except for the lyrics lookup.

## YouTube Music and other apps
Not supported, by decision (2026-10-11): Lyrics Dash follows Spotify and Apple Music only. iOS gives apps no way to read what another app is playing, so the only route would be listening through the microphone with ShazamKit (as Dynamic Lyrics' "Shazam mode" does). That was rejected because turning the mic on in CarPlay likely switches the car's audio to call quality.

## Background (lyrics keep moving after you leave the app)
iOS suspends apps in the background, and a Live Activity can't advance on its own. The app stays running with one or both of these, chosen in Settings → **Keep running** (both on by default):
- **Silent audio:** an inaudible looping track mixed with other audio. Spotify isn't interrupted and stays the Now Playing app. It restarts after calls, Siri and alarms, after audio route changes, and after iOS audio services reset; a check on every poll restarts it if it stopped anyway.
- **Location:** low-accuracy updates (about 3 km, so usually no GPS) with automatic pausing turned off, so traffic and parking don't let iOS suspend the app.

**Pause and play:** neither source says when you pause, so the app asks: Apple Music twice a second (free, on the phone), Spotify every 2 s. For Spotify it also reads iOS's "is another app playing audio" flag twice a second and asks Spotify immediately when it flips; whether iOS updates that flag in the background is unverified (the log shows "Music started/stopped on the phone" when it fires).

Both stop on **Stop** or once nothing has played for the time chosen on the Keep running screen (2, 5, 10 or 20 minutes; 20 by default). If an expected update doesn't arrive (the app was killed or suspended anyway), the card dims and says "Lyrics paused · open Lyrics Dash" instead of showing a wrong line. The log records locks, background moves, pauses longer than 3 s and keep-alive trouble.

Not verified on a device yet: that low-accuracy location alone keeps the app running, and that CarPlay doesn't turn the radio down while silent audio plays.

**Test:** open the app from its icon (not Xcode, whose debugger stops iOS suspending it), start a song, lock the phone or switch apps for 10 minutes, then check the card stayed in step and the log has no "App was paused" lines. Repeat with only one option on, and once with a phone call in the middle.

## Offline (tunnels, dead zones)
- **The playing song** keeps its lyrics: they run on the phone's clock, and a failed Spotify check while music was playing doesn't count towards the inactivity stop.
- **Saved lyrics:** every song with synced lyrics (or marked instrumental) is saved on the phone (`LyricsDiskCache`, Application Support/Lyrics, a few KB per song), so songs played before work with no network, even after a relaunch. "Not found" isn't saved, since LRCLIB may add it later.
- **Ahead of time:** lyrics for the next 10 songs in the Spotify queue are fetched and saved while there's signal; **Road trip mode** (Settings → Offline lyrics) raises that to 20, the most Spotify's queue lists.
- **Save ahead** (Settings → Offline lyrics, `OfflineLyrics`): saves lyrics in bulk for the Apple Music library, Spotify Liked Songs, or chosen Spotify playlists. Wi-Fi only (waits on mobile data), skips songs already saved, about 2 songs a second, with the screen kept on. Spotify playlists are limited to ones the user made or collaborates on, the only ones Spotify lets apps read since February 2026. Liked Songs and playlists need the `user-library-read`, `playlist-read-private` and `playlist-read-collaborative` scopes, so logins from before they were added are asked to connect again once.
- **Storage:** a few KB per song (about 3 MB per 1,000 songs), shown on the Offline lyrics screen with a Delete button.
- **Still needs signal:** noticing that Spotify moved to the next song, paused or skipped (its state only comes over the web), and lyrics for songs never played or queued. Apple Music's position is read on the phone, so it follows offline; only never-seen songs lack lyrics.

## Lyrics widget
A WidgetKit widget (small, medium, Lock Screen rectangular and circular) shows the same card on the Home Screen, Lock Screen, StandBy and the CarPlay widgets page. The app saves the song's line times (`WidgetSnapshot`) and reloads the widget on every change it can't predict (song, play/pause, seek, lyrics, art, appearance); On the Home Screen and StandBy (small and medium) the widget is real time: each timeline entry carries the next minute of lyrics, one transparent card per stretch, and each card is masked by a slice of a huge ring that WidgetKit's clock-hand rotation (the private effect behind the Clock widget's hands) turns past the card exactly while that stretch is sung, so lines wipe in left to right on time with no reloads (`Widget/ClockHand.swift`, `LiveSchedule` in LyricsCore). Since the iOS 26.1 SDK WidgetKit only applies that effect for Apple's Clock through `View._clockHandRotationEffect`, so the widget decodes the modifier type directly. CarPlay keeps widgets still while they're on screen (no animation; only timeline entry switches, and those land late), so CarPlay gets its own **Lyrics for CarPlay** widget that steps through one entry per line, switched earlier by the app's **CarPlay widget** timing setting, the same approach as Dynamic Lyrics' separate CarPlay delay. For lyrics that change exactly on time in the car, use the Live Activity. The Lock Screen widgets, or all of them with **Real-time lines** off (Settings → Widgets), step through one timeline entry per line, which iOS draws about 2 s apart at best. While Lyrics Dash isn't running, the widget is a "Start lyrics" button (`lyricsdash://start`) for the source picked on Home; the app saves that choice in the shared keychain (`source`) so the widget can name it.

The snapshot travels through a shared keychain item, not an App Group: the free Apple ID's signing profile allows any keychain group under the team (`<your team ID>.*`), so both targets list `<team>.com.ishanpatil.lyricsdash.shared`.

## CarPlay Simulator (no car)
Download "Additional Tools for Xcode 27" from [developer.apple.com/download/all](https://developer.apple.com/download/all/). Open the disk image, then **Hardware → CarPlay Simulator**. Plug in the iPhone, unlock it, and tap **Allow** for CarPlay.

## Layout
- `LyricsCore/`: Swift package with the LRC parser and line sync. Test with `cd LyricsCore && swift test`.
- `App/`: the iPhone app. `LyricsEngine` (polling, lyrics, Live Activity updates), `Spotify` (PKCE login, Keychain), `AppleMusic` (Music app player), `SilentAudio` and `LocationKeepAlive` (background keep-alives, chosen in `BackgroundView`), `DemoSong`. Screens: `HomeView` (in `LyricsDashApp.swift`), `SettingsView`, `AppearanceView`, `OfflineView`, `BackgroundView` (Keep running), `StatusView`, and `TroubleshootingView` (in `UpdateDiagnostics.swift`). Debug builds take `-demo YES` and `-screen <route>` (plus `-panel Layout` for Appearance) as launch arguments, for screenshots from `simctl launch`.
- `App/Assets.xcassets`: the app icon, with square corners (iOS rounds them).
- `Widget/`: the Live Activity UI. `.supplementalActivityFamilies([.small])` is the CarPlay presentation.
- `Shared/`: compiled into both targets. The activity data model with `CardStyle`, `LyricsCard`, which the widget renders and the app's Home and Appearance screens preview, and `Artwork`, which shrinks album art to 12×12 so the blurred backdrop fits inside each 4 KB update, and `WidgetSnapshot`, what the lyrics widget reads.
