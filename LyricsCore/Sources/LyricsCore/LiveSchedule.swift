import Foundation

/// Timing for a widget that changes lyrics on its own, between timeline entries. WidgetKit can turn a view like a
/// clock hand, which the Home Screen animates by itself: clockwise once every `period` seconds, at
/// 360° × (Unix time mod period) / period from 12 o'clock. Each stretch of the song between lyric changes gets the
/// slice of a ring that passes 12 o'clock during that stretch, so the stretch shows exactly while it's being sung.
public enum LiveSchedule {
    public struct Segment: Equatable, Sendable {
        public let start: Date
        public let end: Date
    }

    /// The stretches between lyric changes from `from` to `to`, back to back. `boundaries` are the song positions (ms)
    /// where the shown lyric changes, such as each line's start and end; the song is at 0:00 at `songStart`.
    public static func segments(boundaries: [Int], songStart: Date, from: Date, to: Date) -> [Segment] {
        let inside = boundaries.map { songStart.addingTimeInterval(Double($0) / 1000) }.filter { $0 > from && $0 < to }
        let cuts = ([from] + Set(inside).sorted() + [to])
        return zip(cuts, cuts.dropFirst()).map { Segment(start: $0, end: $1) }
    }

    /// The hand's angle at `date` in degrees, counted from the start of the turn `base` falls in, so it keeps
    /// growing past 360° instead of wrapping and a slice is always `start < end`.
    public static func angle(at date: Date, period: Double, base: Date) -> Double {
        let turnStart = base.timeIntervalSince1970 - base.timeIntervalSince1970.truncatingRemainder(dividingBy: period)
        return (date.timeIntervalSince1970 - turnStart) / period * 360
    }
}
