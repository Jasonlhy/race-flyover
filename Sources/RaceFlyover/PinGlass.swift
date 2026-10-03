import AppKit

/// The runner's pin as a Liquid Glass puck (macOS 26+) lying on the road, like
/// the solid pin: a round glass disc tinted with the pin colour, flattened by
/// the camera's perspective, with an arrow on its face for the direction of
/// travel. The scene underneath draws its coloured base and contact shadow.
final class PinGlassView: NSView {
    private var glass: NSView?
    private let arrow = ArrowView()

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.style = .regular
            addSubview(g)
            glass = g
        }
        addSubview(arrow)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// - Parameters:
    ///   - center: the puck's top-face centre, in superview coordinates.
    ///   - radius: its horizontal radius on screen, in points.
    ///   - squash: vertical foreshortening (1 = seen from directly above).
    ///   - angle: direction of travel on the ground relative to the camera,
    ///     radians clockwise from "away from the camera".
    func place(center: CGPoint, radius: CGFloat, squash: CGFloat, angle: CGFloat, color: NSColor) {
        let d = max(4, (radius * 2).rounded())
        let f = CGRect(x: (center.x - d / 2).rounded(), y: (center.y - d / 2).rounded(), width: d, height: d)
        if frame != f { frame = f }
        let inner = CGRect(origin: .zero, size: f.size)
        if #available(macOS 26.0, *), let g = glass as? NSGlassEffectView {
            if g.frame != inner { g.frame = inner }
            if g.cornerRadius != d / 2 { g.cornerRadius = d / 2 }
            // Full-strength tint so the user's pin colour reads clearly through the glass.
            if g.tintColor != color { g.tintColor = color }
        }
        if arrow.frame != inner { arrow.frame = inner }
        arrow.update(angle: angle, size: d)
        flatten(squash: max(0.12, min(1, squash)))
    }

    /// Lays the disc and its arrow flat on the ground by squashing everything
    /// vertically about the centre (a circle on the road seen at an angle).
    private func flatten(squash: CGFloat) {
        guard let layer else { return }
        let size = bounds.size
        let anchor = CGPoint(x: layer.anchorPoint.x * size.width, y: layer.anchorPoint.y * size.height)
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        // Sublayer transforms act about the anchor point; scale about the centre instead.
        let toCentre = CATransform3DMakeTranslation(anchor.x - centre.x, anchor.y - centre.y, 0)
        let back = CATransform3DMakeTranslation(centre.x - anchor.x, centre.y - anchor.y, 0)
        let t = CATransform3DConcat(CATransform3DConcat(toCentre, CATransform3DMakeScale(1, squash, 1)), back)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayerTransform = t
        CATransaction.commit()
    }
}

/// White navigation arrow, rotated to the direction of travel.
private final class ArrowView: NSView {
    private var angle: CGFloat = .nan
    private var size: CGFloat = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func update(angle a: CGFloat, size s: CGFloat) {
        // Redraw only when it visibly changes (~1°).
        guard abs(a - angle) > 0.017 || s != size || angle.isNaN else { return }
        angle = a
        size = s
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !angle.isNaN else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let r = bounds.width * 0.30
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: angle)   // flipped view: positive is clockwise
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: -r))
        path.addLine(to: CGPoint(x: r * 0.78, y: r * 0.72))
        path.addLine(to: CGPoint(x: 0, y: r * 0.36))
        path.addLine(to: CGPoint(x: -r * 0.78, y: r * 0.72))
        path.closeSubpath()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
    }
}
