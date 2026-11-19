# Contributing

Issues and pull requests are welcome.

- **Bugs:** open an issue with your iPhone model, iOS version, and (if you can) the session log from Settings → Troubleshooting → Share latest session log. Remove anything you don't want public first.
- **Real CarPlay photos or screenshots:** add them to `docs/screenshots/` in a PR, or attach them to an issue.
- **Code:** run `xcodegen`, build, and run `cd LyricsCore && swift test` before opening a PR.
- **Secrets:** never commit `Local.xcconfig`, tokens or your team ID. It's gitignored; keep it that way.
