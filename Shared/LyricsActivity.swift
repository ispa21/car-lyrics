import ActivityKit
import Foundation
import SwiftUI

/// Shared by the app (starts/updates) and the widget extension (renders, including on CarPlay).
/// Everything lives in ContentState: one activity spans many songs, because a new
/// Live Activity can't be started while the app is in the background.
struct LyricsActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var current: String
        var next: String
        var previous = ""  // for the Karaoke layout
        var album = ""
        /// Between sung lines (an instrumental, the intro): the card shows the song instead of a lyric.
        var instrumental = false
        var lyrics: LyricsAvailability
        /// When the current line started and ends, so the card's progress bar animates on its own.
        var lineStart: Date?
        var lineEnd: Date?
        /// Increments on every update; shown small so a lagging or throttled display is visible.
        var seq: Int
        /// Chosen in the app's Appearance section. It travels in every update because the widget
        /// can't read the app's settings without an App Group, which free Apple IDs may not support.
        var style = CardStyle()
        /// 12×12 album art (see Artwork), for the blurred backdrop when chosen and the Dynamic Island's album tile.
        var art: Data? = nil
    }
}

extension LyricsActivityAttributes.ContentState {
    /// LRC files mark instrumental parts with an empty line or a lone music symbol.
    static func isInstrumental(_ text: String) -> Bool {
        text.allSatisfy { $0.isWhitespace || "♪♫♩♬🎵🎶…".contains($0) }
    }

    /// "Artist · Album", whichever are known.
    var details: String { [artist, album].filter { !$0.isEmpty }.joined(separator: " · ") }
}

/// How the lyrics card looks: everything the app's Appearance screen can change.
struct CardStyle: Codable, Hashable {
    enum Layout: String, Codable, CaseIterable {
        case minimal, big, detailed, karaoke

        var name: String {
            switch self {
            case .minimal: "Minimal"
            case .big: "Big"
            case .detailed: "Detailed"
            case .karaoke: "Karaoke"
            }
        }
    }

    /// San Francisco and New York, plus fonts built into iOS, so nothing has to be bundled.
    /// Family names were checked against the iOS 26.5 runtime's font files.
    enum Typeface: String, Codable, CaseIterable {
        case pro, condensed, rounded, serif, mono
        case avenirNext, avenirNextCondensed, helveticaNeue, futura, gillSans, optima, verdana, trebuchet
        case georgia, baskerville, palatino, hoeflerText, charter, didot, bodoni, cochin
        case dinAlternate, dinCondensed, copperplate, rockwell, americanTypewriter
        case menlo, courierNew
        case snellRoundhand, bradleyHand, noteworthy, markerFelt, savoye

        enum Category: String, CaseIterable {
            case system = "System fonts", sans = "Sans serif", serif = "Serif", display = "Display"
            case mono = "Monospaced", script = "Handwritten"
        }

        var category: Category {
            switch self {
            case .pro, .condensed, .rounded, .serif, .mono: .system
            case .avenirNext, .avenirNextCondensed, .helveticaNeue, .futura, .gillSans, .optima, .verdana, .trebuchet: .sans
            case .georgia, .baskerville, .palatino, .hoeflerText, .charter, .didot, .bodoni, .cochin: .serif
            case .dinAlternate, .dinCondensed, .copperplate, .rockwell, .americanTypewriter: .display
            case .menlo, .courierNew: .mono
            case .snellRoundhand, .bradleyHand, .noteworthy, .markerFelt, .savoye: .script
            }
        }

        /// The iOS font family; nil for the system's San Francisco and New York designs.
        var family: String? {
            switch self {
            case .pro, .condensed, .rounded, .serif, .mono: nil
            case .avenirNext: "Avenir Next"
            case .avenirNextCondensed: "Avenir Next Condensed"
            case .helveticaNeue: "Helvetica Neue"
            case .futura: "Futura"
            case .gillSans: "Gill Sans"
            case .optima: "Optima"
            case .verdana: "Verdana"
            case .trebuchet: "Trebuchet MS"
            case .georgia: "Georgia"
            case .baskerville: "Baskerville"
            case .palatino: "Palatino"
            case .hoeflerText: "Hoefler Text"
            case .charter: "Charter"
            case .didot: "Didot"
            case .bodoni: "Bodoni 72"
            case .cochin: "Cochin"
            case .dinAlternate: "DIN Alternate"
            case .dinCondensed: "DIN Condensed"
            case .copperplate: "Copperplate"
            case .rockwell: "Rockwell"
            case .americanTypewriter: "American Typewriter"
            case .menlo: "Menlo"
            case .courierNew: "Courier New"
            case .snellRoundhand: "Snell Roundhand"
            case .bradleyHand: "Bradley Hand"
            case .noteworthy: "Noteworthy"
            case .markerFelt: "Marker Felt"
            case .savoye: "Savoye LET"
            }
        }

        var name: String {
            switch self {
            case .pro: "SF Pro"
            case .condensed: "SF Condensed"
            case .rounded: "SF Rounded"
            case .serif: "New York"
            case .mono: "SF Mono"
            default: family ?? rawValue
            }
        }

        /// The weights the family really has (from the iOS font files). Asking SwiftUI for a weight a
        /// family lacks gives Regular, not the nearest face, so other weights snap to the nearest of these.
        var weights: [Weight] {
            switch self {
            case .pro, .condensed, .rounded, .serif, .mono: Weight.allCases
            case .avenirNext, .avenirNextCondensed: [.regular, .medium, .semibold, .bold, .heavy]
            case .helveticaNeue: [.light, .regular, .medium, .bold]
            case .gillSans: [.light, .regular, .semibold, .bold, .heavy]
            case .americanTypewriter: [.light, .regular, .semibold, .bold]
            case .baskerville: [.regular, .semibold, .bold]
            case .copperplate: [.light, .regular, .bold]
            case .optima, .charter, .snellRoundhand: [.regular, .bold, .heavy]
            case .hoeflerText: [.regular, .heavy]
            case .futura: [.medium, .bold]
            case .noteworthy, .markerFelt: [.light, .bold]
            case .dinAlternate, .dinCondensed, .bradleyHand: [.bold]
            case .savoye: [.regular]
            case .verdana, .trebuchet, .georgia, .palatino, .didot, .bodoni, .cochin, .rockwell, .menlo, .courierNew: [.regular, .bold]
            }
        }

        /// The weight this family really draws for `weight`: the nearest one it has.
        func nearest(_ weight: Weight) -> Weight {
            weights.min { abs($0.rank - weight.rank) < abs($1.rank - weight.rank) } ?? weight
        }

        func font(size: CGFloat, weight: Weight) -> Font {
            let weight = nearest(weight)
            return switch self {
            case .condensed: .system(size: size, weight: weight.value).width(.condensed)
            case .rounded: .system(size: size, weight: weight.value, design: .rounded)
            case .serif: .system(size: size, weight: weight.value, design: .serif)
            case .mono: .system(size: size, weight: weight.value, design: .monospaced)
            default: family.map { .custom($0, fixedSize: size).weight(weight.value) } ?? .system(size: size, weight: weight.value)
            }
        }
    }

    enum Weight: String, Codable, CaseIterable {
        case light, regular, medium, semibold, bold, heavy

        var name: String { rawValue.capitalized }
        var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

        var value: Font.Weight {
            switch self {
            case .light: .light
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            case .heavy: .heavy
            }
        }
    }

    enum Alignment: String, Codable, CaseIterable {
        case auto, left, center

        var name: String {
            switch self {
            case .auto: "Auto"
            case .left: "Left"
            case .center: "Centre"
            }
        }
    }

    enum Backdrop: String, Codable, CaseIterable {
        case color, gradient, albumArt

        var name: String {
            switch self {
            case .color: "Colour"
            case .gradient: "Gradient"
            case .albumArt: "Album art"
            }
        }
    }

    /// Breathing room around and between the card's text.
    enum Spacing: String, Codable, CaseIterable {
        case compact, regular, airy

        var name: String { rawValue.capitalized }
        var scale: CGFloat {
            switch self {
            case .compact: 0.7
            case .regular: 1
            case .airy: 1.4
            }
        }
    }

    var layout = Layout.big
    var typeface = Typeface.pro
    var weight = Weight.semibold
    var size = 1.0  // multiplies the layout's text sizes
    var tracking = 0.0  // letter spacing, in points
    var uppercase = false
    var alignment = Alignment.auto  // auto: centred for Big and Karaoke, left for Minimal and Detailed
    var lineSpacing = 0.0  // extra points between wrapped lines of a lyric
    var shadow = false  // soft shadow under lyrics, for busy album art
    var spacing = Spacing.regular
    var autoText = true  // pick white or near-black, whichever reads best on the background
    var text = RGB(red: 1, green: 1, blue: 1)  // used when autoText is off
    var accent = RGB(red: 1, green: 1, blue: 1)  // the progress bar
    var background = RGB(red: 0, green: 0, blue: 0)
    var background2 = RGB(red: 0.16, green: 0.16, blue: 0.18)  // the gradient's second colour
    var backdrop = Backdrop.color
    var artDarkness = 0.5  // black laid over blurred art so lyrics stay readable on bright covers
    var dim = 0.4  // brightness of the lines around the current one
    var showSongInfo = true  // Detailed and Karaoke
    var showNext = true  // Detailed
    var showProgress = true  // all but Minimal
    var showCounter = false  // the update number, for checking updates aren't dropped

    var centered: Bool { alignment == .center || (alignment == .auto && (layout == .big || layout == .karaoke)) }

    func font(_ size: CGFloat) -> Font { typeface.font(size: size * self.size, weight: weight) }

    /// The text colour actually drawn: the chosen one, or, when automatic, white or near-black,
    /// whichever has the higher WCAG contrast on this background (each song's album art included).
    func ink(art: Data?) -> RGB { autoText ? RGB.readable(on: backgroundSamples(art: art)) : text }

    /// The text's contrast where the background is hardest to read on.
    func worstContrast(art: Data?) -> Double {
        let ink = ink(art: art)
        return backgroundSamples(art: art).map { ink.contrast(with: $0) }.min() ?? 21
    }

    /// Automatic text gets a shadow where no single colour is readable enough: on album art, which has bright
    /// spots, and on backgrounds where even the better of white and near-black is below 4.5:1.
    func needsShadow(art: Data?) -> Bool {
        shadow || (autoText && (backdrop == .albumArt || worstContrast(art: art) < 4.5))
    }

    /// What the text sits on: the colour, both ends of the gradient, or the darkened album art's average.
    func backgroundSamples(art: Data?) -> [RGB] {
        switch backdrop {
        case .color: [background]
        case .gradient: [background, background2]
        case .albumArt: [art.flatMap(Artwork.average)?.darkened(by: artDarkness) ?? background]
        }
    }

    /// The groups of settings the Appearance screen can reset one at a time. The update counter is a testing switch
    /// (Troubleshooting), so no reset touches it.
    enum Part { case layout, text, font, colours, show }

    /// Puts one group of settings back to its defaults and leaves the rest alone.
    mutating func reset(_ part: Part) {
        let initial = CardStyle()
        switch part {
        case .layout:
            layout = initial.layout; alignment = initial.alignment; spacing = initial.spacing
        case .text:
            weight = initial.weight; size = initial.size; tracking = initial.tracking
            lineSpacing = initial.lineSpacing; uppercase = initial.uppercase; shadow = initial.shadow
        case .font:
            typeface = initial.typeface
        case .colours:
            autoText = initial.autoText; text = initial.text; accent = initial.accent; background = initial.background
            background2 = initial.background2; backdrop = initial.backdrop; artDarkness = initial.artDarkness
        case .show:
            showSongInfo = initial.showSongInfo; showNext = initial.showNext; showProgress = initial.showProgress; dim = initial.dim
        }
    }

    func isDefault(_ part: Part) -> Bool {
        var copy = self
        copy.reset(part)
        return copy == self
    }
}

/// An sRGB colour that saves and loads exactly. Color.Resolved stores linear values, so its
/// components drift slightly on every save.
struct RGB: Codable, Hashable {
    var red: Float
    var green: Float
    var blue: Float

    init(red: Float, green: Float, blue: Float) { self.red = red; self.green = green; self.blue = blue }
    init(_ resolved: Color.Resolved) { self.init(red: resolved.red, green: resolved.green, blue: resolved.blue) }

    init(hex: UInt32) {
        self.init(red: Float(hex >> 16 & 0xFF) / 255, green: Float(hex >> 8 & 0xFF) / 255, blue: Float(hex & 0xFF) / 255)
    }

    var color: Color { Color(.sRGB, red: Double(red), green: Double(green), blue: Double(blue)) }

    static let white = RGB(red: 1, green: 1, blue: 1)
    static let nearBlack = RGB(hex: 0x121212)

    /// White or near-black, whichever stays most readable on every one of `backgrounds`.
    static func readable(on backgrounds: [RGB]) -> RGB {
        func worst(_ ink: RGB) -> Double { backgrounds.map { ink.contrast(with: $0) }.min() ?? 21 }
        return worst(white) >= worst(nearBlack) ? white : nearBlack
    }

    /// This colour under black laid over it at `amount` opacity.
    func darkened(by amount: Double) -> RGB {
        let keep = Float(1 - amount)
        return RGB(red: red * keep, green: green * keep, blue: blue * keep)
    }

    /// WCAG contrast ratio, from 1 (identical) to 21 (black on white). 4.5 is the usual minimum for reading.
    func contrast(with other: RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private var luminance: Double {
        func linear(_ c: Float) -> Double { let c = Double(c); return c <= 0.040_45 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

/// Whether LRCLIB has lyrics for a song, shown on the card and in the app.
enum LyricsAvailability: String, Codable, Hashable, Sendable {
    case waiting, searching, synced, unsynced, missing, instrumental, offline

    var label: String {
        switch self {
        case .waiting: "Waiting"
        case .searching: "Searching"
        case .synced: "Synced"
        case .unsynced: "Not synced"
        case .missing: "No lyrics"
        case .instrumental: "Instrumental"
        case .offline: "Offline"
        }
    }

    var color: Color {
        switch self {
        case .synced: .green
        case .searching: .yellow
        case .unsynced: .orange
        case .instrumental: .cyan
        case .offline: .red
        case .waiting, .missing: .gray
        }
    }
}
