import Foundation

/// "Surprise me" and the dice menu in Appearance: random looks that stay readable at a glance. A colour shuffle keeps
/// text at 4.5:1 or better and the accent at 3:1, like the presets; on album art, automatic text and a shadow handle
/// each song's cover. Thin weights and the script faces that blur at a glance are left out.
extension CardStyle {
    enum Shuffle: CaseIterable {
        case everything, colours, font, layout

        var title: String {
            switch self {
            case .everything: "Shuffle everything"
            case .colours: "Shuffle colours"
            case .font: "Shuffle font"
            case .layout: "Shuffle layout"
            }
        }

        var symbol: String {
            switch self {
            case .everything: "dice"
            case .colours: "paintpalette"
            case .font: "textformat"
            case .layout: "rectangle.3.group"
            }
        }
    }

    static let shuffleFaces = Typeface.allCases.filter { $0 != .savoye && $0 != .snellRoundhand }

    /// This style with the parts `what` names picked at random. Everything else, the update counter included, stays.
    func shuffled(_ what: Shuffle, using rng: inout some RandomNumberGenerator) -> CardStyle {
        var style = self
        if what == .everything || what == .layout { style.shuffleLayout(using: &rng) }
        if what == .everything || what == .font { style.shuffleFont(using: &rng) }
        if what == .everything || what == .colours { style.shuffleColours(using: &rng) }
        return style
    }

    private mutating func shuffleLayout(using rng: inout some RandomNumberGenerator) {
        layout = Layout.allCases.randomElement(using: &rng)!
        alignment = [Alignment.auto, .auto, .left, .center].randomElement(using: &rng)!
        spacing = Spacing.allCases.randomElement(using: &rng)!
        showSongInfo = Bool.random(using: &rng)
        showNext = true
        showProgress = Double.random(in: 0..<1, using: &rng) < 0.8
    }

    private mutating func shuffleFont(using rng: inout some RandomNumberGenerator) {
        typeface = Self.shuffleFaces.randomElement(using: &rng)!
        let sturdy = typeface.weights.filter { $0 != .light }
        weight = (sturdy.isEmpty ? typeface.weights : sturdy).randomElement(using: &rng)!
        uppercase = Double.random(in: 0..<1, using: &rng) < 0.25
        tracking = (uppercase ? [0.5, 1, 2, 3] : [0, 0, 0, 0.5]).randomElement(using: &rng)!
        lineSpacing = [0, 0, 2, 4].randomElement(using: &rng)!
        size = [0.9, 1, 1, 1.1, 1.2].randomElement(using: &rng)!
    }

    private mutating func shuffleColours(using rng: inout some RandomNumberGenerator) {
        // ponytail: draws until one passes the contrast checks; 50 tries practically always suffice, and if they
        // don't, the colours stay as they were rather than ever producing a hard-to-read card.
        for _ in 0..<50 {
            var style = self
            let hue = Double.random(in: 0..<1, using: &rng)
            // Mostly dark, since the card is read in a car at night; some vivid, a few light.
            let tone = Double.random(in: 0..<1, using: &rng)
            let (saturation, brightness): (ClosedRange<Double>, ClosedRange<Double>) =
                tone < 0.6 ? (0.35...0.9, 0.05...0.25) : tone < 0.85 ? (0.55...1, 0.6...0.95) : (0.04...0.2, 0.9...0.98)
            style.background = .hsb(hue, .random(in: saturation, using: &rng), .random(in: brightness, using: &rng))
            style.background2 = .hsb(hue + .random(in: -0.12...0.12, using: &rng), .random(in: saturation, using: &rng),
                                     .random(in: brightness, using: &rng))
            let roll = Double.random(in: 0..<1, using: &rng)
            style.backdrop = roll < 0.5 ? .color : roll < 0.85 ? .gradient : .albumArt
            style.artDarkness = .random(in: 0.35...0.65, using: &rng)
            style.dim = .random(in: 0.35...0.6, using: &rng)
            style.shadow = style.backdrop == .albumArt
            if style.backdrop == .albumArt {
                // Each cover differs, so automatic text picks white or near-black per song; a light accent shows on darkened art.
                style.autoText = true
                style.accent = .hsb(.random(in: 0..<1, using: &rng), .random(in: 0...0.5, using: &rng), .random(in: 0.85...1, using: &rng))
                self = style
                return
            }
            // Text and accent go light on dark backgrounds and dark on light ones, tinted with a random hue.
            let light = RGB.readable(on: style.backgroundSamples(art: nil)) == .white
            style.autoText = Bool.random(using: &rng)
            style.text = light
                ? .hsb(.random(in: 0..<1, using: &rng), .random(in: 0...0.3, using: &rng), .random(in: 0.92...1, using: &rng))
                : .hsb(.random(in: 0..<1, using: &rng), .random(in: 0.3...0.8, using: &rng), .random(in: 0.06...0.2, using: &rng))
            style.accent = light
                ? .hsb(.random(in: 0..<1, using: &rng), .random(in: 0.5...1, using: &rng), .random(in: 0.75...1, using: &rng))
                : .hsb(.random(in: 0..<1, using: &rng), .random(in: 0.6...1, using: &rng), .random(in: 0.25...0.5, using: &rng))
            if style.worstContrast(art: nil) < 4.5 { style.autoText = true }
            guard style.worstContrast(art: nil) >= 4.5 else { continue }
            let accent = style.backgroundSamples(art: nil).map { style.accent.contrast(with: $0) }.min() ?? 21
            if accent < 3 { style.accent = style.ink(art: nil) }
            self = style
            return
        }
    }
}

extension RGB {
    /// A colour from hue (wrapping, so any number works), saturation and brightness, each 0 to 1.
    static func hsb(_ hue: Double, _ saturation: Double, _ brightness: Double) -> RGB {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let c = brightness * saturation, x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = brightness - c
        let (r, g, b): (Double, Double, Double) = switch Int(h) {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        return RGB(red: Float(r + m), green: Float(g + m), blue: Float(b + m))
    }
}
