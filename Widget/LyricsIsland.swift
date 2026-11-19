import SwiftUI

/// The Dynamic Island's pieces. The island is always black, so they ignore the card's colours and backdrop and
/// keep light text, borrowing only the chosen font, accent and the song's album colours.

/// A small tile of the album's colours (its blurred 12×12 art) with a music note, or the accent when there's no art yet.
struct IslandArt: View {
    let state: LyricsActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        ZStack {
            if let art = state.art.flatMap(Artwork.image) {
                Image(decorative: art, scale: 1).resizable().interpolation(.high).scaledToFill()
                    .blur(radius: size / 6, opaque: true)
                    .overlay(Color.black.opacity(0.2))
            } else {
                state.style.accent.color.opacity(0.25)
            }
            Image(systemName: "music.note")
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.28))
        .accessibilityHidden(true)
    }
}

/// A ring that fills across the current line, in the accent colour. iOS animates it without updates.
struct IslandRing: View {
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        if let start = state.lineStart, let end = state.lineEnd, end > start {
            ProgressView(timerInterval: start...end, countsDown: false, label: { EmptyView() }, currentValueLabel: { EmptyView() })
                .progressViewStyle(.circular)
                .tint(state.style.accent.color)
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
        }
    }
}

/// The song, for the expanded island's centre.
struct IslandSong: View {
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(state.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
            if !state.artist.isEmpty {
                Text(state.artist).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The current lyric large in the chosen font, the next one dim beneath.
struct IslandLyrics: View {
    let state: LyricsActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        let _ = DrawProbe.record(seq: state.seq, on: .island)  // for the app's Status screen, like FamilyCard's
        VStack(alignment: .leading, spacing: 3) {
            if stale {
                Text("Lyrics paused · open Lyrics Dash").font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            } else if state.lyrics != .synced {
                Text(state.next.isEmpty ? state.lyrics.label : state.next).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            } else {
                Text(state.instrumental ? "…" : cased(state.current))
                    .font(state.style.typeface.font(size: 22, weight: state.style.weight))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                if !state.next.isEmpty {
                    Text(cased(state.next))
                        .font(state.style.typeface.font(size: 15, weight: state.style.weight))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
        .contentTransition(.identity)
    }

    private func cased(_ text: String) -> String { state.style.uppercase ? text.uppercased() : text }
}

/// The compact island's right side: the current line, small enough to fit more before it's cut off.
struct IslandLine: View {
    let state: LyricsActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        let _ = DrawProbe.record(seq: state.seq, on: .island)
        Text(stale ? "Paused" : state.instrumental ? "…" : state.current)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: 130, alignment: .trailing)
            .contentTransition(.identity)
    }
}
