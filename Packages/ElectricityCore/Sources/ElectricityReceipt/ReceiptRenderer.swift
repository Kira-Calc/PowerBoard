import AppKit
import ElectricityCore
import SwiftUI

/// The receipt on paper for PNG export (appendix R3.5): off-white, torn top and bottom edges, a faint shadow and a
/// transparent margin. No texture.
public struct ReceiptPaperView<Content: View>: View {
    public static var margin: CGFloat { 32 }
    static var paperColor: Color { Color(red: 0xFB / 255, green: 0xFA / 255, blue: 0xF7 / 255) }

    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(.vertical, TornEdge.toothHeight)
            .background(TornEdge().fill(Self.paperColor).shadow(color: .black.opacity(0.12), radius: 6, y: 2))
            .padding(Self.margin)
    }
}

/// A rectangle with saw-tooth top and bottom edges: teeth 8 dots wide and 4 dots high.
struct TornEdge: Shape {
    static let toothWidth: CGFloat = 8
    static let toothHeight: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        let teeth = max(1, Int((rect.width / Self.toothWidth).rounded()))
        let step = rect.width / CGFloat(teeth)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + Self.toothHeight))
        for index in 0..<teeth {
            let x = rect.minX + CGFloat(index) * step
            path.addLine(to: CGPoint(x: x + step / 2, y: rect.minY))
            path.addLine(to: CGPoint(x: x + step, y: rect.minY + Self.toothHeight))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - Self.toothHeight))
        for index in (0..<teeth).reversed() {
            let x = rect.minX + CGFloat(index) * step
            path.addLine(to: CGPoint(x: x + step / 2, y: rect.maxY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY - Self.toothHeight))
        }
        path.closeSubpath()
        return path
    }
}

/// Renders receipts to PNG and to the 1-bit bitmap used for printing.
@MainActor
public enum ReceiptRenderer {
    public struct RenderError: Error {}

    /// PNG at 2x: 1152 pixels across the 576 dots of 80 mm paper, plus the margin when the paper effect is on.
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
            renderer = ImageRenderer(content: AnyView(ReceiptPaperView {
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
