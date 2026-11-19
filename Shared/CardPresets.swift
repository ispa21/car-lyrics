import Foundation

/// Curated looks, from quiet to loud. Applying one replaces every card setting, and anything can still be changed afterwards.
/// Each pairs its text and background at 4.5:1 contrast or better (WCAG AA), since the card is read at a glance.
struct CardPreset: Identifiable {
    let name: String
    let style: CardStyle
    var id: String { name }

    static let all: [CardPreset] = [
        CardPreset(name: "Midnight", style: CardStyle()),
        CardPreset(name: "Caraoke", style: styled {
            $0.layout = .detailed; $0.typeface = .avenirNext
            $0.autoText = false; $0.text = RGB(hex: 0xF5F0E8); $0.background = RGB(hex: 0x1B1A18); $0.accent = RGB(hex: 0xF0553A); $0.dim = 0.45
        }),
        CardPreset(name: "Album", style: styled {
            $0.layout = .karaoke; $0.weight = .bold; $0.backdrop = .albumArt; $0.artDarkness = 0.55; $0.shadow = true
            $0.dim = 0.5; $0.showSongInfo = false; $0.showProgress = false
        }),
        CardPreset(name: "Road sign", style: styled {
            $0.typeface = .dinCondensed; $0.weight = .bold; $0.uppercase = true; $0.tracking = 1
            $0.background = RGB(hex: 0x0B4A33); $0.accent = RGB(hex: 0xFFD23F)
        }),
        CardPreset(name: "Editorial", style: styled {
            $0.layout = .minimal; $0.typeface = .serif; $0.weight = .medium; $0.size = 1.1; $0.lineSpacing = 4
            $0.autoText = false; $0.spacing = .airy; $0.text = RGB(hex: 0xF3EDE2); $0.background = RGB(hex: 0x121212)
        }),
        CardPreset(name: "Synthwave", style: styled {
            $0.typeface = .futura; $0.weight = .bold; $0.autoText = false; $0.text = RGB(hex: 0xFF5EC4); $0.accent = RGB(hex: 0x3EE6FF)
            $0.backdrop = .gradient; $0.background = RGB(hex: 0x1A0B3D); $0.background2 = RGB(hex: 0x0A1433)
        }),
        CardPreset(name: "Terminal", style: styled {
            $0.layout = .karaoke; $0.typeface = .menlo; $0.weight = .regular; $0.showSongInfo = false
            $0.autoText = false; $0.text = RGB(hex: 0xE6E6E6); $0.background = RGB(hex: 0x0D0F0D); $0.accent = RGB(hex: 0x7CFF6B)
        }),
        CardPreset(name: "Daylight", style: styled {
            $0.layout = .detailed; $0.typeface = .charter; $0.dim = 0.55
            $0.autoText = false; $0.text = RGB(hex: 0x1C1B19); $0.background = RGB(hex: 0xF5F0E8); $0.accent = RGB(hex: 0xC2410C)
        }),
        CardPreset(name: "Subtitles", style: styled {
            $0.layout = .minimal; $0.typeface = .helveticaNeue; $0.weight = .medium; $0.size = 1.15; $0.alignment = .center
            $0.autoText = false; $0.text = RGB(hex: 0xFFE14D)
        }),
        CardPreset(name: "Neon Tokyo", style: styled {
            $0.layout = .karaoke; $0.typeface = .condensed; $0.weight = .heavy; $0.uppercase = true; $0.tracking = 2
            $0.autoText = false; $0.text = RGB(hex: 0x00F0FF); $0.background = RGB(hex: 0x07020F); $0.accent = RGB(hex: 0xFF2BD6)
            $0.dim = 0.5; $0.showSongInfo = false
        }),
        CardPreset(name: "Sunset", style: styled {
            $0.typeface = .avenirNext; $0.weight = .heavy; $0.accent = RGB(hex: 0x121212)
            $0.backdrop = .gradient; $0.background = RGB(hex: 0xFF5F6D); $0.background2 = RGB(hex: 0xFFC371)
        }),
        CardPreset(name: "Love letter", style: styled {
            $0.layout = .minimal; $0.typeface = .snellRoundhand; $0.weight = .bold; $0.size = 1.25; $0.alignment = .center
            $0.spacing = .airy; $0.autoText = false; $0.text = RGB(hex: 0x8B1E3F); $0.background = RGB(hex: 0xFBE3E8); $0.accent = RGB(hex: 0x8B1E3F)
        }),
        CardPreset(name: "Typewriter", style: styled {
            $0.layout = .detailed; $0.typeface = .americanTypewriter; $0.weight = .regular; $0.lineSpacing = 2; $0.dim = 0.5
            $0.autoText = false; $0.text = RGB(hex: 0x2B2B2B); $0.background = RGB(hex: 0xF4ECD8); $0.accent = RGB(hex: 0xB23A2A)
        }),
        CardPreset(name: "Gold", style: styled {
            $0.typeface = .didot; $0.weight = .bold; $0.uppercase = true; $0.tracking = 3
            $0.autoText = false; $0.text = RGB(hex: 0xE6C068); $0.background = RGB(hex: 0x0B0B0B); $0.accent = RGB(hex: 0xE6C068)
        }),
        CardPreset(name: "Comic", style: styled {
            $0.typeface = .markerFelt; $0.weight = .bold; $0.uppercase = true
            $0.background = RGB(hex: 0xFFE600); $0.accent = RGB(hex: 0x121212)
        }),
        CardPreset(name: "Blueprint", style: styled {
            $0.layout = .detailed; $0.typeface = .courierNew; $0.weight = .bold; $0.tracking = 0.5; $0.spacing = .compact
            $0.autoText = false; $0.text = RGB(hex: 0xE8F1FF); $0.background = RGB(hex: 0x0B3D91); $0.accent = RGB(hex: 0x8EC5FF)
        }),
        CardPreset(name: "Brutalist", style: styled {
            $0.typeface = .condensed; $0.weight = .heavy; $0.uppercase = true; $0.tracking = -0.5; $0.alignment = .left
            $0.background = RGB(hex: 0xFF4F00); $0.accent = RGB(hex: 0x121212)
        }),
        CardPreset(name: "Poster", style: styled {
            $0.typeface = .futura; $0.weight = .heavy; $0.uppercase = true; $0.size = 1.1; $0.alignment = .left
            $0.backdrop = .albumArt; $0.artDarkness = 0.25
        }),
        CardPreset(name: "Ocean", style: styled {
            $0.layout = .karaoke; $0.typeface = .gillSans; $0.dim = 0.45; $0.accent = RGB(hex: 0x7FDBFF)
            $0.backdrop = .gradient; $0.background = RGB(hex: 0x0F2027); $0.background2 = RGB(hex: 0x2C5364)
        }),
        CardPreset(name: "Whisper", style: styled {
            $0.layout = .minimal; $0.typeface = .avenirNext; $0.weight = .regular; $0.size = 1.2; $0.lineSpacing = 6
            $0.spacing = .airy; $0.autoText = false; $0.text = RGB(hex: 0xEDEDED)
        }),
    ]

    private static func styled(_ change: (inout CardStyle) -> Void) -> CardStyle {
        var style = CardStyle()
        change(&style)
        return style
    }
}
