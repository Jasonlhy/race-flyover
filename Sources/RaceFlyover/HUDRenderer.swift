import AppKit

/// A panel the HUD wants backed by Liquid Glass this frame.
struct GlassPanel: Equatable {
    var rect: CGRect
    var radius: CGFloat
    var alpha: CGFloat
}

/// Collects glass panel requests while the HUD draws.
final class GlassPanelLayout {
    var panels: [GlassPanel] = []
}

/// Independently drawn regions of the HUD. Each is rendered into its own small
/// layer, so a frame only repaints the panels that change instead of a
/// screen-sized transparent layer.
enum HUDPart: CaseIterable {
    case title, metrics, profile, minimal, card
}

/// Records where each part drew this frame (in HUD coordinates).
final class HUDFrames {
    var rects: [HUDPart: CGRect] = [:]
    func add(_ part: HUDPart, _ r: CGRect) { rects[part] = rects[part].map { $0.union(r) } ?? r }
}

/// Draws the 2D overlay: course title, live distance and elevation, the next
/// fluid and fuel stations, an elevation profile strip, and the intro/finish
/// cards. With `glass` set, panel backgrounds are left to real Liquid Glass
/// views behind the overlay and only their positions are recorded.
struct HUDRenderer {
    let theme: Theme
    let engine: FlyoverEngine
    let size: CGSize
    let thumbnail: Bool
    var glass: GlassPanelLayout?
    /// Neighbourhood names for the caption under the minimap.
    var area: AreaNamer?
    /// Which parts to draw (all by default) and where they ended up.
    var parts: Set<HUDPart> = Set(HUDPart.allCases)
    var frames: HUDFrames?
    /// The cross-fade to black between courses (the live overlay uses a layer instead).
    var drawsFade = true

    private var s: CGFloat { max(0.3, min(size.width / 1.6, size.height) / 1000) * CGFloat(engine.config.textScale) }
    private var margin: CGFloat { 44 * s }

    func draw(_ ctx: CGContext) {
        let mode = thumbnail ? HUDMode.minimal : engine.config.hud
        let a = CGFloat(engine.hudAlpha)
        if mode != .off && a > 0.01 {
            ctx.saveGState()
            ctx.setAlpha(a)
            if mode == .full {
                if parts.contains(.title) { drawTitle(ctx) }
                if parts.contains(.metrics) { drawMetrics(ctx) }
                if parts.contains(.profile) { drawProfile(ctx) }
            } else if parts.contains(.minimal) {
                drawMinimal(ctx)
                frames?.add(.minimal, CGRect(origin: .zero, size: size))
            }
            ctx.restoreGState()
        }
        if parts.contains(.card) {
            if engine.titleAlpha > 0.01 { drawTitleCard(ctx, alpha: CGFloat(engine.titleAlpha)) }
            if engine.finishAlpha > 0.01 { drawFinishCard(ctx, alpha: CGFloat(engine.finishAlpha)) }
        }
        if drawsFade && engine.fade > 0.001 {
            ctx.setFillColor(NSColor.black.withAlphaComponent(CGFloat(engine.fade)).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    private var course: Course { engine.course }
    private var units: Units { engine.config.units }
    private var currentKm: Double { course.officialKm(at: engine.distance) }

    private func panel(_ ctx: CGContext, _ r: CGRect, _ part: HUDPart) {
        frames?.add(part, r)
        if let glass {
            glass.panels.append(GlassPanel(rect: r, radius: 18 * s, alpha: CGFloat(engine.hudAlpha)))
        } else {
            Draw.roundedRect(ctx, r, radius: 14 * s, fill: theme.panel, stroke: theme.text.withAlphaComponent(0.08))
        }
    }

    // MARK: - Text metrics

    /// Vertical metrics for one line drawn with `draw(at:)`, relative to the
    /// line's top. Panels are laid out from cap-top and baseline so the visible
    /// padding is equal on every edge, rather than following font line boxes.
    private struct Line {
        let text: NSAttributedString
        let capTop: CGFloat
        let capHeight: CGFloat
        let baseline: CGFloat
        let descent: CGFloat
        var width: CGFloat { text.size().width }
    }

    private func line(_ text: NSAttributedString) -> Line {
        var font: NSFont?
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let f = value as? NSFont, f.pointSize > (font?.pointSize ?? 0) { font = f }
        }
        let f = font ?? .systemFont(ofSize: 12)
        return Line(text: text, capTop: f.ascender - f.capHeight, capHeight: f.capHeight,
                    baseline: f.ascender, descent: -f.descender)
    }

    /// Visible padding inside every panel.
    private var inset: CGFloat { 18 * s }
    /// How far below the baseline a panel's last line visually ends.
    private func bottomTrim(_ l: Line) -> CGFloat { l.descent * 0.25 }

    /// Stacks lines with `gaps[i]` from line i's baseline to line i+1's cap top.
    /// Returns each line's top offset (with the first cap top at 0) and the
    /// visual height of the stack.
    private func stack(_ lines: [Line], gaps: [CGFloat]) -> (tops: [CGFloat], height: CGFloat) {
        var tops: [CGFloat] = []
        var top = -lines[0].capTop
        for (i, l) in lines.enumerated() {
            if i > 0 { top = tops[i - 1] + lines[i - 1].baseline + gaps[i - 1] - l.capTop }
            tops.append(top)
        }
        let last = lines.count - 1
        return (tops, tops[last] + lines[last].baseline + bottomTrim(lines[last]))
    }

    // MARK: - Corners

    private func drawTitle(_ ctx: CGContext) {
        let eyebrow = line(Draw.text(course.isMajor ? "WORLD MARATHON MAJOR" : (course.isImported ? "YOUR COURSE" : "RACE COURSE"),
                                     size: 11.5 * s, weight: .bold, color: theme.accent, tracking: 2.2 * s))
        let nameText = NSMutableAttributedString()
        if let flag = course.flag {
            nameText.append(Draw.text(flag + " ", size: 26 * s, color: theme.text))
        }
        nameText.append(Draw.text(course.name, size: 30 * s, weight: .semibold, color: theme.text))
        let name = line(nameText)
        var sub = course.data.city
        if let month = course.data.month { sub += "  ·  " + month }
        let subtitle = line(Draw.text(sub, size: 14.5 * s, color: theme.textSecondary))
        var lines = [eyebrow, name, subtitle]
        var gaps = [15 * s, 15 * s]
        if course.data.stationsEstimated == true {
            lines.append(line(Draw.text("Aid stations estimated (every 5 km). Check the race guide.",
                                        size: 11.5 * s, color: theme.fuel)))
            gaps.append(14 * s)
        }
        let (tops, height) = stack(lines, gaps: gaps)
        let width = lines.map(\.width).max() ?? 0
        let box = CGRect(x: margin, y: margin, width: width + inset * 2, height: height + inset * 2)
        panel(ctx, box, .title)
        for (l, top) in zip(lines, tops) {
            l.text.draw(at: CGPoint(x: box.minX + inset, y: box.minY + inset + top))
        }
    }

    private func drawMetrics(_ ctx: CGContext) {
        let width = 340 * s
        let km = currentKm
        let total = course.data.distanceKm

        let label = line(Draw.text("DISTANCE", size: 11.5 * s, weight: .bold, color: theme.textSecondary, tracking: 2.2 * s))
        let bigText = NSMutableAttributedString(attributedString: Draw.text(
            String(format: "%.2f", km / units.kmPerUnit), size: 46 * s, weight: .light, color: theme.text, mono: true))
        bigText.append(Draw.text(" " + units.label, size: 18 * s, weight: .medium, color: theme.textSecondary))
        let big = line(bigText)
        let of = line(Draw.text("of " + units.format(km: total, decimals: total.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2)
                                + String(format: "  ·  %.0f%%", km / total * 100),
                                size: 13 * s, color: theme.textSecondary, mono: true))
        let elevation = course.elevation(at: engine.distance)
        let grade = course.grade(at: engine.distance)
        let arrow = grade > 0.4 ? "▲" : (grade < -0.4 ? "▼" : "▶︎")
        let elev = line(Draw.text(String(format: "Elev %@   %@ %.1f%%", units.formatElevation(elevation), arrow, abs(grade)),
                                  size: 13 * s, weight: .medium, color: theme.text, mono: true))

        let stations = course.data.stations.filter { $0.km >= km }
        let nextFluid = engine.config.showFluid ? stations.first(where: \.fluid) : nil
        let nextFuel = engine.config.showFuel ? stations.first(where: \.fuel) : nil
        let rows = [nextFluid.map { ($0, true) }, nextFuel.map { ($0, false) }].compactMap { $0 }

        // Vertical layout (offsets from the first cap top). The minimap and its
        // area caption sit in the top-left; the distance text is right-aligned.
        let textStack = stack([label, big, of], gaps: [10 * s, 10 * s])
        let mapSize = CGSize(width: 124 * s, height: 86 * s)
        let caption = areaCaption(maxWidth: width - big.width - 14 * s)
        let captionTop = mapSize.height + 9 * s - caption.capTop
        let leftBottom = captionTop + caption.baseline
        let barTop = max(textStack.tops[2] + of.baseline, leftBottom) + 14 * s
        let barH = 4 * s
        let elevTop = barTop + barH + 12 * s - elev.capTop
        var bottom = elevTop + elev.baseline + bottomTrim(elev)
        let rowTitle = { (fluid: Bool) in self.line(Draw.text(fluid ? "NEXT FLUIDS" : "NEXT FUEL", size: 10 * s, weight: .bold,
                                                              color: fluid ? self.theme.fluid : self.theme.fuel, tracking: 1.5 * s)) }
        let sample = line(Draw.text("Ag", size: 12.5 * s, color: theme.textSecondary))
        let titleSample = rowTitle(true)
        let blockH = (titleSample.baseline - titleSample.capTop) + 7 * s + sample.capHeight
        let rowGap = 11 * s
        var rowTops: [CGFloat] = []
        for _ in rows {
            let separator = (rowTops.last.map { $0 + blockH } ?? (elevTop + elev.baseline)) + rowGap
            rowTops.append(separator + rowGap)
            bottom = separator + rowGap + blockH
        }

        let box = CGRect(x: size.width - margin - width - inset * 2, y: margin, width: width + inset * 2,
                         height: bottom + inset * 2)
        panel(ctx, box, .metrics)
        let left = box.minX + inset, right = box.maxX - inset, top = box.minY + inset
        drawMinimap(ctx, in: CGRect(origin: CGPoint(x: left, y: top), size: mapSize))
        drawAreaCaption(ctx, caption, at: CGPoint(x: left, y: top + captionTop))
        label.text.draw(at: CGPoint(x: right - label.width, y: top + textStack.tops[0]))
        big.text.draw(at: CGPoint(x: right - big.width, y: top + textStack.tops[1]))
        of.text.draw(at: CGPoint(x: right - of.width, y: top + textStack.tops[2]))

        let bar = CGRect(x: left, y: top + barTop, width: width, height: barH)
        Draw.roundedRect(ctx, bar, radius: barH / 2, fill: theme.text.withAlphaComponent(0.12))
        Draw.roundedRect(ctx, CGRect(x: bar.minX, y: bar.minY, width: bar.width * CGFloat(min(1, km / total)), height: barH),
                         radius: barH / 2, fill: theme.routeDone)
        elev.text.draw(at: CGPoint(x: right - elev.width, y: top + elevTop))

        for ((station, fluid), rowTop) in zip(rows, rowTops) {
            let y = top + rowTop
            ctx.setFillColor(theme.text.withAlphaComponent(0.10).cgColor)
            ctx.fill(CGRect(x: left, y: y - rowGap - 0.5, width: width, height: 1))
            let badgeR = 11 * s
            let shown = Station(km: station.km, fluid: fluid, fuel: !fluid, label: station.label)
            Draw.stationBadge(ctx, center: CGPoint(x: left + badgeR, y: y + blockH / 2), radius: badgeR,
                              station: shown, theme: theme, alpha: 1)
            let title = rowTitle(fluid)
            let dist = line(Draw.text(units.formatAhead(km: max(0, station.km - km)), size: 15 * s, weight: .semibold,
                                      color: theme.text, mono: true))
            let textX = left + badgeR * 2 + 10 * s
            let detail = line(truncated(station.label, size: 12.5 * s, color: theme.textSecondary,
                                        width: right - dist.width - 12 * s - textX))
            title.text.draw(at: CGPoint(x: textX, y: y - title.capTop))
            detail.text.draw(at: CGPoint(x: textX, y: y + blockH - detail.baseline))
            dist.text.draw(at: CGPoint(x: right - dist.width, y: y + blockH / 2 - dist.capTop - dist.capHeight / 2))
        }
    }

    // MARK: - Minimap

    /// North-up outline of the whole course with the covered part, start,
    /// finish, and the runner's position.
    private func drawMinimap(_ ctx: CGContext, in rect: CGRect) {
        Draw.roundedRect(ctx, rect, radius: 10 * s, fill: theme.text.withAlphaComponent(0.07),
                         stroke: theme.text.withAlphaComponent(0.10))
        let c = course
        let pad = 9 * s
        let area = rect.insetBy(dx: pad, dy: pad)
        let w = max(c.maxX - c.minX, 1), h = max(c.maxY - c.minY, 1)
        let k = min(Double(area.width) / w, Double(area.height) / h)
        let ox = Double(area.midX) - (c.minX + w / 2) * k
        let oy = Double(area.midY) + (c.minY + h / 2) * k
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + x * k, y: oy - y * k) }

        let step = max(1, c.x.count / 360)
        let full = CGMutablePath()
        full.addLines(between: stride(from: 0, to: c.x.count, by: step).map { pt(c.x[$0], c.y[$0]) } + [pt(c.x.last!, c.y.last!)])
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(full)
        ctx.setStrokeColor(theme.textSecondary.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1.6 * s)
        ctx.strokePath()

        let (ri, rt) = c.locate(engine.distance)
        let runner = c.sample(at: engine.distance)
        if ri > 0 || rt > 0 {
            let done = CGMutablePath()
            done.addLines(between: stride(from: 0, through: ri, by: step).map { pt(c.x[$0], c.y[$0]) } + [pt(runner.x, runner.y)])
            ctx.addPath(done)
            ctx.setStrokeColor(theme.routeDone.cgColor)
            ctx.setLineWidth(3.4 * s)
            ctx.strokePath()
        }
        // Start (ring) and finish (filled square).
        let start = pt(c.x[0], c.y[0]), finish = pt(c.x.last!, c.y.last!)
        ctx.setStrokeColor(theme.text.cgColor)
        ctx.setLineWidth(1.2 * s)
        ctx.strokeEllipse(in: CGRect(x: start.x - 3 * s, y: start.y - 3 * s, width: 6 * s, height: 6 * s))
        ctx.setFillColor(theme.text.cgColor)
        ctx.fill(CGRect(x: finish.x - 2.5 * s, y: finish.y - 2.5 * s, width: 5 * s, height: 5 * s))
        // Runner with a soft pulse.
        let p = pt(runner.x, runner.y)
        let pulse = CGFloat((engine.time * 0.9).truncatingRemainder(dividingBy: 1))
        Draw.radialGlow(ctx, center: p, radius: (7 + 6 * pulse) * s, color: theme.routeDone.withAlphaComponent(0.55 * (1 - pulse)))
        Theme.drawPin(ctx, at: p, radius: 5.5 * s, color: theme.runner)
        ctx.restoreGState()
    }

    private func areaCaption(maxWidth: CGFloat) -> Line {
        let text = area?.name ?? course.data.city.components(separatedBy: ",").first ?? ""
        let pin = Draw.text("⌖ ", size: 11 * s, weight: .bold, color: theme.accent)
        let body = truncated(text, size: 11.5 * s, color: theme.text, width: max(60 * s, maxWidth) - pin.size().width,
                             weight: .medium)
        let s = NSMutableAttributedString(attributedString: pin)
        s.append(body)
        return line(s)
    }

    /// Fades the caption in when the area changes (the HUD redraws every frame).
    private func drawAreaCaption(_ ctx: CGContext, _ caption: Line, at p: CGPoint) {
        let fade = area.map { CGFloat(min(1, max(0, (CACurrentMediaTime() - $0.changedAt) / 0.6))) } ?? 1
        ctx.saveGState()
        ctx.setAlpha(fade)
        caption.text.draw(at: p)
        ctx.restoreGState()
    }

    private func truncated(_ s: String, size: CGFloat, color: NSColor, width: CGFloat,
                           weight: NSFont.Weight = .regular) -> NSAttributedString {
        var text = s
        var a = Draw.text(text, size: size, weight: weight, color: color)
        while a.size().width > width && text.count > 4 {
            text = String(text.dropLast(2))
            a = Draw.text(text + "…", size: size, weight: weight, color: color)
        }
        return a
    }

    // MARK: - Elevation profile

    private var profileTitle: Line {
        line(Draw.text("ELEVATION PROFILE  ·  " + units.label.uppercased(), size: 10 * s, weight: .bold,
                       color: theme.textSecondary, tracking: 1.6 * s))
    }

    private func tickLabel(_ text: String) -> Line {
        line(Draw.text(text, size: 10.5 * s, color: theme.textSecondary, mono: true))
    }

    /// Profile panel layout: offsets from the first cap top.
    private var profileLayout: (plotTop: CGFloat, plotHeight: CGFloat, tickTop: CGFloat, height: CGFloat) {
        let title = profileTitle, tick = tickLabel("0")
        let plotTop = title.baseline - title.capTop + 14 * s
        let plotHeight = 70 * s
        let tickTop = plotTop + plotHeight + 9 * s - tick.capTop
        return (plotTop, plotHeight, tickTop, tickTop + tick.baseline + bottomTrim(tick))
    }

    private func drawProfile(_ ctx: CGContext) {
        let layout = profileLayout
        let boxH = layout.height + inset * 2
        let box = CGRect(x: margin, y: size.height - margin - boxH, width: size.width - margin * 2, height: boxH)
        panel(ctx, box, .profile)
        let top = box.minY + inset
        let topLabel = tickLabel(units.formatElevation(course.maxEle))
        let bottomLabel = tickLabel(units.formatElevation(course.minEle))
        let labelColumn = max(topLabel.width, bottomLabel.width)
        let plot = CGRect(x: box.minX + inset + labelColumn + 10 * s, y: top + layout.plotTop,
                          width: box.width - inset * 2 - labelColumn - 10 * s, height: layout.plotHeight)
        let prof = course.profile
        // Keep flat courses from looking mountainous: at least 40 m of vertical range.
        let lo = course.minEle, hi = max(course.maxEle, course.minEle + 40)
        func pt(_ i: Int) -> CGPoint {
            CGPoint(x: plot.minX + plot.width * CGFloat(i) / CGFloat(prof.count - 1),
                    y: plot.maxY - plot.height * CGFloat((prof[i] - lo) / (hi - lo)) * 0.9)
        }
        let area = CGMutablePath()
        area.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        for i in prof.indices { area.addLine(to: pt(i)) }
        area.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        area.closeSubpath()
        let profileLine = CGMutablePath()
        profileLine.addLines(between: prof.indices.map(pt))

        let frac = CGFloat(engine.distance / course.length)
        let cursorX = plot.minX + plot.width * frac

        ctx.saveGState()
        ctx.addPath(area)
        ctx.setFillColor(theme.text.withAlphaComponent(0.10).cgColor)
        ctx.fillPath()
        ctx.addPath(profileLine)
        ctx.setStrokeColor(theme.text.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(1.2 * s)
        ctx.strokePath()
        // Covered portion
        ctx.clip(to: CGRect(x: plot.minX, y: plot.minY - 4, width: cursorX - plot.minX, height: plot.height + 8))
        ctx.addPath(area)
        ctx.setFillColor(theme.routeDone.withAlphaComponent(0.28).cgColor)
        ctx.fillPath()
        ctx.addPath(profileLine)
        ctx.setStrokeColor(theme.routeDone.cgColor)
        ctx.setLineWidth(2 * s)
        ctx.strokePath()
        ctx.restoreGState()

        // Elevation scale
        let peakY = pt(prof.firstIndex(of: prof.max()!) ?? 0).y
        topLabel.text.draw(at: CGPoint(x: plot.minX - 10 * s - topLabel.width,
                                       y: max(top - topLabel.capTop, peakY - topLabel.capTop - topLabel.capHeight / 2)))
        bottomLabel.text.draw(at: CGPoint(x: plot.minX - 10 * s - bottomLabel.width, y: plot.maxY - bottomLabel.baseline))

        // Distance ticks
        let total = course.data.distanceKm
        let unitKm = units.kmPerUnit
        let stepUnits: Double = total / unitKm > 30 ? 5 : (total / unitKm > 12 ? 2 : 1)
        var u = 0.0
        while u <= total / unitKm + 0.001 {
            let x = plot.minX + plot.width * CGFloat(u * unitKm / total)
            ctx.setFillColor(theme.text.withAlphaComponent(0.25).cgColor)
            ctx.fill(CGRect(x: x - 0.5, y: plot.maxY, width: 1, height: 4 * s))
            let t = tickLabel(String(format: "%.0f", u))
            // Keep the end labels inside the panel's padding.
            let tx = min(max(x - t.width / 2, plot.minX - t.width / 2), box.maxX - inset - t.width)
            t.text.draw(at: CGPoint(x: tx, y: top + layout.tickTop))
            u += stepUnits
        }

        // Stations along the strip
        for st in course.data.stations where (st.fluid && engine.config.showFluid) || (st.fuel && engine.config.showFuel) {
            let x = plot.minX + plot.width * CGFloat(st.km / total)
            let passed = st.km < currentKm
            let a: CGFloat = passed ? 0.45 : 1
            if st.fluid {
                ctx.setFillColor(theme.fluid.withAlphaComponent(a).cgColor)
                ctx.fillEllipse(in: CGRect(x: x - 3 * s, y: plot.minY - 1 * s, width: 6 * s, height: 6 * s))
            }
            if st.fuel {
                ctx.setFillColor(theme.fuel.withAlphaComponent(a).cgColor)
                let y = plot.minY + (st.fluid ? 7 * s : -1 * s)
                ctx.addPath(CGPath(rect: CGRect(x: x - 3 * s, y: y, width: 6 * s, height: 6 * s),
                                   transform: nil))
                ctx.fillPath()
            }
            ctx.setFillColor((st.fluid ? theme.fluid : theme.fuel).withAlphaComponent(0.25 * a).cgColor)
            ctx.fill(CGRect(x: x - 0.5 * s, y: plot.minY + 6 * s, width: 1 * s, height: plot.height - 6 * s))
        }

        // Cursor
        let cy = pt(min(prof.count - 1, Int(frac * CGFloat(prof.count - 1)))).y
        ctx.setFillColor(theme.text.withAlphaComponent(0.7).cgColor)
        ctx.fill(CGRect(x: cursorX - 0.75 * s, y: plot.minY, width: 1.5 * s, height: plot.height))
        Theme.drawPin(ctx, at: CGPoint(x: cursorX, y: cy), radius: 6.5 * s, color: theme.runner)

        // Legend
        let legend = NSMutableAttributedString()
        legend.append(Draw.text("●", size: 10 * s, color: theme.fluid))
        legend.append(Draw.text(" Fluids \(course.fluidStations)    ", size: 10.5 * s, color: theme.textSecondary))
        legend.append(Draw.text("■", size: 10 * s, color: theme.fuel))
        legend.append(Draw.text(" Fuel \(course.fuelStations)    ", size: 10.5 * s, color: theme.textSecondary))
        legend.append(Draw.text("↗ " + units.formatElevation(course.elevationGain) + " gain",
                                size: 10.5 * s, color: theme.textSecondary))
        let title = profileTitle
        let legendLine = line(legend)
        // Legend shares the title's baseline.
        title.text.draw(at: CGPoint(x: box.minX + inset, y: top - title.capTop))
        legendLine.text.draw(at: CGPoint(x: box.maxX - inset - legendLine.width, y: top - title.capTop + title.baseline - legendLine.baseline))
    }

    // MARK: - Minimal / thumbnail

    private func drawMinimal(_ ctx: CGContext) {
        let m = thumbnail ? 10 * s : margin
        let name = Draw.text(course.name, size: (thumbnail ? 26 : 18) * s, weight: .semibold, color: theme.text)
        Draw.string(name, at: CGPoint(x: m, y: m))
        let dist = Draw.text(units.format(km: currentKm, decimals: 1), size: (thumbnail ? 26 : 18) * s,
                             weight: .medium, color: theme.text, mono: true)
        Draw.string(dist, at: CGPoint(x: size.width - m, y: m), anchor: 1)
        let bar = CGRect(x: m, y: size.height - m - 3 * s, width: size.width - m * 2, height: 3 * s)
        Draw.roundedRect(ctx, bar, radius: 1.5 * s, fill: theme.text.withAlphaComponent(0.15))
        Draw.roundedRect(ctx, CGRect(x: bar.minX, y: bar.minY, width: bar.width * CGFloat(engine.distance / course.length),
                                     height: bar.height), radius: 1.5 * s, fill: theme.routeDone)
        for st in course.data.stations where (st.fluid && engine.config.showFluid) || (st.fuel && engine.config.showFuel) {
            let x = bar.minX + bar.width * CGFloat(st.km / course.data.distanceKm)
            ctx.setFillColor((st.fluid ? theme.fluid : theme.fuel).cgColor)
            ctx.fillEllipse(in: CGRect(x: x - 2.5 * s, y: bar.minY - 7 * s, width: 5 * s, height: 5 * s))
        }
    }

    // MARK: - Cards

    /// Lays out centred lines from the bottom up so cards sit clear of the macOS
    /// clock, which occupies the top centre of the screen while the saver runs.
    private func drawCentredLines(_ ctx: CGContext, _ lines: [(NSAttributedString, CGFloat)], bottom: CGFloat,
                                  alpha: CGFloat) {
        let height = lines.reduce(0) { $0 + $1.0.size().height + $1.1 }
        let top = bottom - height
        let width = lines.map { $0.0.size().width }.max() ?? 0
        let card = CGRect(x: (size.width - width) / 2 - 44 * s, y: top - 26 * s,
                          width: width + 88 * s, height: height + 48 * s)
        if let glass {
            glass.panels.append(GlassPanel(rect: card, radius: 30 * s, alpha: alpha))
            frames?.add(.card, card)
        } else {
            let band = CGRect(x: 0, y: top - 70 * s, width: size.width, height: min(size.height, bottom + 70 * s) - (top - 70 * s))
            scrim(ctx, from: band.minY, to: band.maxY)
            frames?.add(.card, band)
        }
        var y = top
        for (line, gap) in lines {
            y += Draw.string(line, at: CGPoint(x: size.width / 2, y: y), anchor: 0.5).height + gap
        }
    }

    /// Top edge of the elevation-profile panel (when the full HUD is showing).
    private var profileTop: CGFloat {
        size.height - margin - (profileLayout.height + inset * 2)
    }

    private func drawTitleCard(_ ctx: CGContext, alpha: CGFloat) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        var lines: [(NSAttributedString, CGFloat)] = []
        if course.isMajor {
            lines.append((Draw.text("WORLD MARATHON MAJOR", size: 14 * s, weight: .bold, color: theme.accent,
                                    tracking: 4 * s), 4 * s))
        }
        lines.append((Draw.text(course.name.uppercased(), size: 58 * s, weight: .heavy, color: theme.text,
                                tracking: 2 * s), 0))
        lines.append((Draw.text(course.data.city, size: 20 * s, weight: .regular, color: theme.textSecondary), 16 * s))
        let total = course.data.distanceKm
        let stats = [
            units.format(km: total, decimals: units == .km ? 3 : 1),
            plural(course.fluidStations, "fluid station"),
            plural(course.fuelStations, "fuel station"),
            units.formatElevation(course.elevationGain) + " climbing",
        ].joined(separator: "   ·   ")
        lines.append((Draw.text(stats, size: 16 * s, weight: .medium, color: theme.text, mono: true), 0))
        // The HUD (and its elevation strip) fades in only after this card has gone.
        drawCentredLines(ctx, lines, bottom: size.height - margin - 10 * s - (glass != nil ? 24 * s : 0), alpha: alpha)
        ctx.restoreGState()
    }

    private func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    /// Soft dark band behind the centred cards so they stay legible over the scene.
    private func scrim(_ ctx: CGContext, from top: CGFloat, to bottom: CGFloat) {
        let colors = [0.0, 0.6, 0.6, 0.0].map { NSColor.black.withAlphaComponent($0).cgColor }
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
                                 locations: [0, 0.3, 0.75, 1]) else { return }
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
    }

    private func drawFinishCard(_ ctx: CGContext, alpha: CGFloat) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        let lines: [(NSAttributedString, CGFloat)] = [
            (Draw.text("FINISH", size: 84 * s, weight: .black, color: theme.accent, tracking: 8 * s), 0),
            (Draw.text(course.name + "  ·  " + units.format(km: course.data.distanceKm, decimals: units == .km ? 3 : 1),
                       size: 20 * s, weight: .medium, color: theme.text), 0),
        ]
        let fullHUD = !thumbnail && engine.config.hud == .full
        drawCentredLines(ctx, lines, bottom: (fullHUD ? profileTop - 24 * s : size.height - margin - 10 * s)
                         - (glass != nil ? 24 * s : 0), alpha: alpha)
        ctx.restoreGState()
    }
}
