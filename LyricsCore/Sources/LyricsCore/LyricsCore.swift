import Foundation

/// One timed lyric line. Times are milliseconds from the start of the track.
public struct LyricLine: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let text: String
    public init(start: Int, end: Int, text: String) {
        self.start = start; self.end = end; self.text = text
    }
}

/// How the "show lines early" setting reads in the app.
public enum LyricsTiming {
    /// "On time", "0.3 s earlier" or "0.5 s later". Positive `leadMs` shows lines early.
    public static func label(leadMs: Int) -> String {
        guard leadMs != 0 else { return "On time" }
        return String(format: "%.1f s %@", Double(abs(leadMs)) / 1000, leadMs > 0 ? "earlier" : "later")
    }
}

/// Parser for synced LRC text, as returned by LRCLIB's `syncedLyrics`.
public enum LRC {
    public static let maxLines = 1000
    public static let maxInputLength = 512_000

    /// Parses LRC into sorted lines whose `end` is the next line's start.
    /// `durationMs` > 0 drops stamps past the track and ends the last line at the track end.
    public static func parse(_ raw: String, durationMs: Int = 0) -> [LyricLine] {
        guard raw.count <= maxInputLength else { return [] }
        // LRC spec: a positive [offset:] makes lyrics appear sooner, so it is subtracted.
        var offset = 0
        if let tag = raw.firstMatch(of: /(?i)\[offset:\s*([+-]?\d+)\s*\]/), let value = Int(tag.1) {
            offset = min(600_000, max(-600_000, value))
        }
        var stamped: [(start: Int, text: String)] = []
        for row in raw.replacingOccurrences(of: "\u{FEFF}", with: "").split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var starts: [Int] = []
            var textStart = row.startIndex
            for match in row.matches(of: /\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]/) {
                guard let minutes = Int(match.1), let seconds = Int(match.2), seconds <= 59 else { continue }
                let fraction = match.3.map(String.init) ?? ""
                let fractionMs = (Int(fraction) ?? 0) * [1000, 100, 10, 1][fraction.count]
                starts.append(max(0, (minutes * 60 + seconds) * 1000 + fractionMs - offset))
                textStart = match.range.upperBound
            }
            guard !starts.isEmpty else { continue }
            let text = String(row[textStart...].trimmingCharacters(in: .whitespaces).prefix(1000))
            for start in starts where durationMs <= 0 || start <= durationMs + 2000 {
                stamped.append((start, text))
            }
        }
        stamped = Array(stamped.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element).prefix(maxLines))
        // Lines sharing a stamp (duets, translations) become one multi-line entry.
        var merged: [(start: Int, text: String)] = []
        for line in stamped {
            if let last = merged.last, last.start == line.start {
                if !line.text.isEmpty && line.text != last.text {
                    merged[merged.count - 1].text = last.text.isEmpty ? line.text : last.text + "\n" + line.text
                }
            } else {
                merged.append(line)
            }
        }
        return merged.indices.map { i in
            let start = merged[i].start
            let end = i + 1 < merged.count ? merged[i + 1].start : (durationMs > start ? durationMs : start + 30_000)
            return LyricLine(start: start, end: end, text: merged[i].text)
        }
    }
}

/// A playback position sample, e.g. Spotify's `progress_ms`, taken at `sampledAt`.
/// Use the time the response arrived (minus about half the round trip) for `sampledAt`.
/// Spotify's own `timestamp` field marks the last state change, not the progress sample.
public struct PlaybackSnapshot: Equatable, Sendable {
    public var progressMs: Int
    public var sampledAt: Date
    public var isPlaying: Bool
    public var durationMs: Int
    public var rate: Double

    public init(progressMs: Int, sampledAt: Date, isPlaying: Bool, durationMs: Int = 0, rate: Double = 1) {
        self.progressMs = progressMs; self.sampledAt = sampledAt; self.isPlaying = isPlaying
        self.durationMs = durationMs; self.rate = rate
    }

    /// Extrapolated position at `now`, clamped to the track.
    public func position(at now: Date) -> Int {
        let elapsed = isPlaying ? Int((now.timeIntervalSince(sampledAt) * 1000 * rate).rounded()) : 0
        let value = max(0, progressMs + max(0, elapsed))
        return durationMs > 0 ? min(value, durationMs) : value
    }
}

/// Line selection and the next moment the displayed line changes.
public enum LyricSync {
    /// The line covering `positionMs`, or nil before the first line or in a gap.
    public static func activeIndex(_ lines: [LyricLine], at positionMs: Int) -> Int? {
        let candidate = lastIndex(startingAtOrBefore: positionMs, in: lines)
        guard let candidate, positionMs < lines[candidate].end else { return nil }
        return candidate
    }

    /// The next position where `activeIndex` changes, or nil when nothing changes again.
    /// Schedule display updates (e.g. Live Activity updates) for exactly these moments.
    public static func nextChange(_ lines: [LyricLine], after positionMs: Int) -> Int? {
        let current = lastIndex(startingAtOrBefore: positionMs, in: lines)
        let next = (current ?? -1) + 1
        let nextStart = next < lines.count ? lines[next].start : nil
        if let current, lines[current].end > positionMs, nextStart.map({ lines[current].end < $0 }) ?? true {
            return lines[current].end
        }
        return nextStart
    }

    private static func lastIndex(startingAtOrBefore positionMs: Int, in lines: [LyricLine]) -> Int? {
        var low = 0, high = lines.count - 1, result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].start <= positionMs { result = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return result
    }
}
