// Draws the receipt logo (appendix R5): the app icon's plug in flat black, for thermal printing.
// Pure black on a transparent background, no grey: the bolt and the prong holes are cut out, and the
// icon's rounded square becomes an outline. Lines stay thicker than 3 dots at the 72-dot size.
// Usage: swift scripts/make-receipt-logo.swift <output.pdf>
// Coordinates follow scripts/make-icon.swift (1024 x 1024 canvas, origin at the top left).
import AppKit
import CoreGraphics

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ReceiptLogo.pdf"
// The page is 96 points, the logo size on 80 mm paper.
let side: CGFloat = 96
var box = CGRect(x: 0, y: 0, width: side, height: side)
let context = CGContext(URL(fileURLWithPath: output) as CFURL, mediaBox: &box, nil)!
context.beginPDFPage(nil)
let scale = side / 1024
context.scaleBy(x: scale, y: scale)
context.translateBy(x: 0, y: 1024)
context.scaleBy(x: 1, y: -1)
context.setFillColor(CGColor(gray: 0, alpha: 1))
context.setStrokeColor(CGColor(gray: 0, alpha: 1))

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// The tile as an outline, slightly inside the page so the stroke is not cut.
let tile = CGRect(x: 40, y: 40, width: 944, height: 944)
let stroke: CGFloat = 44
context.addPath(rounded(tile.insetBy(dx: stroke / 2, dy: stroke / 2), 205))
context.setLineWidth(stroke)
context.strokePath()

// The plug, turned 45 degrees as on the icon, clipped to a gap inside the outline.
context.saveGState()
context.addPath(rounded(tile.insetBy(dx: stroke + 34, dy: stroke + 34), 160))
context.clip()
context.translateBy(x: 548, y: 470)
context.rotate(by: .pi / 4)
context.translateBy(x: -512, y: -445)

// Cable and strain relief.
context.addPath(CGPath(rect: CGRect(x: 477, y: 640, width: 70, height: 900), transform: nil))
let sleeve = CGMutablePath()
sleeve.move(to: CGPoint(x: 452, y: 600))
sleeve.addLine(to: CGPoint(x: 572, y: 600))
sleeve.addCurve(to: CGPoint(x: 545, y: 700), control1: CGPoint(x: 572, y: 650), control2: CGPoint(x: 552, y: 680))
sleeve.addLine(to: CGPoint(x: 479, y: 700))
sleeve.addCurve(to: CGPoint(x: 452, y: 600), control1: CGPoint(x: 472, y: 680), control2: CGPoint(x: 452, y: 650))
sleeve.closeSubpath()
context.addPath(sleeve)
context.fillPath()

// Prongs with their holes cut out (even-odd fill).
for x in [CGFloat(400), 568] {
    let prong = CGMutablePath()
    prong.addPath(rounded(CGRect(x: x, y: 190, width: 56, height: 220), 10))
    prong.addEllipse(in: CGRect(x: x + 12, y: 222, width: 32, height: 32))
    context.addPath(prong)
    context.fillPath(using: .evenOdd)
}

// Body with the lightning bolt cut out.
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
// The bolt from the icon, slightly enlarged around its centre so its thinnest part stays above 3 dots.
let grow = CGAffineTransform(translationX: 513, y: 508).scaledBy(x: 1.08, y: 1.08).translatedBy(x: -513, y: -508)
let bolt = CGMutablePath()
bolt.move(to: CGPoint(x: 528, y: 432), transform: grow)
bolt.addLine(to: CGPoint(x: 470, y: 520), transform: grow)
bolt.addLine(to: CGPoint(x: 512, y: 520), transform: grow)
bolt.addLine(to: CGPoint(x: 496, y: 584), transform: grow)
bolt.addLine(to: CGPoint(x: 556, y: 492), transform: grow)
bolt.addLine(to: CGPoint(x: 514, y: 492), transform: grow)
bolt.closeSubpath()
let cut = CGMutablePath()
cut.addPath(body)
cut.addPath(bolt)
context.addPath(cut)
context.fillPath(using: .evenOdd)
context.restoreGState()

context.endPDFPage()
context.closePDF()
print("wrote \(output)")
