import CoreGraphics
import Foundation

/// Album art shrunk to 12×12 pixels for the card's blurred backdrop. Blurred art is only soft colour, so this
/// tiny copy looks the same once blurred. The widget can't download images, so the art travels inside each
/// update, and at 432 bytes it fits well within ActivityKit's 4 KB limit.
enum Artwork {
    static let side = 12

    /// Raw sRGB bytes (3 per pixel) of `image` scaled to side × side.
    static func thumbnail(of image: CGImage) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let base = context.data else { return nil }
        var rgb = Data(capacity: side * side * 3)
        for y in 0..<side {
            let row = base.advanced(by: y * context.bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<side { rgb.append(contentsOf: [row[x * 4], row[x * 4 + 1], row[x * 4 + 2]]) }
        }
        return rgb
    }

    static func image(from data: Data) -> CGImage? {
        guard data.count == side * side * 3, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: side * 3, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The thumbnail's average colour, which is roughly what the blurred backdrop shows behind the text.
    static func average(of data: Data) -> RGB? {
        guard data.count == side * side * 3 else { return nil }
        var sums = [0, 0, 0]
        for (index, byte) in data.enumerated() { sums[index % 3] += Int(byte) }
        let count = Float(side * side * 255)
        return RGB(red: Float(sums[0]) / count, green: Float(sums[1]) / count, blue: Float(sums[2]) / count)
    }

    /// A warm orange-to-violet field for the Appearance preview.
    static let sample: Data = {
        var rgb = Data(capacity: side * side * 3)
        for y in 0..<side {
            for x in 0..<side { rgb.append(contentsOf: [UInt8(240 - y * 12), UInt8(90 + x * 4), UInt8(60 + y * 14)]) }
        }
        return rgb
    }()
}
