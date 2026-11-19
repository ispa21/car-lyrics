import Foundation

/// Diagnostics for "the card freezes after about 250 updates": the widget notes the newest update it has drawn, and
/// when, separately for CarPlay's size, the Lock Screen's and the Dynamic Island. The app reads it back for its update
/// diagnostics and Status screen, so "iOS took the update" (contentUpdates) can be told apart from "iOS drew it".
/// ponytail: drawn isn't the same as on screen (iOS may draw ahead, or for a screen that's off), but it's the
/// closest the app can see.
enum DrawProbe {
    struct Draw: Codable {
        let seq: Int
        let at: Date
    }

    /// Where the card was drawn. `.carPlay` is the .small family, which an Apple Watch uses too.
    enum Surface: String, CaseIterable {
        case lockScreen = "drawn-lockscreen", carPlay = "drawn-carplay", island = "drawn-island"
    }

    /// Called from the widget each time it draws the card. Only the first draw of a newer update is written.
    static func record(seq: Int, on surface: Surface) {
        if let last = read(surface), last.seq >= seq { return }
        SharedKeychain.write(try? JSONEncoder().encode(Draw(seq: seq, at: .now)), account: surface.rawValue)
    }

    static func read(_ surface: Surface) -> Draw? {
        SharedKeychain.read(account: surface.rawValue).flatMap { try? JSONDecoder().decode(Draw.self, from: $0) }
    }

    /// At the start of each run, since update numbers start again from 1.
    static func reset() {
        for surface in Surface.allCases { SharedKeychain.write(nil, account: surface.rawValue) }
    }
}

/// When iOS last asked a widget kind for its Home Screen timeline, and whether that timeline is real time. A widget
/// can't report being on screen (iOS draws it from an archive without running its code), so the Status screen calls
/// this "ready". Being asked at all means the widget has been added somewhere.
struct TimelineProbe: Codable {
    let at: Date
    let live: Bool

    static func record(_ probe: TimelineProbe, kind: String) {
        SharedKeychain.write(try? JSONEncoder().encode(probe), account: "timeline-\(kind)")
    }

    static func read(kind: String) -> TimelineProbe? {
        SharedKeychain.read(account: "timeline-\(kind)").flatMap { try? JSONDecoder().decode(TimelineProbe.self, from: $0) }
    }
}
