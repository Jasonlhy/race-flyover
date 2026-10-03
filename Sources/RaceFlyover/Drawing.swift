import AppKit

/// Small drawing helpers shared by the stylized scene and the HUD. All drawing
/// happens in flipped (top-left origin) views.
enum Draw {
    /// Typeface used for all overlay text; set from the user's options.
    static var typeface = Typeface.system
    private static var fontCache: [String: NSFont] = [:]

    /// A font in the chosen typeface. `mono` asks for tabular (fixed-width) digits so
    /// changing numbers don't jitter.
    static func font(size: CGFloat, weight: NSFont.Weight, mono: Bool) -> NSFont {
        let key = "\(typeface.rawValue)|\(size)|\(weight.rawValue)|\(mono)"
        if let f = fontCache[key] { return f }
        var font: NSFont
        switch typeface {
        case .system:
            font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        case .rounded, .serif, .mono:
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            let design: NSFontDescriptor.SystemDesign = typeface == .rounded ? .rounded : (typeface == .serif ? .serif : .monospaced)
            font = base.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        default:
            let descriptor = NSFontDescriptor(fontAttributes: [
                .family: typeface.family ?? "Helvetica Neue",
                .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
            ])
            font = NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
        }
        if mono && typeface != .system {
            let tabular = font.fontDescriptor.addingAttributes([.featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]]])
            font = NSFont(descriptor: tabular, size: size) ?? font
        }
        if fontCache.count > 400 { fontCache.removeAll() }
        fontCache[key] = font
        return font
    }

    static func text(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor,
                     mono: Bool = false, tracking: CGFloat = 0) -> NSAttributedString {
        let font = font(size: size, weight: weight, mono: mono)
        return NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: color, .kern: tracking,
        ])
    }

    /// Draws `s` with its top-left at `p` (or aligned by `anchor`, 0 = left, 0.5 = centre, 1 = right).
    @discardableResult
    static func string(_ s: NSAttributedString, at p: CGPoint, anchor: CGFloat = 0) -> CGRect {
        let size = s.size()
        let r = CGRect(x: p.x - size.width * anchor, y: p.y, width: size.width, height: size.height)
        s.draw(at: r.origin)
        return r
    }

    static func roundedRect(_ ctx: CGContext, _ r: CGRect, radius: CGFloat, fill: NSColor, stroke: NSColor? = nil,
                            lineWidth: CGFloat = 1) {
        let path = CGPath(roundedRect: r, cornerWidth: min(radius, r.height / 2), cornerHeight: min(radius, r.height / 2),
                          transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(fill.cgColor)
        ctx.fillPath()
        if let stroke {
            ctx.addPath(path)
            ctx.setStrokeColor(stroke.cgColor)
            ctx.setLineWidth(lineWidth)
            ctx.strokePath()
        }
    }

    /// A text label in a rounded pill centred horizontally on `p`, sitting above it.
    @discardableResult
    static func pill(_ ctx: CGContext, _ s: NSAttributedString, above p: CGPoint, fill: NSColor,
                     stroke: NSColor? = nil, padding: CGFloat) -> CGRect {
        let size = s.size()
        let r = CGRect(x: p.x - size.width / 2 - padding * 1.6, y: p.y - size.height - padding * 2,
                       width: size.width + padding * 3.2, height: size.height + padding * 1.2)
        roundedRect(ctx, r, radius: r.height / 2, fill: fill, stroke: stroke)
        s.draw(at: CGPoint(x: r.minX + padding * 1.6, y: r.minY + padding * 0.6))
        return r
    }

    /// Teardrop fitted in `r`.
    static func droplet(in r: CGRect) -> CGPath {
        let p = CGMutablePath()
        let cx = r.midX, w = r.width
        let bottomR = w * 0.36
        let cy = r.maxY - bottomR - r.height * 0.06
        p.move(to: CGPoint(x: cx, y: r.minY + r.height * 0.04))
        p.addCurve(to: CGPoint(x: cx + bottomR, y: cy),
                   control1: CGPoint(x: cx + w * 0.12, y: r.minY + r.height * 0.28),
                   control2: CGPoint(x: cx + bottomR, y: cy - bottomR * 0.9))
        p.addArc(center: CGPoint(x: cx, y: cy), radius: bottomR, startAngle: 0, endAngle: .pi, clockwise: false)
        p.addCurve(to: CGPoint(x: cx, y: r.minY + r.height * 0.04),
                   control1: CGPoint(x: cx - bottomR, y: cy - bottomR * 0.9),
                   control2: CGPoint(x: cx - w * 0.12, y: r.minY + r.height * 0.28))
        p.closeSubpath()
        return p
    }

    /// Lightning bolt fitted in `r`.
    static func bolt(in r: CGRect) -> CGPath {
        let pts: [(CGFloat, CGFloat)] = [(0.58, 0.02), (0.18, 0.56), (0.46, 0.56), (0.36, 0.98),
                                         (0.82, 0.40), (0.53, 0.40), (0.66, 0.02)]
        let p = CGMutablePath()
        p.addLines(between: pts.map { CGPoint(x: r.minX + $0.0 * r.width, y: r.minY + $0.1 * r.height) })
        p.closeSubpath()
        return p
    }

    /// Round station badge: blue droplet for fluids, orange bolt for fuel, split when both.
    static func stationBadge(_ ctx: CGContext, center c: CGPoint, radius: CGFloat, station: Station,
                             theme: Theme, alpha: CGFloat) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        let r = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
        if station.fluid && station.fuel {
            ctx.saveGState()
            ctx.addEllipse(in: r)
            ctx.clip()
            ctx.setFillColor(theme.fluid.cgColor)
            ctx.fill(CGRect(x: r.minX, y: r.minY, width: radius, height: r.height))
            ctx.setFillColor(theme.fuel.cgColor)
            ctx.fill(CGRect(x: r.midX, y: r.minY, width: radius, height: r.height))
            ctx.restoreGState()
            let g = radius * 0.62
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.addPath(droplet(in: CGRect(x: c.x - g * 0.98, y: c.y - g * 0.55, width: g * 0.8, height: g * 1.1)))
            ctx.addPath(bolt(in: CGRect(x: c.x + g * 0.12, y: c.y - g * 0.58, width: g * 0.85, height: g * 1.16)))
            ctx.fillPath()
        } else {
            ctx.setFillColor((station.fluid ? theme.fluid : theme.fuel).cgColor)
            ctx.fillEllipse(in: r)
            let g = radius * 1.1
            let gr = CGRect(x: c.x - g / 2, y: c.y - g / 2, width: g, height: g)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.addPath(station.fluid ? droplet(in: gr.insetBy(dx: g * 0.14, dy: 0)) : bolt(in: gr))
            ctx.fillPath()
        }
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(max(1, radius * 0.14))
        ctx.strokeEllipse(in: r)
        ctx.restoreGState()
    }

    static func linearGradient(_ ctx: CGContext, rect: CGRect, from c0: NSColor, to c1: NSColor,
                               start: CGPoint, end: CGPoint) {
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                 colors: [c0.cgColor, c1.cgColor] as CFArray, locations: [0, 1]) else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(g, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    static func radialGlow(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: NSColor) {
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                 colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray,
                                 locations: [0, 1]) else { return }
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }
}

extension Units {
    /// "12.4 km" / "7.7 mi"
    func format(km: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f %@", km / kmPerUnit, label)
    }

    /// Distance to something ahead: metres/feet when close, otherwise km/mi.
    func formatAhead(km: Double) -> String {
        if self == .km && km < 1 { return String(format: "%.0f m", (km * 100).rounded() * 10) }
        if self == .mi && km < 0.3 { return String(format: "%.0f ft", (km * 3280.84 / 50).rounded() * 50) }
        return format(km: km)
    }

    func formatElevation(_ metres: Double) -> String {
        self == .km ? String(format: "%.0f m", metres) : String(format: "%.0f ft", metres * 3.28084)
    }
}
