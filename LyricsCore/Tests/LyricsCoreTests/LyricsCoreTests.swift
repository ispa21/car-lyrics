import Foundation
import Testing
@testable import LyricsCore

@Test func timingLabelReadsEarlierLaterOrOnTime() {
    #expect(LyricsTiming.label(leadMs: 0) == "On time")
    #expect(LyricsTiming.label(leadMs: 300) == "0.3 s earlier")
    #expect(LyricsTiming.label(leadMs: -500) == "0.5 s later")
    #expect(LyricsTiming.label(leadMs: 3000) == "3.0 s earlier")
}

@Suite struct LRCParsing {
    @Test func parsesStampsFractionsAndSorting() {
        let lines = LRC.parse("[ti:Song]\n[00:05.5]second\n[00:01.25]first\n[00:09.125]third\nno stamp here")
        #expect(lines.map(\.start) == [1250, 5500, 9125])
        #expect(lines.map(\.text) == ["first", "second", "third"])
        #expect(lines.map(\.end) == [5500, 9125, 39125])  // last line: start + 30 s without a duration
    }

    @Test func repeatedStampsAndSharedStamps() {
        let lines = LRC.parse("[00:01.00][00:03.00]chorus\n[00:03.00]harmony\n[00:05.00]")
        #expect(lines.map(\.start) == [1000, 3000, 5000])
        #expect(lines[1].text == "chorus\nharmony")
        #expect(lines[2].text == "")  // instrumental break stays as a timed empty line
    }

    @Test func offsetMovesLyricsSoonerAndClampsAtZero() {
        let lines = LRC.parse("[offset:+500]\n[00:00.20]a\n[00:02.00]b")
        #expect(lines.map(\.start) == [0, 1500])
    }

    @Test func durationTrimsAndEndsLastLine() {
        let lines = LRC.parse("[00:01.00]a\n[00:10.00]b\n[05:00.00]past end", durationMs: 12_000)
        #expect(lines.map(\.text) == ["a", "b"])
        #expect(lines.last?.end == 12_000)
    }

    @Test func rejectsBadStampsAndHandlesBOMAndCRLF() {
        let lines = LRC.parse("\u{FEFF}[00:75.00]bad seconds\r\n[00:02.00]ok\r\n")
        #expect(lines == [LyricLine(start: 2000, end: 32_000, text: "ok")])
        #expect(LRC.parse(String(repeating: "x", count: LRC.maxInputLength + 1)).isEmpty)
    }
}

@Suite struct Sync {
    // Gap between 4 s and 6 s: the first line ends before the second starts.
    let lines = [LyricLine(start: 1000, end: 4000, text: "a"),
                 LyricLine(start: 6000, end: 9000, text: "b")]

    @Test func activeLine() {
        #expect(LyricSync.activeIndex(lines, at: 0) == nil)
        #expect(LyricSync.activeIndex(lines, at: 1000) == 0)
        #expect(LyricSync.activeIndex(lines, at: 3999) == 0)
        #expect(LyricSync.activeIndex(lines, at: 5000) == nil)
        #expect(LyricSync.activeIndex(lines, at: 6000) == 1)
        #expect(LyricSync.activeIndex(lines, at: 9000) == nil)
        #expect(LyricSync.activeIndex([], at: 10) == nil)
    }

    @Test func nextChangeVisitsEveryBoundary() {
        var position = 0, boundaries: [Int] = []
        while let next = LyricSync.nextChange(lines, after: position) { boundaries.append(next); position = next }
        #expect(boundaries == [1000, 4000, 6000, 9000])
    }

    @Test func playbackExtrapolation() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let playing = PlaybackSnapshot(progressMs: 10_000, sampledAt: t0, isPlaying: true, durationMs: 11_000)
        #expect(playing.position(at: t0.addingTimeInterval(0.5)) == 10_500)
        #expect(playing.position(at: t0.addingTimeInterval(5)) == 11_000)  // clamped to duration
        #expect(playing.position(at: t0.addingTimeInterval(-1)) == 10_000)  // clock skew never rewinds
        let paused = PlaybackSnapshot(progressMs: 10_000, sampledAt: t0, isPlaying: false)
        #expect(paused.position(at: t0.addingTimeInterval(30)) == 10_000)
    }
}

@Suite struct Live {
    let songStart = Date(timeIntervalSince1970: 1_200_000)  // a multiple of the 120 s turn

    @Test func segmentsTileTheWindowAtEachChange() {
        // Lines 1–4 s and 6–9 s, seen from 2 s to 8 s: the line, the gap, the next line.
        let segments = LiveSchedule.segments(boundaries: [1000, 4000, 6000, 9000, 9000], songStart: songStart,
                                             from: songStart.addingTimeInterval(2), to: songStart.addingTimeInterval(8))
        #expect(segments.map { $0.start.timeIntervalSince(songStart) } == [2, 4, 6])
        #expect(segments.map { $0.end.timeIntervalSince(songStart) } == [4, 6, 8])
    }

    @Test func angleMatchesTheClockHandAndNeverWraps() {
        #expect(LiveSchedule.angle(at: songStart, period: 120, base: songStart) == 0)
        #expect(LiveSchedule.angle(at: songStart.addingTimeInterval(30), period: 120, base: songStart) == 90)
        // Past the end of the turn it keeps counting, so a slice across 12 o'clock still has start < end.
        let base = songStart.addingTimeInterval(100)
        #expect(LiveSchedule.angle(at: base, period: 120, base: base) == 300)
        #expect(LiveSchedule.angle(at: songStart.addingTimeInterval(130), period: 120, base: base) == 390)
    }
}
