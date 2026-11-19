import Foundation

/// What the lyrics widget needs to step through a song by itself: every line with its time, and when the song
/// started (nil while paused). The app saves it whenever the song, play state, position, lyrics or look change;
/// the widget turns it into a timeline with one entry per line, which iOS switches between on its own.
struct WidgetSnapshot: Codable {
    struct Line: Codable {
        let start: Int
        let end: Int
        let text: String
    }

    var title: String
    var artist: String
    var lines: [Line]
    var durationMs: Int
    /// When the song, shifted by "Show lines early", was at 0:00. Nil while paused.
    var songStart: Date?
    /// Where playback stood when saved, for showing a paused song.
    var positionMs: Int
    var lyrics: LyricsAvailability
    var style: CardStyle
    var art: Data?
    var album: String? = nil
    /// The app's "Real-time widget" setting; nil (saved by an older version) counts as on.
    var live: Bool? = nil
    /// How much earlier the CarPlay widget switches lines, on top of "Show lines early", to cancel CarPlay's lag.
    var carPlayLeadMs: Int? = nil
    /// The same for the Home Screen and StandBy widget. It can be negative: the real-time widget has no lag, so it can
    /// cancel a "Show lines early" set for the Live Activity.
    var widgetLeadMs: Int? = nil

    static func load() -> WidgetSnapshot? {
        SharedKeychain.read().flatMap { try? JSONDecoder().decode(WidgetSnapshot.self, from: $0) }
    }

    /// Nil clears it, which the widget shows as "tap to start".
    static func save(_ snapshot: WidgetSnapshot?) {
        SharedKeychain.write(snapshot.flatMap { try? JSONEncoder().encode($0) })
    }

    /// The card's content at song position `ms`, in the shape the Live Activity uses, so the widget can draw the same card.
    func state(at ms: Int, playing: Bool, now: Date) -> LyricsActivityAttributes.ContentState {
        let index = lines.lastIndex { $0.start <= ms }.flatMap { ms < lines[$0].end ? $0 : nil }
        let text = index.map { lines[$0].text } ?? ""
        let isInstrumental = LyricsActivityAttributes.ContentState.isInstrumental
        let instrumental = !lines.isEmpty && isInstrumental(text)
        let current = lines.isEmpty ? title : (instrumental ? "" : text)
        let next = lines.isEmpty ? lyrics.label : lines.first { $0.start > ms && !isInstrumental($0.text) }?.text ?? ""
        let previous = lines.last { $0.end <= ms && !isInstrumental($0.text) }?.text ?? ""
        // The current line, or before the first line the intro up to it, as the Live Activity does.
        var lineStart: Date?, lineEnd: Date?
        if playing, !lines.isEmpty {
            let span = index.map { (lines[$0].start, lines[$0].end) }
                ?? (lines.last { $0.start <= ms }?.end ?? 0, lines.first { $0.start > ms }?.start ?? durationMs)
            lineStart = now.addingTimeInterval(Double(span.0 - ms) / 1000)
            lineEnd = now.addingTimeInterval(Double(span.1 - ms) / 1000)
        }
        return .init(title: title, artist: artist, current: current, next: next, previous: previous, album: album ?? "",
                     instrumental: instrumental, lyrics: lyrics, lineStart: lineStart, lineEnd: lineEnd, seq: 0, style: style,
                     art: style.backdrop == .albumArt ? art : nil)
    }
}

/// One keychain item the app and widget can both read. A free Apple ID can't use App Groups, but its signing
/// profile allows any keychain access group under the team, so both targets list the same one in their entitlements.
enum SharedKeychain {
    /// "<team>.com.ishanpatil.lyricsdash.shared", put in both targets' Info.plist from the build settings.
    private static let group = Bundle.main.object(forInfoDictionaryKey: "SharedKeychainGroup") as? String ?? ""

    /// `account` names the item: "snapshot" for the widget, others for diagnostics (see DrawProbe).
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "LyricsDash.widget",
         kSecAttrAccount as String: account, kSecAttrAccessGroup as String: group]
    }

    static func write(_ data: Data?, account: String = "snapshot") {
        SecItemDelete(query(account) as CFDictionary)
        guard let data else { return }
        var item = query(account)
        item[kSecValueData as String] = data
        // Readable while locked (after the first unlock), since Lock Screen and CarPlay widgets draw then.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func read(account: String = "snapshot") -> Data? {
        var item = query(account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}
