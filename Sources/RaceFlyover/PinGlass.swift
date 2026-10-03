import AppKit

/// The runner's pin as a Liquid Glass bead (macOS 26+): a round glass view
/// tinted with the pin colour, floating just above the road so the course
/// refracts through it, with an arrow showing the direction of travel. Its
/// shadow on the ground is drawn by the scene underneath.
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

    /// Centres the bead on `center` (superview coordinates) with `radius` points.
    func place(center: CGPoint, radius: CGFloat, angle: CGFloat, color: NSColor) {
        let d = (radius * 2).rounded()
        let f = CGRect(x: (center.x - d / 2).rounded(), y: (center.y - d / 2).rounded(), width: d, height: d)
        if frame != f { frame = f }
        let inner = CGRect(origin: .zero, size: f.size)
        if #available(macOS 26.0, *), let g = glass as? NSGlassEffectView {
            if g.frame != inner { g.frame = inner }
            if g.cornerRadius != d / 2 { g.cornerRadius = d / 2 }
            let tint = color.withAlphaComponent(0.55)
            if g.tintColor != tint { g.tintColor = tint }
        }
        if arrow.frame != inner { arrow.frame = inner }
        arrow.update(angle: angle, size: d)
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
