import AppKit

/// Transparent top layer that draws the HUD text (and, for solid panels, the
/// panel backgrounds) over whichever scene is showing.
final class HUDOverlayView: NSView {
    weak var engine: FlyoverEngine?
    var theme = Theme.forStyle(.midnight)
    var isThumbnail = false
    var usesGlass = false
    var area: AreaNamer?
    /// Panel positions recorded during the last draw, for the glass layer.
    private(set) var glassPanels: [GlassPanel] = []

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        guard let engine, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let layout = usesGlass && !isThumbnail ? GlassPanelLayout() : nil
        HUDRenderer(theme: theme, engine: engine, size: bounds.size, thumbnail: isThumbnail, glass: layout,
                    area: area).draw(ctx)
        glassPanels = layout?.panels ?? []
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
