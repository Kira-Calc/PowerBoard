import AppKit
import ElectricityCore
import SwiftUI

/// The receipt on paper for PNG export (appendix R3.5, made more lifelike at the user's request): warm thermal
/// paper with uneven torn ends, slightly darker towards the curled sides, a fine grain, print a touch lighter than
/// pure black, and a contact shadow under a soft lift shadow on a transparent margin. Printing never uses any of it.
public struct ReceiptPaperView<Content: View>: View {
    public static var margin: CGFloat { 40 }
    static var paperColor: Color { Color(red: 0xF8 / 255, green: 0xF6 / 255, blue: 0xF0 / 255) }
    /// Thermal print is a very dark grey, not ink black.
    static var printOpacity: Double { 0.86 }

    let sideMargin: CGFloat
    let content: Content

    public init(sideMargin: CGFloat, @ViewBuilder content: () -> Content) {
        self.sideMargin = sideMargin
        self.content = content()
    }

    public var body: some View {
        content
            .opacity(Self.printOpacity)
            .padding(.horizontal, sideMargin)
            .padding(.vertical, TornEdge.maxDepth + 4)
            .background { paper }
            .padding(Self.margin)
    }

    private var paper: some View {
        ZStack {
            TornEdge().fill(Self.paperColor)
            // The sides curl away from the light a little.
            TornEdge().fill(LinearGradient(stops: [
                .init(color: .black.opacity(0.07), location: 0),
                .init(color: .black.opacity(0.015), location: 0.06),
                .init(color: .clear, location: 0.2),
                .init(color: .clear, location: 0.8),
                .init(color: .black.opacity(0.015), location: 0.94),
                .init(color: .black.opacity(0.08), location: 1),
            ], startPoint: .leading, endPoint: .trailing))
            // A broad, faint sheen across the sheet.
            TornEdge().fill(LinearGradient(stops: [
                .init(color: .white.opacity(0), location: 0.2),
                .init(color: .white.opacity(0.45), location: 0.45),
                .init(color: .white.opacity(0), location: 0.7),
            ], startPoint: .topLeading, endPoint: .bottomTrailing))
            if let grain = PaperGrain.image {
                Image(decorative: grain, scale: 2)
                    .resizable(resizingMode: .tile)
                    .blendMode(.multiply)
                    .opacity(0.5)
                    .clipShape(TornEdge())
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.28), radius: 0.8, y: 0.6)
        .shadow(color: .black.opacity(0.14), radius: 14, y: 10)
    }
}

/// A strip with torn top and bottom ends: teeth of uneven width and depth, the same on every render.
struct TornEdge: Shape {
    static let maxDepth: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let top = Self.teeth(width: rect.width, seed: 7)
        let bottom = Self.teeth(width: rect.width, seed: 19)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + Self.maxDepth))
        for point in top { path.addLine(to: CGPoint(x: rect.minX + point.x, y: rect.minY + point.y)) }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - Self.maxDepth))
        for point in bottom.reversed() { path.addLine(to: CGPoint(x: rect.minX + point.x, y: rect.maxY - point.y)) }
        path.closeSubpath()
        return path
    }

    /// Points along one torn end, as (x, depth from the outer edge): peaks reach 0 to 2 dots from the edge,
    /// valleys 4 to 7 dots in, 5 to 11 dots apart.
    static func teeth(width: CGFloat, seed: UInt64) -> [CGPoint] {
        var random = SeededRandom(seed: seed)
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var peak = true
        while x < width {
            x = min(width, x + CGFloat(random.next(in: 5...11)) / 2)
            let depth = peak ? CGFloat(random.next(in: 0...2)) : CGFloat(random.next(in: 4...7))
            points.append(CGPoint(x: x, y: depth))
            peak.toggle()
        }
        return points
    }
}

/// A small, fixed noise tile for the paper's grain.
enum PaperGrain {
    static let image: CGImage? = {
        let side = 128
        var random = SeededRandom(seed: 42)
        let pixels = (0..<side * side).map { _ in UInt8(235 + random.next(in: 0...20)) }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()
}

/// A tiny linear congruential generator, so the torn edges and grain look the same in every export.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }

    mutating func next(in range: ClosedRange<Int>) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return range.lowerBound + Int((state >> 33) % UInt64(range.count))
    }
}

/// Renders receipts to PNG and to the 1-bit bitmap used for printing.
@MainActor
public enum ReceiptRenderer {
    public struct RenderError: Error {}

    /// PNG at 2x: 1152 pixels across the 576 dots of 80 mm paper; with the paper effect, plus the paper's blank
    /// sides and the transparent margin.
    public static func png(model: ReceiptModel, paper: ReceiptPaper, logo: ReceiptLogo, paperEffect: Bool) throws -> Data {
        guard let image = image(model: model, paper: paper, logo: logo, paperEffect: paperEffect, scale: 2),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw RenderError() }
        return data
    }

    /// The receipt as an image. With the paper effect it has a transparent margin; without it, a white page.
    public static func image(model: ReceiptModel, paper: ReceiptPaper, logo: ReceiptLogo, paperEffect: Bool, scale: CGFloat) -> CGImage? {
        let renderer: ImageRenderer<AnyView>
        if paperEffect {
            renderer = ImageRenderer(content: AnyView(ReceiptPaperView(sideMargin: paper.sideMarginDots) {
                ReceiptView(model: model, paper: paper, logo: logo, background: .clear)
            }.fixedSize()))
        } else {
            renderer = ImageRenderer(content: AnyView(ReceiptView(model: model, paper: paper, logo: logo).fixedSize()))
        }
        renderer.scale = scale
        renderer.isOpaque = !paperEffect
        return renderer.cgImage
    }

    /// One dot per pixel, white paper, converted to pure black and white (R7.1, R7.3).
    public static func printBitmap(model: ReceiptModel, paper: ReceiptPaper, logo: ReceiptLogo) -> MonochromeBitmap? {
        image(model: model, paper: paper, logo: logo, paperEffect: false, scale: 1).flatMap(MonochromeBitmap.init)
    }
}
