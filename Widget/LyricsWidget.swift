import LyricsCore
import SwiftUI
import WidgetKit

/// Synced lyrics on the Home Screen, Lock Screen, StandBy and the CarPlay widgets page, drawn with the same card
/// and appearance as the Live Activity. The app saves the song's line times (WidgetSnapshot) and reloads this
/// widget on every change. On the Home Screen and StandBy (small, medium and large) it's live: each entry carries the next
/// minute of lyrics and WidgetKit's turning clock hand reveals each line on time (see ClockHand). Elsewhere, or if that
/// stops working, iOS switches between one entry per line, about 2 s apart at best. CarPlay has its own widget below.
/// When nothing is playing, it offers to start Lyrics Dash.
struct LyricsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LyricsWidget", provider: LyricsTimeline()) { entry in
            LyricsWidgetView(entry: entry)
        }
        .configurationDisplayName("Lyrics")
        .description("Synced lyrics for what's playing. When nothing is, tap to start Lyrics Dash.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular])
        .disfavoredLocations([.carPlay], for: [.systemSmall])
        .contentMarginsDisabled()
    }
}

/// The lyrics for CarPlay's widgets page. CarPlay keeps widgets still while they're on screen except for switching
/// timeline entries, so this one steps through one entry per line, like Dynamic Lyrics' CarPlay widget. CarPlay
/// switches entries late, so it has its own "lines early" setting on top of the usual one.
struct LyricsCarPlayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LyricsCarPlayWidget", provider: LyricsTimeline(carPlay: true)) { entry in
            LyricsWidgetView(entry: entry)
        }
        .configurationDisplayName("Lyrics for CarPlay")
        .description("Synced lyrics on CarPlay's widgets page. Set its timing in Lyrics Dash.")
        .supportedFamilies([.systemSmall])
        .disfavoredLocations([.homeScreen, .standBy], for: [.systemSmall])
        .contentMarginsDisabled()
    }
}

struct LyricsWidgetEntry: TimelineEntry {
    let date: Date
    /// Nil when Lyrics Dash isn't running: the widget shows its start button.
    let state: LyricsActivityAttributes.ContentState?
    /// Live mode: the card for each stretch of the next minute, each shown only while it's sung.
    var live: [(segment: LiveSchedule.Segment, state: LyricsActivityAttributes.ContentState)] = []
}

struct LyricsTimeline: TimelineProvider {
    /// The CarPlay widget: one entry per line, switched `carPlayLeadMs` earlier. The others use `widgetLeadMs`.
    var carPlay = false

    func placeholder(in context: Context) -> LyricsWidgetEntry { LyricsWidgetEntry(date: .now, state: nil) }

    func getSnapshot(in context: Context, completion: @escaping (LyricsWidgetEntry) -> Void) {
        completion(entries(from: .now, live: false)[0])
    }

    /// Never reloads by itself: the app reloads it whenever the song, play state or position changes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<LyricsWidgetEntry>) -> Void) {
        let home = [.systemSmall, .systemMedium, .systemLarge].contains(context.family)
        let entries = entries(from: .now, live: !carPlay && home && ClockHand.available)
        // For the app's Status screen. Lock Screen widgets share the kind but are never real time, so they don't count.
        if home {
            TimelineProbe.record(.init(at: .now, live: entries.contains { !$0.live.isEmpty }),
                                 kind: carPlay ? "LyricsCarPlayWidget" : "LyricsWidget")
        }
        completion(Timeline(entries: entries, policy: .never))
    }

    /// One entry per line change from now to the song's end (or one per 30 s when live), then the start button,
    /// in case the app has stopped.
    private func entries(from now: Date, live: Bool) -> [LyricsWidgetEntry] {
        guard let snapshot = WidgetSnapshot.load() else { return [LyricsWidgetEntry(date: now, state: nil)] }
        guard var songStart = snapshot.songStart else {
            return [LyricsWidgetEntry(date: now, state: snapshot.state(at: snapshot.positionMs, playing: false, now: now))]
        }
        songStart.addTimeInterval(-Double((carPlay ? snapshot.carPlayLeadMs : snapshot.widgetLeadMs) ?? 0) / 1000)
        let ms = Int(now.timeIntervalSince(songStart) * 1000)
        let songEnd = songStart.addingTimeInterval(Double(snapshot.durationMs) / 1000 + 5)
        guard now < songEnd else { return [LyricsWidgetEntry(date: now, state: nil)] }
        if live, snapshot.live != false, !snapshot.lines.isEmpty {
            return liveEntries(snapshot, songStart: songStart, from: now, until: songEnd)
        }
        var entries = [LyricsWidgetEntry(date: now, state: snapshot.state(at: ms, playing: true, now: now))]
        for line in snapshot.lines where line.start > ms {
            let date = songStart.addingTimeInterval(Double(line.start) / 1000)
            entries.append(LyricsWidgetEntry(date: date, state: snapshot.state(at: line.start, playing: true, now: date)))
        }
        entries.append(LyricsWidgetEntry(date: songEnd, state: nil))
        return entries
    }

    /// An entry every 30 s, each with the cards for the next minute of song. A minute of slices fits inside the
    /// clock hand's 120 s turn, and leaves 25 s of slack if iOS switches entries late.
    private func liveEntries(_ snapshot: WidgetSnapshot, songStart: Date, from now: Date, until songEnd: Date) -> [LyricsWidgetEntry] {
        let boundaries = snapshot.lines.flatMap { [$0.start, $0.end] }
        func card(at date: Date) -> LyricsActivityAttributes.ContentState {
            snapshot.state(at: Int(date.timeIntervalSince(songStart) * 1000), playing: true, now: date)
        }
        return stride(from: now, to: songEnd, by: 30).map { date in
            let segments = LiveSchedule.segments(boundaries: boundaries, songStart: songStart, from: date.addingTimeInterval(-5),
                                                 to: min(date.addingTimeInterval(55), songEnd))
            // Each stretch takes the card at its middle, clear of rounding at its edges.
            return LyricsWidgetEntry(date: date, state: card(at: date),
                                     live: segments.map { ($0, card(at: $0.start.addingTimeInterval($0.end.timeIntervalSince($0.start) / 2))) })
        } + [LyricsWidgetEntry(date: songEnd, state: nil)]
    }
}

/// The live widget: one transparent card per stretch, stacked on one backdrop, each shown only while it's sung.
struct LiveLyricsCard: View {
    let entry: LyricsWidgetEntry
    let state: LyricsActivityAttributes.ContentState
    let small: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LyricsCard(state: state, small: small).backdrop
                ForEach(entry.live.indices, id: \.self) { index in
                    let (segment, card) = entry.live[index]
                    LyricsCard(state: card, small: small, drawsBackdrop: false)
                        .live(from: segment.start, to: segment.end, base: entry.date, size: geometry.size)
                }
            }
        }
    }
}

struct LyricsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LyricsWidgetEntry

    var body: some View {
        content.widgetURL(URL(string: entry.state == nil ? "lyricsdash://start" : "lyricsdash://open"))
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: entry.state == nil ? "play.fill" : "music.note").font(.title3.weight(.semibold))
            }
            .accessibilityLabel(entry.state == nil ? "Start Lyrics Dash" : "Open Lyrics Dash")
            .containerBackground(for: .widget) { Color.clear }
        case .accessoryRectangular:
            Group {
                if let state = entry.state {
                    VStack(alignment: .leading, spacing: 1) {
                        if state.instrumental {
                            Text(state.title).font(.headline).lineLimit(1)
                            Text(state.details.isEmpty ? "…" : "\(state.details) …").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            Text(state.current).font(.headline).lineLimit(2).minimumScaleFactor(0.7)
                            if !state.next.isEmpty { Text(state.next).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                } else {
                    Label("Tap to start lyrics", systemImage: "play.fill").font(.headline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(for: .widget) { Color.clear }
        default:
            if let state = entry.state {
                Group {
                    if entry.live.isEmpty {
                        LyricsCard(state: state, small: family == .systemSmall)
                    } else {
                        LiveLyricsCard(entry: entry, state: state, small: family == .systemSmall)
                    }
                }
                .overlay(alignment: .topTrailing) { if state.style.showCounter { probe(live: !entry.live.isEmpty) } }
                .containerBackground(for: .widget) { state.style.background.color }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "play.circle.fill").font(.system(size: 36)).foregroundStyle(.white)
                    Text("Start lyrics").font(.headline).foregroundStyle(.white)
                    Text("with \(startSource)").font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Start Lyrics Dash with \(startSource)")
                .containerBackground(for: .widget) { Color.black }
            }
        }
    }

    /// The source Home has selected, which the start link follows (saved by the app as "source"; Spotify until then).
    private var startSource: String {
        SharedKeychain.read(account: "source").flatMap { String(data: $0, encoding: .utf8) } == "appleMusic" ? "Apple Music" : "Spotify"
    }

    /// With "Update counter" on: a dial whose hand turns once every 120 s when the widget is live (a still hand means
    /// this screen doesn't run WidgetKit's clock hands, so the lyrics can't move either), or "per line" when iOS is
    /// stepping through one entry per line.
    @ViewBuilder private func probe(live: Bool) -> some View {
        Group {
            if live {
                ClockHand.rotating(Capsule().frame(width: 2, height: 6).offset(y: -3).frame(width: 14, height: 14), period: 120)
                    .background(Circle().stroke(lineWidth: 1))
            } else {
                Text("per line").font(.system(size: 8, weight: .semibold))
            }
        }
        .foregroundStyle(.white.opacity(0.7))
        .padding(6)
    }
}
