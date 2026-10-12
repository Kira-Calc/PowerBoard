// Draws the PowerBoard app icon: a skeuomorphic electric plug on a white rounded square.
// Usage: swift scripts/make-icon.swift <output.png> [size]
// The drawing is resolution independent; all coordinates are on a 1024 x 1024 canvas.
import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
let output = arguments.count > 1 ? arguments[1] : "icon.png"
let size = arguments.count > 2 ? Int(arguments[2]) ?? 1024 : 1024

let space = CGColorSpace(name: CGColorSpace.displayP3)!
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let scale = CGFloat(size) / 1024
context.scaleBy(x: scale, y: scale)
// Draw with the origin at the top left, like a design tool.
context.translateBy(x: 0, y: 1024)
context.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

func linear(_ stops: [(CGFloat, CGColor)], from start: CGPoint, to end: CGPoint, in path: CGPath) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
    context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

func radial(_ stops: [(CGFloat, CGColor)], center: CGPoint, radius: CGFloat, in path: CGPath) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
    context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                               options: [.drawsAfterEndLocation])
    context.restoreGState()
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: Background: white rounded square on the macOS icon grid (824 pt inside a 1024 canvas).

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = rounded(tile, 185)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x000000, 0.28))
context.addPath(tilePath)
context.setFillColor(color(0xFFFFFF))
context.fillPath()
context.restoreGState()
linear([(0, color(0xFFFFFF)), (0.7, color(0xF7F7F5)), (1, color(0xECECE9))],
       from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924), in: tilePath)
// Thin inner edge so the white tile reads on a white desktop.
context.addPath(rounded(tile.insetBy(dx: 1.5, dy: 1.5), 184))
context.setStrokeColor(color(0x000000, 0.08))
context.setLineWidth(3)
context.strokePath()

// MARK: The plug is drawn upright in its own coordinates, then turned 45 degrees (prongs to the upper right)
// and clipped to the tile, so the straight cable runs off the lower left edge.

context.saveGState()
context.addPath(tilePath)
context.clip()
context.translateBy(x: 548, y: 470)
context.rotate(by: .pi / 4)
context.translateBy(x: -512, y: -445)

// MARK: Cable: a straight cylinder, drawn first so the plug body covers its end.

let cable = CGRect(x: 483, y: 640, width: 58, height: 900)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -14), blur: 24, color: color(0x000000, 0.22))
context.addPath(CGPath(rect: cable, transform: nil))
context.setFillColor(color(0x1C1D20))
context.fillPath()
context.restoreGState()
linear([(0, color(0x111215)), (0.25, color(0x3B3E45)), (0.4, color(0x6B707A)), (0.55, color(0x2C2E33)), (1, color(0x0E0F11))],
       from: CGPoint(x: 483, y: 0), to: CGPoint(x: 541, y: 0), in: CGPath(rect: cable, transform: nil))

// Strain relief: a short tapered sleeve between body and cable.
let sleeve = CGMutablePath()
sleeve.move(to: CGPoint(x: 452, y: 600))
sleeve.addLine(to: CGPoint(x: 572, y: 600))
sleeve.addCurve(to: CGPoint(x: 545, y: 700), control1: CGPoint(x: 572, y: 650), control2: CGPoint(x: 552, y: 680))
sleeve.addLine(to: CGPoint(x: 479, y: 700))
sleeve.addCurve(to: CGPoint(x: 452, y: 600), control1: CGPoint(x: 472, y: 680), control2: CGPoint(x: 452, y: 650))
sleeve.closeSubpath()
linear([(0, color(0x17181B)), (0.35, color(0x4A4D55)), (0.55, color(0x2D2F34)), (1, color(0x141518))],
       from: CGPoint(x: 452, y: 0), to: CGPoint(x: 572, y: 0), in: sleeve)
for y in stride(from: 625.0, through: 685.0, by: 20.0) {
    context.move(to: CGPoint(x: 462 + (y - 600) * 0.17, y: y))
    context.addLine(to: CGPoint(x: 562 - (y - 600) * 0.17, y: y))
}
context.setStrokeColor(color(0x000000, 0.45))
context.setLineWidth(4)
context.strokePath()

// MARK: Prongs: two brass blades with a hole near the tip.

func prong(x: CGFloat) {
    let blade = rounded(CGRect(x: x, y: 190, width: 56, height: 200), 10)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 6, height: 10), blur: 14, color: color(0x000000, 0.25))
    context.addPath(blade)
    context.setFillColor(color(0xB98A3A))
    context.fillPath()
    context.restoreGState()
    linear([(0, color(0x8C6420)), (0.22, color(0xF3D79A)), (0.45, color(0xD2A757)), (0.75, color(0xA77A2C)), (1, color(0x7A5518))],
           from: CGPoint(x: x, y: 0), to: CGPoint(x: x + 56, y: 0), in: blade)
    // Tip bevel.
    linear([(0, color(0xFFFFFF, 0.55)), (1, color(0xFFFFFF, 0))],
           from: CGPoint(x: 0, y: 190), to: CGPoint(x: 0, y: 214), in: blade)
    // Hole.
    let hole = CGPath(ellipseIn: CGRect(x: x + 15, y: 226, width: 26, height: 26), transform: nil)
    radial([(0, color(0x3A2A0E)), (0.7, color(0x5B4216)), (1, color(0x8C6420))],
           center: CGPoint(x: x + 30, y: 241), radius: 14, in: hole)
    context.addPath(CGPath(ellipseIn: CGRect(x: x + 15, y: 226, width: 26, height: 26), transform: nil))
    context.setStrokeColor(color(0xFFF1CC, 0.6))
    context.setLineWidth(2)
    context.strokePath()
}
prong(x: 400)
prong(x: 568)

// MARK: Plug body: a rounded block in dark graphite plastic.

let body = CGMutablePath()
body.move(to: CGPoint(x: 330, y: 380))
body.addLine(to: CGPoint(x: 694, y: 380))
body.addQuadCurve(to: CGPoint(x: 734, y: 420), control: CGPoint(x: 734, y: 380))
body.addLine(to: CGPoint(x: 734, y: 500))
body.addCurve(to: CGPoint(x: 600, y: 620), control1: CGPoint(x: 734, y: 580), control2: CGPoint(x: 680, y: 620))
body.addLine(to: CGPoint(x: 424, y: 620))
body.addCurve(to: CGPoint(x: 290, y: 500), control1: CGPoint(x: 344, y: 620), control2: CGPoint(x: 290, y: 580))
body.addLine(to: CGPoint(x: 290, y: 420))
body.addQuadCurve(to: CGPoint(x: 330, y: 380), control: CGPoint(x: 290, y: 380))
body.closeSubpath()

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 22), blur: 40, color: color(0x000000, 0.35))
context.addPath(body)
context.setFillColor(color(0x24262B))
context.fillPath()
context.restoreGState()
// Side shading, left to right.
linear([(0, color(0x16171A)), (0.18, color(0x3A3D44)), (0.5, color(0x2C2F35)), (0.85, color(0x1F2125)), (1, color(0x111215))],
       from: CGPoint(x: 290, y: 0), to: CGPoint(x: 734, y: 0), in: body)
// Top face catching light.
linear([(0, color(0xFFFFFF, 0.28)), (0.18, color(0xFFFFFF, 0.06)), (0.6, color(0xFFFFFF, 0)), (1, color(0x000000, 0.25))],
       from: CGPoint(x: 0, y: 380), to: CGPoint(x: 0, y: 620), in: body)
// Rim at the front face where the prongs come out.
let rim = rounded(CGRect(x: 300, y: 384, width: 424, height: 24), 12)
linear([(0, color(0xFFFFFF, 0.35)), (1, color(0xFFFFFF, 0))], from: CGPoint(x: 0, y: 384), to: CGPoint(x: 0, y: 408), in: rim)

// Soft highlight on the upper left of the face.
radial([(0, color(0xFFFFFF, 0.14)), (1, color(0xFFFFFF, 0))], center: CGPoint(x: 430, y: 440), radius: 170, in: body)

// Grip ridges on both sides.
for side in [CGFloat(318), 690] {
    for y in stride(from: 440.0, through: 520.0, by: 20.0) {
        let ridge = rounded(CGRect(x: side, y: y, width: 16, height: 8), 4)
        context.addPath(ridge)
        context.setFillColor(color(0x000000, 0.35))
        context.fillPath()
        context.addPath(rounded(CGRect(x: side, y: y + 8, width: 16, height: 3), 1.5))
        context.setFillColor(color(0xFFFFFF, 0.10))
        context.fillPath()
    }
}

// Energy mark: a lightning bolt pressed into the face, in the app's orange.
let bolt = CGMutablePath()
bolt.move(to: CGPoint(x: 528, y: 432))
bolt.addLine(to: CGPoint(x: 470, y: 520))
bolt.addLine(to: CGPoint(x: 512, y: 520))
bolt.addLine(to: CGPoint(x: 496, y: 584))
bolt.addLine(to: CGPoint(x: 556, y: 492))
bolt.addLine(to: CGPoint(x: 514, y: 492))
bolt.closeSubpath()
context.saveGState()
context.translateBy(x: 0, y: 3)
context.addPath(bolt)
context.setFillColor(color(0x000000, 0.5))
context.fillPath()
context.restoreGState()
linear([(0, color(0xFFC15A)), (0.5, color(0xF59A2C)), (1, color(0xE07614))],
       from: CGPoint(x: 0, y: 432), to: CGPoint(x: 0, y: 584), in: bolt)
context.addPath(bolt)
context.setStrokeColor(color(0xFFE2A8, 0.7))
context.setLineWidth(2)
context.strokePath()

context.restoreGState()

let image = context.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output) (\(size) px)")
