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

    /// A finisher's medal hanging from a V-shaped ribbon, with `title` struck
    /// on its face and `subtitle` beneath. `top` is the top of the ribbon; the
    /// whole emblem is about 4.2 × radius tall. Returns the medal's centre.
    @discardableResult
    static func medal(_ ctx: CGContext, centreX cx: CGFloat, top: CGFloat, radius r: CGFloat,
                      ribbon: NSColor, title: String, subtitle: String) -> CGPoint {
        let c = CGPoint(x: cx, y: top + r * 2.2)
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        func gradient(_ colors: [NSColor], _ locations: [CGFloat]) -> CGGradient? {
            CGGradient(colorsSpace: space, colors: colors.map(\.cgColor) as CFArray, locations: locations)
        }

        // Ribbon: two straps crossing behind the medal, each with a white stripe.
        func strap(_ side: CGFloat, shade: CGFloat) {
            let topOuter = CGPoint(x: cx + side * r * 1.0, y: top)
            let topInner = CGPoint(x: cx + side * r * 0.42, y: top)
            let lowInner = CGPoint(x: cx - side * r * 0.18, y: c.y - r * 0.7)
            let lowOuter = CGPoint(x: cx + side * r * 0.40, y: c.y - r * 0.7)
            let path = CGMutablePath()
            path.addLines(between: [topOuter, topInner, lowInner, lowOuter])
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor((ribbon.blended(withFraction: shade, of: .black) ?? ribbon).cgColor)
            ctx.fillPath()
            // Centre stripe, a third of the strap's width.
            func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
            let stripe = CGMutablePath()
            stripe.addLines(between: [lerp(topInner, topOuter, 0.36), lerp(topInner, topOuter, 0.64),
                                      lerp(lowInner, lowOuter, 0.64), lerp(lowInner, lowOuter, 0.36)])
            stripe.closeSubpath()
            ctx.addPath(stripe)
            ctx.setFillColor(NSColor(white: 1, alpha: 0.85 - shade).cgColor)
            ctx.fillPath()
        }
        strap(1, shade: 0.28)   // behind
        strap(-1, shade: 0.0)

        // Ring that holds the ribbon.
        ctx.setStrokeColor(Theme.hex(0xC9962B).cgColor)
        ctx.setLineWidth(r * 0.07)
        ctx.strokeEllipse(in: CGRect(x: cx - r * 0.16, y: c.y - r * 1.12, width: r * 0.32, height: r * 0.32))

        // Medal: soft shadow, gold disc, bevelled inner face.
        let disc = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: r * 0.06), blur: r * 0.25, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.setFillColor(Theme.hex(0xD9A93A).cgColor)
        ctx.fillEllipse(in: disc)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: disc)
        ctx.clip()
        if let g = gradient([Theme.hex(0xFFE9A3), Theme.hex(0xE9B949), Theme.hex(0xB07D1C)], [0, 0.5, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: disc.minX, y: disc.minY), end: CGPoint(x: disc.maxX, y: disc.maxY), options: [])
        }
        ctx.restoreGState()
        let face = disc.insetBy(dx: r * 0.14, dy: r * 0.14)
        ctx.saveGState()
        ctx.addEllipse(in: face)
        ctx.clip()
        if let g = gradient([Theme.hex(0xB8861F), Theme.hex(0xF2C95A), Theme.hex(0xFFEFB8)], [0, 0.55, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: face.minX, y: face.minY), end: CGPoint(x: face.maxX, y: face.maxY), options: [])
        }
        ctx.restoreGState()
        ctx.setStrokeColor(Theme.hex(0x9C7015, 0.8).cgColor)
        ctx.setLineWidth(max(1, r * 0.025))
        ctx.strokeEllipse(in: disc.insetBy(dx: r * 0.012, dy: r * 0.012))
        ctx.strokeEllipse(in: face)
        ctx.setStrokeColor(Theme.hex(0x9C7015, 0.45).cgColor)
        ctx.strokeEllipse(in: face.insetBy(dx: r * 0.08, dy: r * 0.08))

        // Laurel wreath: two sprigs curving up from the bottom around the centre.
        let engraved = Theme.hex(0x6B4A0E)
        ctx.setFillColor(Theme.hex(0x9C7015, 0.8).cgColor)
        ctx.setStrokeColor(Theme.hex(0x9C7015, 0.8).cgColor)
        ctx.setLineWidth(max(1, r * 0.018))
        for side in [-1.0, 1.0] as [CGFloat] {
            ctx.addArc(center: c, radius: r * 0.55, startAngle: .pi / 2 + side * 0.2, endAngle: .pi / 2 + side * 1.75,
                       clockwise: side < 0)
            ctx.strokePath()
            for k in 0..<7 {
                let a = (CGFloat.pi / 2) + side * (0.32 + CGFloat(k) * 0.22)
                for offset in [-1.0, 1.0] as [CGFloat] {   // a leaf either side of the stem
                    let p = CGPoint(x: c.x + cos(a) * r * (0.55 + offset * 0.045), y: c.y + sin(a) * r * (0.55 + offset * 0.045))
                    ctx.saveGState()
                    ctx.translateBy(x: p.x, y: p.y)
                    ctx.rotate(by: a + side * (.pi / 2 - offset * 0.5))
                    ctx.fillEllipse(in: CGRect(x: -r * 0.075, y: -r * 0.028, width: r * 0.15, height: r * 0.056))
                    ctx.restoreGState()
                }
            }
        }

        // Lettering struck into the face, in classical capitals: the title
        // arched around the top inside the rim, the distance large in the
        // centre. A light edge below each letter reads as engraved.
        func classical(_ size: CGFloat) -> NSFont {
            NSFont(name: "Optima-ExtraBlack", size: size) ?? .systemFont(ofSize: size, weight: .black)
        }
        func engrave(_ string: String, font: NSFont, kern: CGFloat, at p: CGPoint) {
            for (color, dy) in [(NSColor(white: 1, alpha: 0.45), max(1, r * 0.012)), (engraved, 0)] {
                let t = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .kern: kern])
                let size = t.size()
                t.draw(at: CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2 + dy))
            }
        }
        // Arched title: each letter placed and turned along a circle.
        let arcFont = classical(r * 0.2)
        let arcRadius = r * 0.66
        let spacing = r * 0.035
        let letters = title.map { String($0) }
        let widths = letters.map { NSAttributedString(string: $0, attributes: [.font: arcFont]).size().width + spacing }
        let sweep = widths.reduce(0, +) / arcRadius
        var angle = -CGFloat.pi / 2 - sweep / 2
        for (letter, w) in zip(letters, widths) {
            let mid = angle + (w / 2) / arcRadius
            ctx.saveGState()
            ctx.translateBy(x: c.x + cos(mid) * arcRadius, y: c.y + sin(mid) * arcRadius)
            ctx.rotate(by: mid + .pi / 2)
            engrave(letter, font: arcFont, kern: 0, at: .zero)
            ctx.restoreGState()
            angle += w / arcRadius
        }
        // Distance in the centre: the number large, the unit small beneath.
        let parts = subtitle.split(separator: " ").map(String.init)
        let number = parts.first ?? subtitle
        let unit = parts.dropFirst().joined(separator: " ")
        engrave(number, font: classical(r * (number.count > 5 ? 0.245 : 0.34)), kern: r * 0.005, at: CGPoint(x: c.x, y: c.y + r * 0.02))
        if !unit.isEmpty { engrave(unit, font: classical(r * 0.11), kern: r * 0.03, at: CGPoint(x: c.x, y: c.y + r * 0.27)) }

        // Shine across the upper left.
        ctx.saveGState()
        ctx.addEllipse(in: disc)
        ctx.clip()
        if let g = gradient([NSColor(white: 1, alpha: 0.35), NSColor(white: 1, alpha: 0)], [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: c.x - r * 0.45, y: c.y - r * 0.5), startRadius: 0,
                                   endCenter: CGPoint(x: c.x - r * 0.45, y: c.y - r * 0.5), endRadius: r * 0.9, options: [])
        }
        ctx.restoreGState()
        return c
    }

    /// A glass puck lying on the road: a see-through edge (`base`, on the ground),
    /// a clear glass face (`rim`, lifted by the puck's thickness) and a
    /// see-through disc of the pin colour in its middle (`centre`). Light glass
    /// for light map styles, dark glass otherwise. Draws no outline in black.
    static func glassPuck(_ ctx: CGContext, base: CGPath, rim: CGPath, centre: CGPath, color: NSColor,
                          light: Bool, lineScale s: CGFloat) {
        glassEdge(ctx, base, light: light, lineScale: s)
        glassFace(ctx, rim: rim, centre: centre, color: color, light: light, lineScale: s)
    }

    /// The glass puck's side, just showing below its face.
    static func glassEdge(_ ctx: CGContext, _ base: CGPath, light: Bool, lineScale s: CGFloat) {
        ctx.addPath(base)
        ctx.setFillColor((light ? NSColor(white: 1, alpha: 0.30) : NSColor(white: 0, alpha: 0.28)).cgColor)
        ctx.fillPath()
        ctx.addPath(base)
        ctx.setStrokeColor(NSColor(white: 1, alpha: light ? 0.55 : 0.28).cgColor)
        ctx.setLineWidth(1 * s)
        ctx.strokePath()
    }

    /// The glass puck's face: clear glass with a coloured see-through centre.
    static func glassFace(_ ctx: CGContext, rim: CGPath, centre: CGPath, color: NSColor, light: Bool,
                          lineScale s: CGFloat) {
        // Barely tinted glass with a soft sheen across its upper half.
        ctx.addPath(rim)
        ctx.setFillColor((light ? NSColor(white: 1, alpha: 0.24) : NSColor(white: 0.05, alpha: 0.22)).cgColor)
        ctx.fillPath()
        let box = rim.boundingBoxOfPath
        ctx.saveGState()
        ctx.addPath(rim)
        ctx.clip()
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [NSColor(white: 1, alpha: light ? 0.45 : 0.28).cgColor,
                                       NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                              locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: box.midX, y: box.minY),
                                   end: CGPoint(x: box.midX, y: box.midY), options: [])
        }
        ctx.restoreGState()
        ctx.addPath(rim)
        ctx.setStrokeColor(NSColor(white: 1, alpha: light ? 0.95 : 0.6).cgColor)
        ctx.setLineWidth(1.5 * s)
        ctx.strokePath()

        // Centre: the pin colour, see-through, with a crisp rim of the same colour.
        ctx.addPath(centre)
        ctx.setFillColor(color.withAlphaComponent(0.55).cgColor)
        ctx.fillPath()
        ctx.addPath(centre)
        ctx.setStrokeColor(color.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(1.5 * s)
        ctx.strokePath()
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
