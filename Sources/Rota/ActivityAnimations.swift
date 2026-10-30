import AppKit
import SwiftUI

// Progress animations run as Core Animation on their own layers. Any SwiftUI-driven
// animation, a per-frame timeline or a repeating animation alike, made SwiftUI re-rasterize
// every text in the same hosting view on each display frame: an open running session
// took most of a core, more the longer its transcript.

/// An arc turning clockwise once every 1.2 s, as the run indicators show; static under Reduce Motion.
struct SpinnerArc: NSViewRepresentable {
    /// The visible share of the circle, as `Circle().trim(from: 0, to: length)`.
    let length: CGFloat
    let lineWidth: CGFloat
    let color: NSColor

    func makeNSView(context: Context) -> SpinnerArcView { SpinnerArcView() }

    func updateNSView(_ view: SpinnerArcView, context: Context) {
        view.configure(length: length, lineWidth: lineWidth, color: color,
                       animated: !context.environment.accessibilityReduceMotion)
    }
}

extension Text {
    /// A highlight sweeping across the text while something is in progress.
    func shimmering(_ active: Bool = true) -> some View { modifier(Shimmer(text: self, active: active)) }
}

private struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: Text
    let active: Bool

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content.overlay { ShimmerSweep(text: text).allowsHitTesting(false) }
        } else {
            content
        }
    }
}

/// A highlight band sweeping left to right every 1.6 s, clipped to the glyphs of `text`: a layer
/// mask rendered from `text` with the overlay's environment, so font, line limit and truncation match.
private struct ShimmerSweep: NSViewRepresentable {
    let text: Text

    func makeNSView(context: Context) -> ShimmerSweepView { ShimmerSweepView() }

    func updateNSView(_ view: ShimmerSweepView, context: Context) {
        view.update(text: text, environment: context.environment)
    }
}

/// A view that only hosts animated sublayers: clicks pass through, and layout follows the screen's scale.
class AnimationHostView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    /// Sublayers outside a view's own layer animate every change implicitly unless told not to.
    func withoutActions(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}

extension CABasicAnimation {
    static func forever(_ keyPath: String, from: Any, to: Any, duration: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }
}

final class SpinnerArcView: AnimationHostView {
    private let arc = CAShapeLayer()
    private var color = NSColor.labelColor

    override init() {
        super.init()
        arc.fillColor = nil
        arc.lineCap = .round
        layer?.addSublayer(arc)
    }

    func configure(length: CGFloat, lineWidth: CGFloat, color: NSColor, animated: Bool) {
        withoutActions {
            arc.strokeEnd = length
            arc.lineWidth = lineWidth
        }
        if color != self.color {
            self.color = color
            needsDisplay = true
        }
        if !animated {
            arc.removeAnimation(forKey: "turn")
        } else if arc.animation(forKey: "turn") == nil {
            // The layer's y axis points up, so a negative angle turns clockwise on screen.
            let turn = CABasicAnimation.forever("transform.rotation.z", from: 0, to: -2 * Double.pi, duration: 1.2)
            arc.add(turn, forKey: "turn")
        }
    }

    override func updateLayer() {
        withoutActions {
            effectiveAppearance.performAsCurrentDrawingAppearance { arc.strokeColor = color.cgColor }
        }
    }

    override func layout() {
        super.layout()
        withoutActions {
            arc.frame = bounds
            arc.path = CGPath(ellipseIn: bounds, transform: nil)
            arc.contentsScale = scale
        }
    }
}

private final class ShimmerSweepView: AnimationHostView {
    /// The band's width as a share of the text's.
    private static let bandShare = 0.4
    private let highlight = CALayer()
    private let band = CAGradientLayer()
    private let glyphs = CALayer()
    private var text: Text?
    private var environment = EnvironmentValues()
    private var glyphsStale = true
    /// The size and scale the layers were last laid out at.
    private var laidOut: (size: CGSize, scale: CGFloat)?

    override init() {
        super.init()
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        highlight.addSublayer(band)
        highlight.mask = glyphs
        layer?.addSublayer(highlight)
    }

    func update(text: Text, environment: EnvironmentValues) {
        self.environment = environment
        guard text != self.text else { return }
        self.text = text
        glyphsStale = true
        needsLayout = true
    }

    override func updateLayer() {
        withoutActions {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let color = NSColor.labelColor.cgColor
                band.colors = [NSColor.clear.cgColor, color.copy(alpha: color.alpha * 0.55) ?? color,
                               NSColor.clear.cgColor]
            }
        }
    }

    override func layout() {
        super.layout()
        let size = bounds.size, scale = scale
        let resized = laidOut?.size != size
        guard resized || laidOut?.scale != scale || glyphsStale else { return }
        withoutActions {
            highlight.frame = bounds
            glyphs.frame = bounds
            band.bounds = CGRect(x: 0, y: 0, width: Self.bandShare * size.width, height: size.height)
            band.position.y = bounds.midY
            glyphs.contents = bounds.isEmpty ? nil : renderGlyphs(size: size, scale: scale)
            glyphs.contentsScale = scale
        }
        laidOut = (size, scale)
        glyphsStale = false
        if resized { sweep() }
    }

    /// The band's middle travels from half a band before the text to half a band past it. A
    /// gradient's `locations` animation stayed still on screen, so the band moves instead; the
    /// phase follows the media clock, so a new width ("Working for 59s", "1m 0s") keeps the beat.
    private func sweep() {
        let width = bounds.width, half = Self.bandShare / 2
        let sweep = CABasicAnimation.forever("position.x", from: -half * width, to: (1 + half) * width,
                                             duration: 1.6)
        sweep.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: sweep.duration)
        band.add(sweep, forKey: "sweep")
    }

    private func renderGlyphs(size: CGSize, scale: CGFloat) -> CGImage? {
        guard let text else { return nil }
        let environment = environment
        let renderer = ImageRenderer(content: text
            .transformEnvironment(\.self) { $0 = environment }
            .frame(width: size.width, height: size.height, alignment: .topLeading))
        renderer.scale = scale
        return renderer.cgImage.flatMap(Self.coverage)
    }

    /// The glyphs' coverage alone: the text's own colour, such as a secondary style, would
    /// otherwise dim the highlight too.
    private static func coverage(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let alpha = UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                               count: context.bytesPerRow * image.height)
        let peak = Int(alpha.max() ?? 0)
        guard peak > 0 else { return nil }
        for index in alpha.indices { alpha[index] = UInt8(Int(alpha[index]) * 255 / peak) }
        return context.makeImage()
    }
}
