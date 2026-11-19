import ActivityKit
import SwiftUI
import WidgetKit

@main
struct LyricsWidgetBundle: WidgetBundle {
    var body: some Widget {
        LyricsLiveActivity()
        LyricsWidget()
        LyricsCarPlayWidget()
    }
}

struct LyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            FamilyCard(state: context.state, stale: context.isStale)
                .activityBackgroundTint(context.state.style.background.color)
                .activitySystemActionForegroundColor(context.state.style.ink(art: context.state.art).color)
        } dynamicIsland: { context in
            // See LyricsIsland.swift: light text on the island's black, with the album's colours and the accent.
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandArt(state: context.state, size: 44)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandRing(state: context.state)
                }
                DynamicIslandExpandedRegion(.center) {
                    IslandSong(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandLyrics(state: context.state, stale: context.isStale)
                }
            } compactLeading: {
                IslandArt(state: context.state, size: 22)
            } compactTrailing: {
                IslandLine(state: context.state, stale: context.isStale)
            } minimal: {
                IslandArt(state: context.state, size: 22)
            }
            .keylineTint(context.state.style.accent.color)
        }
        // .small is the family CarPlay (and Apple Watch) use.
        .supplementalActivityFamilies([.small])
    }
}

/// Tells the shared card whether it's drawing at CarPlay's size.
struct FamilyCard: View {
    @Environment(\.activityFamily) private var family
    let state: LyricsActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        // ponytail: a side effect while drawing, for diagnostics only (see DrawProbe).
        let _ = DrawProbe.record(seq: state.seq, on: family == .small ? .carPlay : .lockScreen)
        LyricsCard(state: state, small: family == .small, stale: stale)
    }
}
