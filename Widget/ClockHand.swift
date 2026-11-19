import LyricsCore
import SwiftUI

extension View {
    /// Shows this view only from `start` to `end`: the slice of a huge ring that WidgetKit's clock hand turns past
    /// 12 o'clock then. `base` is the entry's date. The slice's edge crosses the view left to right in `wipe` seconds,
    /// centred on the change; back-to-back slices tile, so exactly one stretch shows at a time.
    func live(from start: Date, to end: Date, base: Date, size: CGSize, period: Double = 120, wipe: Double = 0.25) -> some View {
        // The edge sweeps width / radius radians in `wipe` seconds, turning 2π / period radians a second.
        let radius = size.width * period / (2 * .pi * wipe)
        let slice = RingSector(start: -LiveSchedule.angle(at: end, period: period, base: base),
                               end: -LiveSchedule.angle(at: start, period: period, base: base),
                               radius: radius, thickness: size.height)
        return mask {
            ClockHand.rotating(slice.frame(width: size.width, height: size.height), period: period)
                .offset(y: radius)  // the ring's centre far below, so its top passes over the view
        }
    }
}

/// WidgetKit's clock-hand rotation, the effect that turns the Clock widget's hands. The Home Screen keeps rotating
/// the view by itself, so a widget can change on time between timeline entries, without reloads.
///
/// ponytail: private API. Since the iOS 26.1 SDK, WidgetKit's `View._clockHandRotationEffect` leaves the view
/// unrotated unless the app is Apple's Clock (it checks `dyld_program_sdk_at_least`), but the modifier type itself
/// still works, so this decodes it the way the Home Screen does when it unarchives a widget. On CarPlay, and with the
/// subdued glass look, WidgetKit pauses hands that turn once a minute or faster, so keep `period` above 60 s.
/// If a later iOS renames or reshapes the type, `available` turns false and the widget falls back to timeline entries.
enum ClockHand {
    private static var type: (any (ViewModifier & Decodable).Type)? {
        _typeByName("9WidgetKit24_ClockHandRotationEffectV") as? any (ViewModifier & Decodable).Type
    }

    static var available: Bool { type.map { modifier($0, period: 120) != nil } ?? false }

    /// `content` turned clockwise about its centre once every `period` seconds: at 360° × (Unix time mod period)
    /// / period from 12 o'clock, so pick a period that divides a day.
    @MainActor static func rotating(_ content: some View, period: Double) -> AnyView {
        guard let type else { return AnyView(content) }
        return apply(type, period: period, to: content)
    }

    @MainActor private static func apply<M: ViewModifier & Decodable>(_ type: M.Type, period: Double, to content: some View) -> AnyView {
        modifier(type, period: period).map { AnyView(content.modifier($0)) } ?? AnyView(content)
    }

    private static func modifier<M: Decodable>(_: M.Type, period: Double) -> M? {
        let json = #"{"anchor":[0.5,0.5],"period":\#(period),"timeZone":{"identifier":"GMT"}}"#
        return try? JSONDecoder().decode(M.self, from: Data(json.utf8))
    }
}

/// The part of a ring from `start` to `end` (degrees clockwise from 12 o'clock), centred in its frame and
/// `thickness` deep on each side of `radius`.
struct RingSector: Shape {
    let start: Double
    let end: Double
    let radius: CGFloat
    let thickness: CGFloat

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.addArc(center: centre, radius: radius + thickness, startAngle: .degrees(start - 90), endAngle: .degrees(end - 90), clockwise: false)
        path.addArc(center: centre, radius: radius - thickness, startAngle: .degrees(end - 90), endAngle: .degrees(start - 90), clockwise: true)
        path.closeSubpath()
        return path
    }
}
