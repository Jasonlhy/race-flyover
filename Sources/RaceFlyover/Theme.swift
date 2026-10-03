import AppKit

struct Theme {
    var skyTop: NSColor
    var skyHorizon: NSColor
    var ground: NSColor
    var groundFar: NSColor
    var grid: NSColor
    var routeAhead: NSColor
    var routeDone: NSColor
    var glow: NSColor
    var curtain: NSColor
    var shadow: NSColor
    var runner: NSColor
    var fluid: NSColor
    var fuel: NSColor
    var text: NSColor
    var textSecondary: NSColor
    var accent: NSColor
    var panel: NSColor
    var stars: Bool = false
    var sun: NSColor?

    /// Applies the user's pin and trail colours on top of a style's palette.
    func with(pin: AccentColor, trail: AccentColor) -> Theme {
        var t = self
        if let c = trail.color {
            t.routeDone = c
            t.glow = c.withAlphaComponent(0.28)
            if t.curtain.alphaComponent > 0 { t.curtain = c.withAlphaComponent(0.14) }
        }
        // The pin is filled with its colour and ringed in white, so by default it
        // takes the trail colour (white-on-white would vanish).
        t.runner = pin.color ?? t.routeDone
        return t
    }

    /// Gold for landmark labels: distinct from fluids (blue) and fuel (orange).
    static let landmark = hex(0xFFC93C)

    func color(for burst: FlyoverEngine.Burst.Kind) -> [NSColor] {
        switch burst {
        case .fluid: return [fluid]
        case .fuel: return [fuel]
        case .both: return [fluid, fuel]
        case .marker: return [NSColor.white]
        case .half: return [accent]
        }
    }

    /// Large location pin: coloured disc, thick white ring, soft drop shadow.
    static func drawPin(_ ctx: CGContext, at c: CGPoint, radius r: CGFloat, color: NSColor) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: r * 0.25), blur: r * 0.9,
                      color: NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ctx.restoreGState()
        let inner = r * 0.66
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
    }

    static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }

    static func forStyle(_ style: VisualStyle) -> Theme {
        switch style {
        case .satellitePlain, .satellite, .map:
            // Over map imagery: dusk sky beyond the tiles, bright route and pins.
            return Theme(skyTop: hex(0x05070D), skyHorizon: hex(0x2A3550), ground: hex(0x101318),
                         groundFar: hex(0x2A3550), grid: .clear, routeAhead: hex(0xFFFFFF, 0.85),
                         routeDone: hex(0xFF3D71), glow: hex(0xFF3D71, 0.30), curtain: .clear,
                         shadow: hex(0x000000, 0.55), runner: hex(0xFFFFFF), fluid: hex(0x2E9BFF),
                         fuel: hex(0xFF9500), text: hex(0xFFFFFF), textSecondary: hex(0xD6DCE6),
                         accent: hex(0xFF5C8A), panel: hex(0x0A0D14, 0.62))
        case .mapLight:
            return Theme(skyTop: hex(0x7FB2E5), skyHorizon: hex(0xE4EEF7), ground: hex(0xF2EFE9),
                         groundFar: hex(0xE4EEF7), grid: .clear, routeAhead: hex(0x2B3442, 0.75),
                         routeDone: hex(0xFF4D00), glow: hex(0xFF6A2B, 0.28), curtain: .clear,
                         shadow: hex(0x000000, 0.25), runner: hex(0xFF4D00), fluid: hex(0x1B7FE0),
                         fuel: hex(0xF08A00), text: hex(0x161C26), textSecondary: hex(0x4C5A6E),
                         accent: hex(0xE8501A), panel: hex(0xFFFFFF, 0.72))
        case .midnight:
            return Theme(skyTop: hex(0x03060F), skyHorizon: hex(0x14254A), ground: hex(0x070D1C),
                         groundFar: hex(0x101C38), grid: hex(0x3A5A9A, 0.30), routeAhead: hex(0x8FB4FF, 0.55),
                         routeDone: hex(0x5EF0FF), glow: hex(0x2EC8FF, 0.22), curtain: hex(0x3E8BFF, 0.16),
                         shadow: hex(0x000000, 0.45), runner: hex(0xFFFFFF), fluid: hex(0x38A8FF),
                         fuel: hex(0xFF9F2E), text: hex(0xF2F6FF), textSecondary: hex(0xA9B8D6),
                         accent: hex(0x5EF0FF), panel: hex(0x050A18, 0.55), stars: true)
        case .neon:
            return Theme(skyTop: hex(0x07000F), skyHorizon: hex(0x3A0A4A), ground: hex(0x05000A),
                         groundFar: hex(0x1C0630), grid: hex(0xFF2BD6, 0.35), routeAhead: hex(0xFFE36E, 0.45),
                         routeDone: hex(0x2BFFF1), glow: hex(0x2BFFF1, 0.25), curtain: hex(0xFF2BD6, 0.14),
                         shadow: hex(0x000000, 0.5), runner: hex(0xFFFFFF), fluid: hex(0x33C2FF),
                         fuel: hex(0xFFB02E), text: hex(0xFFF2FD), textSecondary: hex(0xD7A6E6),
                         accent: hex(0xFF5BE1), panel: hex(0x0C0014, 0.55), stars: true, sun: hex(0xFF5B9A))
        case .daylight:
            return Theme(skyTop: hex(0x5FA6E8), skyHorizon: hex(0xDCEBF7), ground: hex(0xE9E4D6),
                         groundFar: hex(0xD7DDE0), grid: hex(0x8C8676, 0.28), routeAhead: hex(0x4A5A6E, 0.55),
                         routeDone: hex(0xFF5A1F), glow: hex(0xFF7A3C, 0.22), curtain: hex(0xFF5A1F, 0.14),
                         shadow: hex(0x3B342A, 0.18), runner: hex(0xFF3B00), fluid: hex(0x1B7FE0),
                         fuel: hex(0xF08A00), text: hex(0x1A2230), textSecondary: hex(0x4C5A6E),
                         accent: hex(0xE8501A), panel: hex(0xFFFFFF, 0.62), sun: hex(0xFFF4D6))
        case .blueprint:
            return Theme(skyTop: hex(0x0B3A75), skyHorizon: hex(0x1A5AA6), ground: hex(0x0E4A92),
                         groundFar: hex(0x1A5AA6), grid: hex(0xFFFFFF, 0.16), routeAhead: hex(0xFFFFFF, 0.5),
                         routeDone: hex(0xFFFFFF), glow: hex(0xBFE0FF, 0.2), curtain: hex(0xFFFFFF, 0.08),
                         shadow: hex(0x05244D, 0.5), runner: hex(0xFFE14D), fluid: hex(0x7FD3FF),
                         fuel: hex(0xFFD24D), text: hex(0xFFFFFF), textSecondary: hex(0xC5DCF5),
                         accent: hex(0xFFE14D), panel: hex(0x072B59, 0.55))
        case .mono:
            return Theme(skyTop: hex(0x0B0B0C), skyHorizon: hex(0x1E1E21), ground: hex(0x0E0E10),
                         groundFar: hex(0x1A1A1D), grid: hex(0xFFFFFF, 0.07), routeAhead: hex(0xFFFFFF, 0.28),
                         routeDone: hex(0xFFFFFF), glow: hex(0xFFFFFF, 0.10), curtain: hex(0xFFFFFF, 0.06),
                         shadow: hex(0x000000, 0.4), runner: hex(0xFFFFFF), fluid: hex(0x9CCBFF),
                         fuel: hex(0xFFC78A), text: hex(0xF5F5F5), textSecondary: hex(0x9A9A9F),
                         accent: hex(0xFFFFFF), panel: hex(0x000000, 0.45))
        }
    }
}
