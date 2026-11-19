import SwiftUI

/// The lyrics card. Shared so the app's Appearance screen can preview it; the widget renders it on the
/// Lock Screen, in the Dynamic Island and on CarPlay. `small` is CarPlay's size (the .small activity family).
struct LyricsCard: View {
    let state: LyricsActivityAttributes.ContentState
    var small = false
    /// No update arrived when one was due, so the lyric shown is probably out of date.
    var stale = false
    /// False for the live widget, which stacks transparent cards on one shared backdrop.
    var drawsBackdrop = true

    private var style: CardStyle { state.style }
    private var ink: Color { style.ink(art: state.art).color }
    private var shadowed: Bool { style.needsShadow(art: state.art) }
    private var fill: Alignment { style.centered ? .center : .leading }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if state.instrumental, state.lyrics == .synced {
                    instrumental
                } else {
                    switch style.layout {
                    case .minimal: minimal
                    case .big: big
                    case .detailed: detailed
                    case .karaoke: karaoke
                    }
                }
            }
            .multilineTextAlignment(style.centered ? .center : .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: fill)
            .opacity(stale ? 0.3 : 1)
            // Below the lyrics rather than over them, so it never covers the progress bar; the layout re-fits above it.
            if stale {
                Text("Lyrics paused · open Lyrics Dash")
                    .font(.system(size: small ? 10 : 12, weight: .semibold))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.bottom, small ? 4 : 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { if drawsBackdrop { backdrop } }
        // CarPlay can draw old and new text on top of each other while an update animates
        // (developer forums, thread 804483), so lyric changes are instant.
        .contentTransition(.identity)
        .transaction { $0.animation = nil }
    }

    /// A colour, a two-colour gradient, or the song's album art blurred into soft colour and darkened.
    @ViewBuilder var backdrop: some View {
        switch style.backdrop {
        case .color:
            style.background.color
        case .gradient:
            LinearGradient(colors: [style.background.color, style.background2.color], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .albumArt:
            if let art = state.art.flatMap(Artwork.image) {
                Image(decorative: art, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .blur(radius: small ? 10 : 16, opaque: true)
                    .overlay(Color.black.opacity(style.artDarkness))
                    .clipped()
            } else {
                style.background.color
            }
        }
    }

    // Fitting text. Each layout lists its arrangements from fullest to sparest inside a ViewThatFits, which measures
    // the space the card really has (every CarPlay screen, the Lock Screen and widget sizes differ) and uses the first
    // whose text fits whole. Lines are given up least important first (song info, previous line, next line), and only
    // then does the current lyric shrink, through `shrinking`, the last resort that always fits. So the current lyric
    // is never cut off with "…", whatever the font, letter spacing, all caps or size setting.

    private var stack: HorizontalAlignment { style.centered ? .center : .leading }

    /// Between sung lines, instead of a music symbol: "…" for the lyrics to come, then the artist, title and album.
    /// The progress bar, where the layout has one, fills until the singing resumes. Short of space (CarPlay's card is
    /// small, and big or decorative fonts wrap the title), everything shrinks step by step, and only then does the
    /// album go, then the artist.
    private var instrumental: some View {
        VStack(alignment: stack, spacing: pad(small ? 3 : 4)) {
            ViewThatFits(in: .vertical) {
                song(state.artist, state.album, scale: 1)
                song(state.artist, state.album, scale: 0.8)
                song(state.artist, state.album, scale: 0.65)
                song(state.artist, state.album, scale: 0.5)
                song(state.artist, state.album, scale: 0.4)
                song(state.artist, "", scale: 0.4)
                song("", "", scale: 0.4)
                song("", "", scale: 0.4).lineLimit(4).minimumScaleFactor(0.25)
            }
            if style.layout != .minimal { progress(0.8) }
        }
        .padding(pad(small ? 10 : 14))
    }

    /// "…" centred whatever the alignment, then the artist, the title at `scale` of its usual size, and the album.
    /// They shrink only so far: the title to 13 or 15 points, the artist and album to the song info line's size.
    private func song(_ artist: String, _ album: String, scale: CGFloat) -> some View {
        let big = style.layout == .big
        let soft = max(style.dim, 0.6)  // artist and album stay readable however dim the other lines are set
        let title = max((big ? 36 : (small ? 18 : 20)) * scale, small ? 13 : 15)
        let detail = max((big ? 15 : (small ? 12 : 13)) * scale, small ? 10 : 11)
        return VStack(alignment: stack, spacing: pad(small ? 3 : 4)) {
            line("…", size: title * 0.8, brightness: soft).frame(maxWidth: .infinity)
            optional(artist, detail, soft)
            line(state.title, size: title)
            optional(album, detail, soft)
        }
    }

    /// Just the current line, at a comfortable size, wrapping onto as many lines as fit.
    private var minimal: some View {
        let brightness = state.lyrics == .synced ? 1.0 : 0.5, size: CGFloat = small ? 24 : 22
        return ViewThatFits(in: .vertical) {
            line(headline, size: size, brightness: brightness)
            shrinking(headline, size: size, brightness: brightness)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: fill)
        .padding(pad(small ? 10 : 16))
    }

    /// The current lyric, as big as it fits, with a thin bar filling across the line.
    private var big: some View {
        VStack(spacing: pad(5)) {
            line(headline, size: 64, brightness: state.lyrics == .synced ? 1 : 0.5)
                .lineLimit(4)
                .minimumScaleFactor(0.1)  // short lines go huge, long lines shrink to fit
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: fill)
            if state.lyrics == .synced { progress(0.7) }
        }
        .padding(pad(small ? 8 : 10))
    }

    /// Song line, current lyric, next lyric (dim), and the bar.
    private var detailed: some View {
        let gap = pad(small ? 3 : 5), size: CGFloat = small ? 22 : 23
        return VStack(alignment: stack, spacing: gap) {
            ViewThatFits(in: .vertical) {
                VStack(alignment: stack, spacing: gap) { songInfo; line(state.current, size: size); nextLine(15) }
                VStack(alignment: stack, spacing: gap) { line(state.current, size: size); nextLine(15) }
                line(state.current, size: size)
                shrinking(state.current, size: size)
            }
            progress(0.8)
        }
        .padding(pad(small ? 10 : 14))
    }

    /// Previous, current and next lines, the current one bright and larger.
    private var karaoke: some View {
        let gap = pad(small ? 2 : 4), size: CGFloat = small ? 22 : 24, aside: CGFloat = small ? 14 : 15
        return VStack(alignment: stack, spacing: gap) {
            ViewThatFits(in: .vertical) {
                VStack(alignment: stack, spacing: gap) {
                    songInfo; optional(state.previous, aside, style.dim); line(state.current, size: size); optional(state.next, aside, style.dim)
                }
                VStack(alignment: stack, spacing: gap) {
                    optional(state.previous, aside, style.dim); line(state.current, size: size); optional(state.next, aside, style.dim)
                }
                VStack(alignment: stack, spacing: gap) { line(state.current, size: size); optional(state.next, aside, style.dim) }
                line(state.current, size: size)
                shrinking(state.current, size: size)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: fill)
            progress(0.8)
        }
        .padding(pad(small ? 10 : 14))
    }

    private var headline: String {
        switch state.lyrics {
        case .synced: state.current
        case .searching: "…"
        default: "No lyrics"
        }
    }

    @ViewBuilder private var songInfo: some View {
        if style.showSongInfo { info }
    }

    @ViewBuilder private func nextLine(_ size: CGFloat) -> some View {
        if style.showNext { optional(state.next, size, style.dim) }
    }

    /// A secondary line, left out when empty.
    @ViewBuilder private func optional(_ text: String, _ size: CGFloat, _ brightness: Double) -> some View {
        if !text.isEmpty { line(text, size: size, brightness: brightness) }
    }

    /// The last resort: shrinks the text, down to a quarter of its size, until it fits.
    private func shrinking(_ text: String, size: CGFloat, brightness: Double = 1) -> some View {
        line(text, size: size, brightness: brightness).lineLimit(4).minimumScaleFactor(0.25)
    }

    /// The song, quietly. A status badge appears only when something needs attention (searching, no lyrics…).
    /// Short of width, the artist goes before the title is cut.
    private var info: some View {
        HStack(spacing: 5) {
            if state.lyrics != .synced {
                Circle().fill(state.lyrics.color).frame(width: 5, height: 5)
                Text(state.lyrics.label.uppercased())
                    .font(.system(size: small ? 9 : 10, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(state.lyrics.color)
                    .fixedSize()
            }
            ViewThatFits(in: .horizontal) {
                infoText(state.artist.isEmpty ? state.title : "\(state.title) · \(state.artist)")
                infoText(state.title)
            }
            if !style.centered { Spacer(minLength: 0) }
            if style.showCounter {
                Text("#\(state.seq)").font(.system(size: 8, weight: .medium).monospacedDigit()).foregroundStyle(ink.opacity(0.35)).fixedSize()
            }
        }
    }

    private func infoText(_ text: String) -> some View {
        Text(text).font(.system(size: small ? 10 : 11, weight: .medium)).foregroundStyle(ink.opacity(0.6)).lineLimit(1)
    }

    /// A lyric line in the chosen font, size, spacing, case, colour and shadow. Letters may squeeze slightly
    /// (allowsTightening) before anything shrinks or is dropped.
    private func line(_ text: String, size: CGFloat, brightness: Double = 1) -> some View {
        Text(style.uppercase ? text.uppercased() : text)
            .font(style.font(size))
            .tracking(style.tracking)
            .lineSpacing(style.lineSpacing)
            .allowsTightening(true)
            .foregroundStyle(ink.opacity(brightness))
            .shadow(color: shadowed ? .black.opacity(0.55) : .clear, radius: shadowed ? 4 : 0, y: shadowed ? 1 : 0)
    }

    private func pad(_ base: CGFloat) -> CGFloat { base * style.spacing.scale }

    @ViewBuilder private func progress(_ opacity: Double) -> some View {
        if style.showProgress, let start = state.lineStart, let end = state.lineEnd, end > start {
            // Animates by itself between updates, so it costs no extra activity updates.
            ProgressView(timerInterval: start...end, countsDown: false, label: { EmptyView() }, currentValueLabel: { EmptyView() })
                .progressViewStyle(.linear)
                .tint(style.accent.color.opacity(opacity))
        }
    }
}
