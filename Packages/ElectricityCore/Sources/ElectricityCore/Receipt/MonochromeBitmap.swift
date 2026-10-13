import CoreGraphics
import Foundation

/// A 1-bit image for printing (appendix R7.3): luminance below 128 is black, everything else white, no dithering.
/// Transparent pixels count as white paper.
public struct MonochromeBitmap: Sendable, Hashable {
    public let width: Int
    public let height: Int
    /// Rows of packed bits, most significant bit first, 1 for black. Each row is `bytesPerRow` long.
    public let bits: [UInt8]

    public var bytesPerRow: Int { (width + 7) / 8 }

    public static let threshold: UInt8 = 128

    public init(width: Int, height: Int, bits: [UInt8]) {
        precondition(bits.count == (width + 7) / 8 * height, "bits must hold every row")
        self.width = width
        self.height = height
        self.bits = bits
    }

    /// Converts an image: flattens it on white, reads 8-bit luminance, then applies the threshold.
    public init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let gray = data.bindMemory(to: UInt8.self, capacity: width * height)
        let rowBytes = (width + 7) / 8
        var bits = [UInt8](repeating: 0, count: rowBytes * height)
        for y in 0..<height {
            for x in 0..<width where gray[y * width + x] < Self.threshold {
                bits[y * rowBytes + x / 8] |= 0x80 >> UInt8(x % 8)
            }
        }
        self.init(width: width, height: height, bits: bits)
    }

    public func isBlack(x: Int, y: Int) -> Bool {
        bits[y * bytesPerRow + x / 8] & (0x80 >> UInt8(x % 8)) != 0
    }

    /// The bitmap as an 8-bit gray image holding only 0 and 255, for preview and system printing.
    public func cgImage() -> CGImage? {
        var pixels = [UInt8](repeating: 255, count: width * height)
        for y in 0..<height {
            for x in 0..<width where isBlack(x: x, y: y) { pixels[y * width + x] = 0 }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
