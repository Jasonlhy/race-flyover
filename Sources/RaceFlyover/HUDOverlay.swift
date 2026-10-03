import AppKit

/// The HUD layer. Rather than one transparent, screen-sized layer repainted
/// every frame (tens of megabytes of pixels at Retina resolution, composited
/// over the map), each panel lives in its own small layer sized to what it
/// last drew, and the static title panel only repaints when it changes.
final class HUDOverlayView: NSView {
    weak var engine: FlyoverEngine?
    var theme = Theme.forStyle(.midnight)
    var isThumbnail = false
    var usesGlass = false
    var area: AreaNamer?

    private var parts: [HUDPart: HUDPartView] = [:]
    private let fadeLayer = CALayer()

    /// Panel positions recorded during the last draw, for the glass layer.
    var glassPanels: [GlassPanel] {
        HUDPart.allCases.compactMap { parts[$0] }.filter { !$0.isHidden }.flatMap(\.glassPanels)
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fadeLayer.backgroundColor = NSColor.black.cgColor
        fadeLayer.opacity = 0
        fadeLayer.zPosition = 10
        fadeLayer.actions = ["opacity": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(fadeLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        fadeLayer.frame = bounds
        parts.values.forEach { $0.forgetRect() }
    }

    /// Called every frame: positions the part layers and marks the changing ones dirty.
    func refresh() {
        guard let engine else { return }
        let mode = isThumbnail ? HUDMode.minimal : engine.config.hud
        var wanted = Set<HUDPart>()
        if mode != .off && engine.hudAlpha > 0.01 {
            if mode == .full { wanted.formUnion([.title, .metrics, .profile]) } else { wanted.insert(.minimal) }
        }
        if engine.titleAlpha > 0.01 || engine.finishAlpha > 0.01 { wanted.insert(.card) }

        for part in HUDPart.allCases {
            guard wanted.contains(part) else {
                parts[part]?.isHidden = true
                continue
            }
            let view = parts[part] ?? makePart(part)
            view.isHidden = false
            view.updateFrame(in: bounds)
            // The title panel is static apart from fades and settings changes.
            let signature = part == .title
                ? "\(engine.course.id)|\(Int(engine.hudAlpha * 100))|\(engine.config.typeface)|\(engine.config.textScale)|\(usesGlass)|\(bounds.size)|\(theme.text)"
                : nil
            view.setNeedsRedraw(signature: signature)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeLayer.frame = bounds
        fadeLayer.opacity = Float(engine.fade)
        CATransaction.commit()
    }

    private func makePart(_ part: HUDPart) -> HUDPartView {
        let v = HUDPartView(part: part, owner: self)
        addSubview(v)
        parts[part] = v
        return v
    }

    fileprivate func render(_ part: HUDPart, in ctx: CGContext, frames: HUDFrames, glass: GlassPanelLayout?) {
        guard let engine else { return }
        var renderer = HUDRenderer(theme: theme, engine: engine, size: bounds.size, thumbnail: isThumbnail,
                                   glass: glass, area: area)
        renderer.parts = [part]
        renderer.frames = frames
        renderer.drawsFade = false
        renderer.draw(ctx)
    }
}

/// One HUD part, drawn in HUD coordinates but backed by a layer only as large
/// as the area it drew last time (plus a margin for strokes and shadows).
private final class HUDPartView: NSView {
    let part: HUDPart
    weak var owner: HUDOverlayView?
    private(set) var glassPanels: [GlassPanel] = []
    private var drawnRect: CGRect?
    private var signature: String?
    private let margin: CGFloat = 16

    init(part: HUDPart, owner: HUDOverlayView) {
        self.part = part
        self.owner = owner
        super.init(frame: owner.bounds)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func forgetRect() { drawnRect = nil; signature = nil }

    func updateFrame(in bounds: CGRect) {
        // Until we know the extent, draw at full size once.
        let target = drawnRect.map { $0.insetBy(dx: -margin, dy: -margin).intersection(bounds).integral } ?? bounds
        if frame != target {
            frame = target
            signature = nil
        }
    }

    func setNeedsRedraw(signature new: String?) {
        if let new, new == signature { return }
        signature = new
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let owner, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let frames = HUDFrames()
        let glass = owner.usesGlass && !owner.isThumbnail ? GlassPanelLayout() : nil
        ctx.saveGState()
        ctx.translateBy(x: -frame.minX, y: -frame.minY)
        FrameStats.shared.measure("hud.\(part)") { owner.render(part, in: ctx, frames: frames, glass: glass) }
        ctx.restoreGState()
        glassPanels = glass?.panels ?? []
        if let r = frames.rects[part] {
            let grown = drawnRect.map { !$0.insetBy(dx: -margin, dy: -margin).contains(r) } ?? true
            drawnRect = r
            // The panel outgrew this layer (e.g. a new row appeared): resize next frame.
            if grown { signature = nil }
        }
    }
}

/// Real Liquid Glass panels (macOS 26+) positioned under the HUD's text so the
/// moving course refracts through them.
final class GlassPanelsView: NSView {
    private var views: [NSView] = []
    private var current: [GlassPanel] = []
    var clear = false {
        didSet { if clear != oldValue { restyle() } }
    }
    var tint: NSColor? {
        didSet { restyle() }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(_ panels: [GlassPanel]) {
        guard #available(macOS 26.0, *) else { return }
        if panels.count != views.count {
            views.forEach { $0.removeFromSuperview() }
            views = panels.map { _ in
                let v = NSGlassEffectView()
                v.style = clear ? .clear : .regular
                v.tintColor = tint
                addSubview(v)
                return v
            }
            current = []
        }
        guard panels != current else { return }
        current = panels
        for (view, panel) in zip(views, panels) {
            // Snap to whole points so the glass doesn't shimmer as numbers change.
            let r = panel.rect.integral
            if view.frame != r { view.frame = r }
            (view as? NSGlassEffectView)?.cornerRadius = panel.radius
            view.alphaValue = panel.alpha
            view.isHidden = panel.alpha < 0.01
        }
    }

    private func restyle() {
        guard #available(macOS 26.0, *) else { return }
        for case let v as NSGlassEffectView in views {
            v.style = clear ? .clear : .regular
            v.tintColor = tint
        }
    }
}
