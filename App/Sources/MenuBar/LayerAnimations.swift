import AppKit
import SwiftUI

// Looping indicators drawn with Core Animation. The animation runs in the window server, so the app does no work per
// frame. The SwiftUI versions (a `TimelineView` redrawing 30 times a second) kept the app at 25 to 35 % CPU while a
// tool was working, because the menu bar label and every list around them were re-evaluated on each frame.

/// A thin track with a light band sliding across it, like a page loading bar. One pass every 1.2 seconds.
/// With Reduce Motion the band stays in the middle.
struct ActivityBar: NSViewRepresentable {
    func makeNSView(context: Context) -> SlidingBandView { SlidingBandView() }
    func updateNSView(_ view: SlidingBandView, context: Context) {}
}

/// A ring with a gap that spins once every 0.9 seconds, like a page loading indicator.
/// With Reduce Motion it stands still.
struct SpinningRing: NSViewRepresentable {
    var diameter: CGFloat = 10
    var lineWidth: CGFloat = 1.8

    func makeNSView(context: Context) -> SpinningRingView { SpinningRingView(diameter: diameter, lineWidth: lineWidth) }
    func updateNSView(_ view: SpinningRingView, context: Context) {}
}

/// Base for the two views: colors follow the appearance (the menu bar can be light or dark), and the animation is
/// added again whenever the view gets a window, since Core Animation drops it when the layer leaves the screen.
class LoopingLayerView: NSView {
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    override func layout() {
        super.layout()
        refresh()
    }

    /// Resolves a dynamic system color for this view's appearance.
    func cgColor(_ color: NSColor, alpha: CGFloat = 1) -> CGColor {
        var result = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            result = color.withAlphaComponent(color.alphaComponent * alpha).cgColor
        }
        return result
    }

    /// Lays out the sublayers, sets their colors and (re)starts the animation.
    func refresh() {}
}

final class SlidingBandView: LoopingLayerView {
    private let track = CALayer()
    private let band = CAGradientLayer()
    private var animatedWidth: CGFloat = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.addSublayer(track)
        track.addSublayer(band)
        track.masksToBounds = true
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
    }

    override func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let width = bounds.width
        let bandWidth = max(width * 0.4, 8)
        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        track.backgroundColor = cgColor(.labelColor, alpha: 0.15)
        band.colors = [cgColor(.labelColor, alpha: 0), cgColor(.labelColor), cgColor(.labelColor, alpha: 0)]
        band.bounds = CGRect(x: 0, y: 0, width: bandWidth, height: bounds.height)
        band.cornerRadius = bounds.height / 2
        band.position = CGPoint(x: width / 2, y: bounds.midY)

        guard width > 0, window != nil, !reduceMotion else {
            band.removeAllAnimations()
            animatedWidth = -1
            return
        }
        // Restart only when the size changed or the animation was dropped.
        guard animatedWidth != width || band.animation(forKey: "slide") == nil else { return }
        animatedWidth = width
        let slide = CABasicAnimation(keyPath: "position.x")
        slide.fromValue = -bandWidth / 2
        slide.toValue = width + bandWidth / 2
        slide.duration = 1.2
        slide.repeatCount = .infinity
        band.add(slide, forKey: "slide")
    }
}

final class SpinningRingView: LoopingLayerView {
    private let ring = CAShapeLayer()
    private let diameter: CGFloat
    private let lineWidth: CGFloat

    init(diameter: CGFloat, lineWidth: CGFloat) {
        self.diameter = diameter
        self.lineWidth = lineWidth
        super.init(frame: .zero)
        layer?.addSublayer(ring)
        ring.fillColor = nil
        ring.lineCap = .round
        ring.strokeEnd = 0.72
    }

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    override func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let rect = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        ring.bounds = rect
        ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
        ring.path = CGPath(ellipseIn: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), transform: nil)
        ring.lineWidth = lineWidth
        ring.strokeColor = cgColor(.secondaryLabelColor)

        guard window != nil, !reduceMotion else {
            ring.removeAllAnimations()
            return
        }
        guard ring.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        // Negative turns clockwise in AppKit's unflipped coordinates.
        spin.toValue = -2 * Double.pi
        spin.duration = 0.9
        spin.repeatCount = .infinity
        ring.add(spin, forKey: "spin")
    }
}
