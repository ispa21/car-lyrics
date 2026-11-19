# Synced lyrics on CarPlay (and later Android Auto): feasibility

2026-10-10. Researched against official Apple, Spotify, and Android docs where they were reachable. Each claim is labelled **[verified]** (official source, quoted below), **[reported]** (credible third-party source), or **[assumption]** (not yet checked).

## Verdict

**Feasible on a real CarPlay screen, without Apple granting a CarPlay entitlement, by showing the lyrics as an iOS 26+ Live Activity.** The current lyric line is pushed into the Live Activity as playback moves on.

Two caveats:
- **CarPlay templates are off the table.** A lyrics-only app can't get any of the CarPlay template entitlements.
- **The real risk is update cadence.** Nobody has confirmed that CarPlay shows a Live Activity updated every 2–6 seconds, from a backgrounded app, promptly and without throttling. That is the first thing to test.

Someone else already ships this, which is evidence it works. Musixmatch added Live Activity lyrics on CarPlay for Apple Music and Spotify in May 2026, priced at $35.99/yr **[reported]**. Dynamic Lyrics does the same through a CarPlay widget **[reported]**. If you'd rather buy than build, those exist. If you can use Apple Music, iOS 26 already shows its synced lyrics natively in CarPlay **[reported]**.

## Approaches compared

| # | Approach | Real car, personal build | Blocker |
| --- | --- | --- | --- |
| A | **Live Activity on the CarPlay Home Screen** (iOS 26+) | **Yes** | Update cadence and background execution are unverified, so they get their own milestone |
| B | WidgetKit widget on the CarPlay widgets page (iOS 26+) | Likely, but weaker | Apple's guidance: timeline entries "at least about 5 minutes apart", and 40–70 reloads a day **[verified]**. That fits poorly with per-line updates and a reload on every song. It's a fallback. |
| C | CarPlay app with templates (for example a CPListTemplate showing the current line) | **No** (simulator only) | Every template category needs an entitlement that Apple grants after review. A lyrics app doesn't fit audio, communication, EV charging, navigation, parking, or quick food ordering **[verified]**. |
| D | Put the lyric into CarPlay's Now Playing title | **No** with Spotify | Only the app producing the audio owns its Now Playing info. Spotify plays the audio. **[assumption]**, standard MediaPlayer behaviour |
| E | Navigation app that draws lyrics on its map window | **No** | Needs the maps entitlement, and the guidelines limit that window to maps **[verified]** for the entitlement, **[assumption]** for the content rule |

## Evidence (official)

- **CarPlay entitlements.** Apple's "Requesting CarPlay Entitlements": "you must request the appropriate entitlement for your app's category… Apple reviews each application using predefined criteria." The doc lists `carplay-audio`, `-communication`, `-charging`, `-maps`, `-parking`, and `-quick-ordering`. To test: "use a simulator… choose I/O > External Displays > CarPlay."
- **Live Activities in CarPlay.** ActivityKit overview: "In CarPlay, it appears on the Home Screen." From "Displaying live data with Live Activities":
  - activities last "up to eight hours";
  - data "can't exceed a combined size of 4 KB";
  - "You can update or end a Live Activity from your app while it runs in the background";
  - "your app needs to be in the foreground to start a Live Activity";
  - "Buttons and toggles on Live Activities don't perform actions in CarPlay."

  Neither page mentions any CarPlay entitlement for Live Activities.
- **CarPlay opt-in.** WWDC25 "What's new in widgets": opt in with `.supplementalActivityFamilies([.small])`, and "In iOS 26, widgets are available in all CarPlay cars."
- **Widget budget.** "Keeping a widget up to date": "40 to 70 refreshes" a day, and "entries that are at least about 5 minutes apart". Reloads don't count while the app "has an active audio or navigation session".
- **Spotify playback.**
  - Endpoint: `GET /v1/me/player/currently-playing`, scope `user-read-currently-playing`. It returns `progress_ms`, `is_playing`, `item.duration_ms`, `name`, `artists`, and `album`.
  - `timestamp` is when the playback state last changed, not when `progress_ms` was sampled.
  - February 2026 rules: "All Development Mode apps require the app owner to have an active Spotify Premium subscription"; new apps get 5 users. The player endpoints are not on the removed list.
- **Spotify policy (risk, not a technical blocker).**
  - III.5: "Do not create any product or service which is integrated with streams or content from another service."
  - III.6: "Do not synchronize any sound recordings with any visual media, including any advertising, film, …"

  Neither clause mentions lyrics. A Spotify community moderator said a separate screen showing third-party lyrics, with no Spotify content on it, would be acceptable. That isn't binding. For a single-user personal build the practical risk is low; for distribution it needs an answer from Spotify. The Spotify Web API offers no lyrics.
- **Lyrics source.** LRCLIB (`lrclib.net/api/get` and `/api/search`) is free, needs no key, and returns `syncedLyrics` in LRC format. Caraoke already uses it in production. The lyrics themselves stay copyrighted by their rights holders, so this is fine for personal use and a licensing question for distribution. **[assumption]** Its terms page renders client-side and wasn't readable here.
- **Android Auto.** The official category table covers media, messaging, navigation, POI, IoT, weather, and parked-only video and games. None of them is lyrics. Car App Library templates (List, Pane, Message, and others) serve the non-media categories **[verified]**. Personal apps can run on a real car through Android Auto's developer settings ("Unknown sources") **[reported]**. Template refresh limits are not verified yet.

## Recommended architecture (smallest viable)

```
iPhone (iOS 26+)
 ├─ App (SwiftUI)
 │   ├─ PlaybackSource ── SpotifyWebAPI: PKCE login, polls currently-playing
 │   │                    (later: MusicKit SystemMusicPlayer for Apple Music, no network)
 │   ├─ LyricsProvider ── LRCLIB get → search fallback, on-device cache
 │   ├─ LyricsCore ────── LRC parser + line sync + next-change scheduling   ← BUILT
 │   └─ Updater ───────── at each LyricSync.nextChange: activity.update(current, next line)
 └─ Widget extension ──── Live Activity UI, .supplementalActivityFamilies([.small]) → CarPlay
```

- **Polling.** The app polls Spotify adaptively, not on a fixed fast loop:
  - at each predicted track end;
  - about every 10 s to catch seeks, pauses, and skips;
  - immediately when the app comes back to the foreground.

  Between polls, the line position is extrapolated locally (`PlaybackSnapshot.position(at:)`).
- **Background execution** is the open design choice. The app has to keep issuing updates while the phone is locked and Spotify is playing. The options:
  1. **Silent audio session that mixes with other audio (`.mixWithOthers`):** keeps the app alive with no server. It's fine for personal builds; App Review would reject it. **Built, together with low-accuracy background location (2026-10-11); the user picks either or both.**
  2. **Server polling Spotify and sending APNs `liveactivity` pushes:** suitable for App Store distribution, but needs a server, an APNs key, and room in the push budget.
  3. **BGTaskScheduler:** minutes-level granularity, so it's insufficient.

## Personal-only build (decided 2026-10-10)
- **Sideloading from Xcode does not unlock a CarPlay app.** On-device testing of template apps still needs Apple's entitlement approval. Only the simulator works without it ([react-native-carplay notes](https://github.com/birkir/react-native-carplay/blob/master/CarPlay.md), [Codemagic: missing CarPlay capability](https://help.codemagic.io/articles/1909148758-why-does-my-build-fail-with-provisioning-profile-doesn-t-include-the-carplay-driving-task-app-capability)). The Live Activity route stays the plan.
- **What personal-only allows:**
  - the silent-audio keep-alive;
  - no App Review constraints;
  - a free Apple ID, re-signed every 7 days;
  - Spotify Development Mode for one user, still with the Premium requirement.
- **Android Auto gets easier.** Caraoke's companion already reads Spotify through Android's media session, with no Spotify API or Premium needed. It also already does LRCLIB lookups and romanization. M6 can reuse that code and add a sideloaded Car App Library screen.

## Earliest blockers, in order

1. **Local environment (found now).** Xcode 27's simulator components aren't installed. `xcodebuild` reports "CoreSimulator is out of date… Simulator device support disabled", and `simctl` needs authorization to install packages. Fix: open Xcode and accept the component install, or run `sudo xcodebuild -runFirstLaunch`. Until then, neither the CarPlay Simulator nor device deployment works.
2. **Live Activity cadence on CarPlay** (Milestone 1). If updates from a backgrounded app get throttled or arrive late, fall back to B (widget) or to option 2 above.
3. **Background survival on a real, locked iPhone for a full drive** (Milestone 2).

## Tools, accounts, permissions

| Need | Status |
| --- | --- |
| Xcode 27 / Swift 6.4 / iOS 26.5 simulator runtime | Installed. Simulator components need the fix in blocker 1. |
| Apple ID for on-device builds | Needed. A paid Developer Program ($99/yr) avoids free-team limits: 7-day profiles, and some capabilities may be unavailable **[assumption]**. No CarPlay entitlement is needed for route A. |
| `NSSupportsLiveActivities` in the app's Info.plist, plus a widget extension | Configured in Milestone 1 |
| Spotify developer app (Development Mode), the owner's Spotify **Premium**, redirect URI, scope `user-read-currently-playing` | Needed for Milestone 3 |
| iPhone on iOS 26+ and a CarPlay car | Needed for Milestones 2 and 5 |
| Android Auto: Android 9+ phone, Android Studio, Desktop Head Unit, AA developer mode with "Unknown sources" | Needed for Milestone 6 |

## Milestones (each independently testable)

| # | Deliverable | Pass condition |
| --- | --- | --- |
| **M0** | `LyricsCore`: LRC parser, line selection, next-change scheduling, playback extrapolation | `swift test` passes, and it builds for the iOS Simulator. **Done: 8/8 tests pass.** |
| **M1 (gate)** | Spike app with a fixture song: start a Live Activity, background the app, update per line on a timer. **Built:** App/, Widget/; compiles for the simulator and a device, not yet run (see README) | The CarPlay Simulator shows every line change within ±0.5 s for 3 minutes, with no throttling logged. If this fails, stop and switch routes. |
| M2 | Background survival on a device | iPhone locked, Spotify playing, 60 minutes: updates keep flowing and Spotify audio is unaffected |
| M3 | Spotify `PlaybackSource`. **Built**, untested on device | Login works; line drift ≤ 300 ms against Spotify's own lyrics view; pause, seek, skip, ads, and podcasts are handled |
| M4 | LRCLIB provider and cache. **Built** (memory cache), untested on device | Exact and search matching, with title, artist, album, and duration within ±2 s; offline replay comes from cache |
| M5 | Real car | A full drive works end to end; legible at a glance |
| M6 | Android Auto extension | Sideloaded Car App Library app showing current and next line. Verify refresh throttling in the Desktop Head Unit first. Logic is shared through a Kotlin port, or Caraoke's Java parser. |

## Verified vs assumed: summary

- **Verified:**
  - CarPlay template categories need Apple approval.
  - Live Activities show in CarPlay, with the update rules quoted above.
  - The widget budget numbers.
  - Spotify's endpoint fields, the Premium and Development Mode rules, and the policy clause text.
  - `LyricsCore` builds and its tests pass.
- **Not verified:**
  - Live Activity update cadence in CarPlay.
  - Background keep-alive behaviour.
  - Exactly how Spotify's policy applies to lyrics.
  - LRCLIB's terms.
  - Free-team capability limits.
  - Android Auto refresh limits.

**CarPlay compatibility is not claimed** until M1 passes in the CarPlay Simulator and M5 passes on a real display.

## Sources

- [Apple: Requesting CarPlay Entitlements](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements)
- [Apple: ActivityKit](https://developer.apple.com/documentation/activitykit)
- [Apple: Displaying live data with Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)
- [Apple: Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
- [WWDC25 "What's new in widgets" (notes)](https://wwdcnotes.com/documentation/wwdc25-278-whats-new-in-widgets/)
- [Spotify: Get currently playing track](https://developer.spotify.com/documentation/web-api/reference/get-the-users-currently-playing-track)
- [Spotify: February 2026 Dev Mode migration guide](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide)
- [Spotify: July 2026 changelog](https://developer.spotify.com/documentation/web-api/references/changes/july-2026)
- [Spotify Developer Policy](https://developer.spotify.com/policy/)
- [Spotify community: synchronization clarification](https://community.spotify.com/t5/Spotify-for-Developers/Synchronization-restriction-request-for-clarification/td-p/5139804)
- [Android for Cars: app categories](https://developer.android.com/training/cars)
- [Android Authority: sideloading on Android Auto](https://www.androidauthority.com/sideload-apps-on-android-auto-3681820/)
- [9to5Mac: Musixmatch live lyrics in CarPlay](https://9to5mac.com/2026/05/29/live-lyrics-now-available-in-carplay-with-new-app-update/)
- [Dynamic Lyrics CarPlay widget guide](https://allthings.how/how-to-get-live-lyrics-on-carplay-ios-26-with-dynamic-lyrics-widget/)
- [Wikipedia: LRC format (offset semantics)](https://en.wikipedia.org/wiki/LRC_(file_format))
