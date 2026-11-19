# Lyrics Dash

Synced, line-by-line lyrics on your **CarPlay** screen, for Spotify and Apple Music. It uses an iOS 26+ Live Activity, so it needs no CarPlay entitlement from Apple. The same card shows on the Lock Screen, the Dynamic Island and in widgets.

<p align="center">
  <img src="docs/screenshots/home-running.png" width="250" alt="Home screen while lyrics are running">
  <img src="docs/screenshots/appearance.png" width="250" alt="Appearance editor with presets">
  <img src="docs/screenshots/settings.png" width="250" alt="Settings">
</p>

## CarPlay and Lock Screen card

The card has four layouts (Minimal, Big, Detailed, Karaoke) and 20 presets, and you can make your own. This is how each layout renders on CarPlay and on the Lock Screen:

<p align="center">
  <img src="docs/screenshots/carplay-card-layouts.png" width="300" alt="Card layouts as shown on CarPlay">
  <img src="docs/screenshots/lockscreen-card-layouts.png" width="300" alt="Card layouts as shown on the Lock Screen">
</p>

The card on a real CarPlay screen (Apple's CarPlay Simulator connected to an iPhone, demo song):

<p align="center"><img src="docs/screenshots/carplay-real.png" width="360" alt="Lyrics Dash card on the CarPlay dashboard"></p>

> The layout images above are renders of the card from the app. Photos from a real car are welcome: see [Contributing](CONTRIBUTING.md).

## More screenshots

| Presets | Keep running | Offline lyrics | Status |
| --- | --- | --- | --- |
| <img src="docs/screenshots/presets.png" width="180"> | <img src="docs/screenshots/keep-running.png" width="180"> | <img src="docs/screenshots/offline.png" width="180"> | <img src="docs/screenshots/status.png" width="180"> |

## Features
- Spotify (Premium) and Apple Music. Lyrics come from [LRCLIB](https://lrclib.net), which is free and needs no key.
- Live Activity on CarPlay, the Lock Screen and the Dynamic Island, plus Home Screen, StandBy, Lock Screen and CarPlay widgets.
- Customisable card: layouts, fonts, colours, presets, "Surprise me".
- Per-song timing adjustment, and a **Status** screen that says what's working and what isn't.
- Keeps running in the background (silent audio and low-accuracy location).
- Offline: lyrics for songs you've played, your queue, or your whole library are saved on the phone.

## Requirements
- iPhone 11 or newer on **iOS 26+** (CarPlay only shows Live Activities from iOS 26)
- A Mac with **Xcode 27** and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- An Apple ID (a free one works; the install expires after 7 days and you re-run it)
- For Spotify: a Premium account and a free [Spotify developer app](https://developer.spotify.com/dashboard)

## Quick start
```sh
git clone https://github.com/ispa21/car-lyrics.git && cd car-lyrics
cp Local.xcconfig.example Local.xcconfig   # add your Apple team ID (and Spotify Client ID)
xcodegen
open LyricsDash.xcodeproj                  # pick your iPhone, press ⌘R
```
The full walkthrough (phone setup, Spotify, CarPlay, troubleshooting) is in **[docs/SETUP.md](docs/SETUP.md)**. No car? Use **Try the demo song** in the app, or the CarPlay Simulator.

## Docs
- [docs/SETUP.md](docs/SETUP.md): step-by-step install and use
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): how it works (background running, widgets, offline cache)
- [docs/FEASIBILITY.md](docs/FEASIBILITY.md): why a Live Activity, and what was tried

Run the core tests with `cd LyricsCore && swift test`.

## Limitations
- It's a sideloaded personal build, not an App Store app. Keeping the app alive in the background with silent audio and location would not pass App Review.
- Not supported: YouTube Music and other apps (iOS doesn't let apps see what another app plays).
- Lyrics are fetched from LRCLIB at runtime and aren't bundled; not every song has synced lyrics there.

Not affiliated with Spotify, Apple or LRCLIB.

## License
[MIT](LICENSE)
