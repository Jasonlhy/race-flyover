import AppKit
import simd

/// Perspective camera for the stylized scene. World space is metres: x east,
/// y north, z up.
struct Projector {
    let eye: SIMD3<Double>
    let right: SIMD3<Double>
    let up: SIMD3<Double>
    let forward: SIMD3<Double>
    let focal: Double
    let cx: Double
    let cy: Double
    let near: Double
    /// Screen y of the horizon, when the camera is tilted enough to see it.
    let horizonY: Double?

    init(camera: CameraState, target: SIMD3<Double>, size: CGSize) {
        let h = camera.heading, t = camera.tilt
        forward = SIMD3(sin(t) * sin(h), sin(t) * cos(h), -cos(t))
        right = SIMD3(cos(h), -sin(h), 0)
        up = simd_cross(right, forward)
        eye = target - forward * camera.distance
        focal = Double(size.height) / 2 / tan(FlyoverEngine.fieldOfView / 2)
        cx = Double(size.width) / 2
        // Sit the look-at point below centre when tilted so more road ahead shows.
        cy = Double(size.height) * (0.5 + 0.13 * sin(t))
        near = max(0.5, camera.distance * 0.02)
        let level = SIMD3(sin(h), cos(h), 0.0)
        let zc = simd_dot(level, forward)
        horizonY = zc > 1e-3 ? cy - focal * simd_dot(level, up) / zc : nil
    }

    @inline(__always) func toCamera(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let v = p - eye
        return SIMD3(simd_dot(v, right), simd_dot(v, up), simd_dot(v, forward))
    }

    @inline(__always) func screen(_ c: SIMD3<Double>) -> CGPoint {
        CGPoint(x: cx + focal * c.x / c.z, y: cy - focal * c.y / c.z)
    }

    /// Screen point and depth, or nil when behind the camera.
    func project(_ p: SIMD3<Double>) -> (CGPoint, Double)? {
        let c = toCamera(p)
        return c.z > near ? (screen(c), c.z) : nil
    }

    private func clip(_ inside: SIMD3<Double>, _ outside: SIMD3<Double>) -> SIMD3<Double> {
        let t = (inside.z - near) / (inside.z - outside.z)
        return inside + (outside - inside) * t
    }

    /// Appends a 3D polyline to `path`, clipping at the near plane.
    func addPolyline(to path: CGMutablePath, count: Int, stride step: Int = 1, _ point: (Int) -> SIMD3<Double>) {
        guard count >= 2 else { return }
        var prev = toCamera(point(0))
        var penDown = false
        var i = step
        while true {
            let idx = min(i, count - 1)
            let c = toCamera(point(idx))
            let pIn = prev.z > near, cIn = c.z > near
            if pIn && cIn {
                if !penDown { path.move(to: screen(prev)); penDown = true }
                path.addLine(to: screen(c))
            } else if pIn {
                if !penDown { path.move(to: screen(prev)) }
                path.addLine(to: screen(clip(prev, c)))
                penDown = false
            } else if cIn {
                path.move(to: screen(clip(c, prev)))
                path.addLine(to: screen(c))
                penDown = true
            }
            prev = c
            if idx == count - 1 { break }
            i += step
        }
    }

    func addSegment(to path: CGMutablePath, _ a: SIMD3<Double>, _ b: SIMD3<Double>) {
        addPolyline(to: path, count: 2) { $0 == 0 ? a : b }
    }
}

/// Self-contained renderer: a perspective flyover over a stylized ground grid,
/// the route raised on a translucent elevation curtain, and the HUD on top.
final class StylizedView: NSView {
    weak var engine: FlyoverEngine?
    var theme = Theme.forStyle(.midnight)
    var isThumbnail = false
    /// Map imagery is drawn underneath by `TileGroundView`: leave the ground
    /// transparent, keep the route flat on it, and credit the imagery.
    var tileMode = false
    var attribution: String?

    private var cacheKey = ""
    private var points: [SIMD3<Double>] = []
    private let stars: [(CGFloat, CGFloat, CGFloat)] = {
        var rng = SystemRandomNumberGenerator()
        return (0..<180).map { _ in
            (CGFloat.random(in: 0...1, using: &rng), CGFloat.random(in: 0...1, using: &rng),
             CGFloat.random(in: 0.3...1, using: &rng))
        }
    }()

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { !tileMode }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func prepare(_ course: Course, exaggeration: Double) {
        let key = "\(course.id)-\(exaggeration)"
        guard key != cacheKey else { return }
        cacheKey = key
        points = course.x.indices.map {
            SIMD3(course.x[$0], course.y[$0], (course.ele[$0] - course.minEle) * exaggeration)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        FrameStats.shared.measure("sceneDraw") { drawScene() }
    }

    private func drawScene() {
        guard let engine, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let size = bounds.size
        let course = engine.course
        let config = engine.config
        let ex = tileMode ? 0 : config.exaggeration
        prepare(course, exaggeration: ex)

        var cam = engine.camera
        let target = SIMD3(cam.target.x, cam.target.y, (cam.target.z - course.minEle) * ex)
        cam.target = target
        let proj = Projector(camera: cam, target: target, size: size)
        let s = max(0.32, min(size.width, size.height * 1.6) / 1700) // UI scale
        let D = cam.distance

        if tileMode {
            ctx.clear(CGRect(origin: .zero, size: size))
        }
        drawBackdrop(ctx, size: size, proj: proj, time: engine.time)
        if !tileMode { drawGrid(ctx, size: size, proj: proj, target: target, camera: cam, scale: s) }

        let (runnerIndex, runnerT) = course.locate(engine.distance)
        let runnerPoint: SIMD3<Double> = {
            let a = points[runnerIndex], b = points[min(runnerIndex + 1, points.count - 1)]
            return a + (b - a) * runnerT
        }()

        // Elevation curtain between the ground and the raised route.
        if ex > 0.01 && cam.tilt > 0.15 {
            let path = CGMutablePath()
            let step = D > 4000 ? 4 : 2
            var i = 0
            while i < points.count - 1 {
                let j = min(i + step, points.count - 1)
                let a = points[i], b = points[j]
                let quad = [a, b, SIMD3(b.x, b.y, 0), SIMD3(a.x, a.y, 0)].compactMap { proj.project($0)?.0 }
                if quad.count == 4 { path.addLines(between: quad); path.closeSubpath() }
                i = j
            }
            ctx.addPath(path)
            ctx.setFillColor(theme.curtain.cgColor)
            ctx.fillPath()
        }

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Ground shadow of the route.
        if ex > 0.01 {
            let shadow = CGMutablePath()
            proj.addPolyline(to: shadow, count: points.count, stride: 2) { SIMD3(self.points[$0].x, self.points[$0].y, 0) }
            stroke(ctx, shadow, theme.shadow, 3 * s)
        }

        // Route still to run.
        let ahead = CGMutablePath()
        let aheadCount = points.count - runnerIndex
        proj.addPolyline(to: ahead, count: aheadCount + 1) { k in
            k == 0 ? runnerPoint : self.points[min(runnerIndex + k, self.points.count - 1)]
        }
        if tileMode { stroke(ctx, ahead, NSColor.black.withAlphaComponent(0.45), 6 * s) }
        stroke(ctx, ahead, theme.routeAhead, (tileMode ? 3.2 : 2.6) * s)

        // Route already covered, with a soft glow.
        let done = CGMutablePath()
        proj.addPolyline(to: done, count: runnerIndex + 2) { k in
            k <= runnerIndex ? self.points[k] : runnerPoint
        }
        // Covered route: a thick trail that ends exactly at the pin.
        stroke(ctx, done, theme.glow, 22 * s)
        stroke(ctx, done, NSColor.black.withAlphaComponent(tileMode ? 0.35 : 0.2), 10 * s)
        stroke(ctx, done, theme.routeDone, 7 * s)

        drawFog(ctx, size: size, proj: proj)

        let currentKm = course.officialKm(at: engine.distance)
        let labelScale = s * CGFloat(config.textScale)
        if config.showMarkers { drawMarkers(ctx, course: course, proj: proj, D: D, scale: labelScale, currentKm: currentKm) }
        drawStartFinish(ctx, course: course, proj: proj, D: D, scale: labelScale)
        if config.showLandmarks {
            drawLandmarks(ctx, course: course, proj: proj, D: D, scale: labelScale, currentKm: currentKm)
        }
        drawStations(ctx, course: course, proj: proj, D: D, scale: labelScale, currentKm: currentKm, config: config)
        drawRunner(ctx, at: runnerPoint, proj: proj, D: D, scale: s, time: engine.time)

        if tileMode, let attribution {
            let t = Draw.text(attribution, size: max(9, 10 * s), color: NSColor.white.withAlphaComponent(0.75))
            let r = CGRect(x: size.width - t.size().width - 14 * s, y: size.height - t.size().height - 8 * s,
                           width: t.size().width + 8 * s, height: t.size().height + 2 * s)
            Draw.roundedRect(ctx, r, radius: 3 * s, fill: NSColor.black.withAlphaComponent(0.35))
            t.draw(at: CGPoint(x: r.minX + 4 * s, y: r.minY + 1 * s))
        }
    }

    private func stroke(_ ctx: CGContext, _ path: CGPath, _ color: NSColor, _ width: CGFloat) {
        ctx.addPath(path)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.strokePath()
    }

    // MARK: - Backdrop

    private func drawBackdrop(_ ctx: CGContext, size: CGSize, proj: Projector, time: Double) {
        let full = CGRect(origin: .zero, size: size)
        guard let hy = proj.horizonY.map({ CGFloat($0) }), hy > -size.height * 0.2 else {
            if !tileMode {
                Draw.linearGradient(ctx, rect: full, from: theme.groundFar, to: theme.ground,
                                    start: .zero, end: CGPoint(x: 0, y: size.height))
            }
            return
        }
        let sky = CGRect(x: 0, y: 0, width: size.width, height: max(0, hy))
        Draw.linearGradient(ctx, rect: sky, from: theme.skyTop, to: theme.skyHorizon,
                            start: CGPoint(x: 0, y: hy - size.height * 0.55), end: CGPoint(x: 0, y: hy))
        if theme.stars && hy > 0 {
            for (i, star) in stars.enumerated() {
                let y = star.1 * hy * 0.92
                let twinkle = 0.55 + 0.45 * sin(time * (0.6 + Double(i % 7) * 0.13) + Double(i))
                let a = star.2 * CGFloat(twinkle) * min(1, (hy - y) / (size.height * 0.15))
                ctx.setFillColor(NSColor.white.withAlphaComponent(a * 0.7).cgColor)
                let r = star.2 * 1.3
                ctx.fillEllipse(in: CGRect(x: star.0 * size.width, y: y, width: r, height: r))
            }
        }
        if let sun = theme.sun, hy > 0 {
            ctx.saveGState()
            ctx.clip(to: sky)
            Draw.radialGlow(ctx, center: CGPoint(x: size.width / 2, y: hy), radius: size.height * 0.55,
                            color: sun.withAlphaComponent(0.35))
            if theme.stars { // synthwave sun for the neon style
                let r = size.height * 0.13
                let disc = CGRect(x: size.width / 2 - r, y: hy - r * 1.25, width: r * 2, height: r * 2)
                ctx.addEllipse(in: disc)
                ctx.clip()
                Draw.linearGradient(ctx, rect: disc, from: Theme.hex(0xFFE36E), to: sun,
                                    start: CGPoint(x: 0, y: disc.minY), end: CGPoint(x: 0, y: disc.maxY))
                ctx.setFillColor(theme.skyHorizon.cgColor)
                for k in 0..<6 {
                    let y = disc.midY + CGFloat(k) * r * 0.16
                    ctx.fill(CGRect(x: disc.minX, y: y, width: disc.width, height: r * 0.02 * CGFloat(k + 1)))
                }
            }
            ctx.restoreGState()
        }
        guard !tileMode else { return }
        let ground = CGRect(x: 0, y: max(0, hy), width: size.width, height: size.height - max(0, hy))
        Draw.linearGradient(ctx, rect: ground, from: theme.groundFar, to: theme.ground,
                            start: CGPoint(x: 0, y: hy), end: CGPoint(x: 0, y: hy + size.height * 0.45))
    }

    private func drawFog(_ ctx: CGContext, size: CGSize, proj: Projector) {
        guard let hy = proj.horizonY.map({ CGFloat($0) }), hy > -size.height * 0.1, hy < size.height else { return }
        let band = size.height * 0.2
        Draw.linearGradient(ctx, rect: CGRect(x: 0, y: hy - 2, width: size.width, height: band + 2),
                            from: theme.groundFar.withAlphaComponent(0.98), to: theme.groundFar.withAlphaComponent(0),
                            start: CGPoint(x: 0, y: hy), end: CGPoint(x: 0, y: hy + band))
        // Thin glowing horizon line.
        ctx.setFillColor(theme.skyHorizon.blended(withFraction: 0.4, of: .white)!.withAlphaComponent(0.35).cgColor)
        ctx.fill(CGRect(x: 0, y: hy - 0.5, width: size.width, height: 1))
    }

    private func drawGrid(_ ctx: CGContext, size: CGSize, proj: Projector, target: SIMD3<Double>,
                          camera: CameraState, scale: CGFloat) {
        let D = camera.distance
        let extent = D * (2.2 + 9 * pow(sin(camera.tilt), 3))
        let raw = extent / 26
        let steps: [Double] = [25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 25000]
        let step = steps.first { $0 >= raw } ?? 25000
        ctx.setLineWidth(max(0.6, 1 * scale))
        for axis in 0..<2 {
            let c = axis == 0 ? target.x : target.y
            let other = axis == 0 ? target.y : target.x
            var v = ((c - extent) / step).rounded(.down) * step
            while v <= c + extent {
                let d = abs(v - c) / extent
                let alpha = pow(max(0, 1 - d), 1.6)
                if alpha > 0.02 {
                    let path = CGMutablePath()
                    let a = axis == 0 ? SIMD3(v, other - extent, 0) : SIMD3(other - extent, v, 0)
                    let b = axis == 0 ? SIMD3(v, other + extent, 0) : SIMD3(other + extent, v, 0)
                    proj.addSegment(to: path, a, b)
                    ctx.addPath(path)
                    let major = (v / step).rounded().truncatingRemainder(dividingBy: 5) == 0
                    ctx.setStrokeColor(theme.grid.withAlphaComponent(theme.grid.alphaComponent * CGFloat(alpha) * (major ? 1.8 : 1)).cgColor)
                    ctx.strokePath()
                }
                v += step
            }
        }
    }

    // MARK: - Course furniture

    private func depthAlpha(_ z: Double, D: Double) -> CGFloat {
        CGFloat(1 - smoothstep((z - D * 2.5) / (D * 5)))
    }

    private func point3(_ course: Course, km: Double) -> SIMD3<Double> {
        let d = course.along(officialKm: km)
        let (i, t) = course.locate(d)
        let a = points[i], b = points[min(i + 1, points.count - 1)]
        return a + (b - a) * t
    }

    private func drawMarkers(_ ctx: CGContext, course: Course, proj: Projector, D: Double, scale s: CGFloat,
                             currentKm: Double) {
        let units = engine?.config.units ?? .km
        let n = Int(course.data.distanceKm / units.kmPerUnit)
        guard n >= 1 else { return }
        for k in 1...n {
            let km = Double(k) * units.kmPerUnit
            guard let (p, z) = proj.project(point3(course, km: km)) else { continue }
            let a = depthAlpha(z, D: D) * (km < currentKm ? 0.55 : 1)
            guard a > 0.03 else { continue }
            let r = 2.6 * s
            ctx.setFillColor(theme.text.withAlphaComponent(0.85 * a).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            if k % 5 == 0 {
                let label = Draw.text(units == .km ? "\(k)K" : "MI \(k)", size: 12 * s, weight: .bold,
                                      color: theme.text.withAlphaComponent(a), tracking: 0.6 * s)
                Draw.pill(ctx, label, above: CGPoint(x: p.x, y: p.y - 6 * s),
                          fill: theme.panel.withAlphaComponent(theme.panel.alphaComponent * a), padding: 3.5 * s)
            }
        }
        if course.data.distanceKm > 40, let (p, z) = proj.project(point3(course, km: course.data.distanceKm / 2)) {
            let a = depthAlpha(z, D: D)
            if a > 0.03 {
                let label = Draw.text("HALF", size: 12 * s, weight: .heavy, color: theme.accent.withAlphaComponent(a),
                                      tracking: 1 * s)
                Draw.pill(ctx, label, above: CGPoint(x: p.x, y: p.y - 6 * s),
                          fill: theme.panel.withAlphaComponent(theme.panel.alphaComponent * a),
                          stroke: theme.accent.withAlphaComponent(0.6 * a), padding: 3.5 * s)
            }
        }
    }

    private func drawStartFinish(_ ctx: CGContext, course: Course, proj: Projector, D: Double, scale s: CGFloat) {
        let ends: [(String, SIMD3<Double>)] = [("START", points[0]), ("FINISH", points[points.count - 1])]
        for (i, end) in ends.enumerated() {
            let lift = SIMD3(0, 0, D * 0.05)
            guard let (base, z) = proj.project(end.1), let (top, _) = proj.project(end.1 + lift) else { continue }
            let a = max(0.25, depthAlpha(z, D: D * 2))
            ctx.setStrokeColor(theme.text.withAlphaComponent(0.8 * a).cgColor)
            ctx.setLineWidth(1.5 * s)
            ctx.move(to: base)
            ctx.addLine(to: top)
            ctx.strokePath()
            let label = Draw.text(end.0, size: 13 * s, weight: .heavy, color: (i == 0 ? theme.text : NSColor.black).withAlphaComponent(a),
                                  tracking: 1.5 * s)
            Draw.pill(ctx, label, above: top,
                      fill: (i == 0 ? theme.panel : theme.accent).withAlphaComponent(i == 0 ? 0.8 * a : a),
                      stroke: theme.text.withAlphaComponent(0.7 * a), padding: 4 * s)
        }
    }

    /// Gold star labels standing at landmarks coming up along the route.
    private func drawLandmarks(_ ctx: CGContext, course: Course, proj: Projector, D: Double, scale s: CGFloat,
                               currentKm: Double) {
        let ahead = engine?.config.units.kmPerUnit ?? 1
        for l in LandmarkStore.shared.landmarks(for: course) where l.km > currentKm - 0.5 && l.km < currentKm + 5 * ahead {
            let routeZ = point3(course, km: l.km).z
            let at = course.local(lat: l.lat, lon: l.lon)
            let ground = SIMD3(at.x, at.y, routeZ)
            guard let (base, z) = proj.project(ground), let (top, _) = proj.project(ground + SIMD3(0, 0, D * 0.11)) else { continue }
            var a = depthAlpha(z, D: D * 1.5)
            if l.km < currentKm { a *= CGFloat(max(0, 1 - (currentKm - l.km) / 0.5)) }
            guard a > 0.03 else { continue }
            ctx.setStrokeColor(Theme.landmark.withAlphaComponent(0.85 * a).cgColor)
            ctx.setLineWidth(1.6 * s)
            ctx.move(to: base)
            ctx.addLine(to: top)
            ctx.strokePath()
            ctx.setFillColor(Theme.landmark.withAlphaComponent(a).cgColor)
            ctx.fillEllipse(in: CGRect(x: base.x - 2.5 * s, y: base.y - 1.5 * s, width: 5 * s, height: 3 * s))
            let label = NSMutableAttributedString(attributedString: Draw.text("★ ", size: 12 * s, weight: .bold,
                                                                              color: Theme.landmark.withAlphaComponent(a)))
            label.append(Draw.text(l.name, size: 13 * s, weight: .semibold, color: NSColor.white.withAlphaComponent(a)))
            Draw.pill(ctx, label, above: top, fill: NSColor.black.withAlphaComponent(0.62 * a),
                      stroke: Theme.landmark.withAlphaComponent(0.7 * a), padding: 4.5 * s)
        }
    }

    private func drawStations(_ ctx: CGContext, course: Course, proj: Projector, D: Double, scale s: CGFloat,
                              currentKm: Double, config: Config) {
        let stations = course.data.stations.filter { ($0.fluid && config.showFluid) || ($0.fuel && config.showFuel) }
        let nextIndex = stations.firstIndex { $0.km >= currentKm }
        let units = config.units
        // Draw far-to-near so nearer pins overlap farther ones.
        let drawable: [(Int, Station, CGPoint, CGPoint, Double)] = stations.enumerated().compactMap { i, st in
            let base3 = point3(course, km: st.km)
            let top3 = base3 + SIMD3(0, 0, D * 0.075)
            guard let (base, z) = proj.project(base3), let (top, _) = proj.project(top3) else { return nil }
            return (i, st, base, top, z)
        }.sorted { $0.4 > $1.4 }

        for (i, st, base, top, z) in drawable {
            let passed = st.km < currentKm - 0.02
            var a = depthAlpha(z, D: D) * (passed ? 0.4 : 1)
            if i == nextIndex { a = max(a, 0.9) }
            guard a > 0.03 else { continue }
            let color = st.fluid ? theme.fluid : theme.fuel
            ctx.setStrokeColor(color.withAlphaComponent(0.9 * a).cgColor)
            ctx.setLineWidth(2 * s)
            ctx.move(to: base)
            ctx.addLine(to: top)
            ctx.strokePath()
            ctx.setFillColor(color.withAlphaComponent(0.8 * a).cgColor)
            ctx.fillEllipse(in: CGRect(x: base.x - 3 * s, y: base.y - 1.5 * s, width: 6 * s, height: 3 * s))
            let perspective = CGFloat(min(1.5, max(0.65, D / z * 1.2)))
            let radius = 11 * s * perspective
            Draw.stationBadge(ctx, center: CGPoint(x: top.x, y: top.y - radius), radius: radius, station: st,
                              theme: theme, alpha: a)

            let upcoming = i == nextIndex || (!passed && st.km - currentKm < (units == .km ? 1.2 : 1.6))
            if upcoming {
                let dist = max(0, st.km - currentKm)
                let label = NSMutableAttributedString(attributedString: Draw.text(
                    st.label, size: 13 * s, weight: .semibold, color: theme.text.withAlphaComponent(a)))
                label.append(Draw.text("  " + units.formatAhead(km: dist), size: 13 * s, weight: .regular,
                                       color: theme.textSecondary.withAlphaComponent(a), mono: true))
                let anchor = CGPoint(x: top.x + radius + 8 * s, y: top.y - radius - label.size().height / 2)
                let bg = CGRect(x: anchor.x - 6 * s, y: anchor.y - 3 * s,
                                width: label.size().width + 12 * s, height: label.size().height + 6 * s)
                Draw.roundedRect(ctx, bg, radius: 6 * s, fill: theme.panel.withAlphaComponent(theme.panel.alphaComponent * a))
                label.draw(at: anchor)
            }
        }
    }

    /// A circle lying flat on the ground (horizontal plane at `c.z`), projected.
    private func groundCircle(_ proj: Projector, center c: SIMD3<Double>, radius r: Double, segments: Int = 48) -> CGPath? {
        var pts: [CGPoint] = []
        pts.reserveCapacity(segments)
        for i in 0..<segments {
            let a = Double(i) / Double(segments) * 2 * .pi
            guard let (pt, _) = proj.project(c + SIMD3(cos(a) * r, sin(a) * r, 0)) else { return nil }
            pts.append(pt)
        }
        let path = CGMutablePath()
        path.addLines(between: pts)
        path.closeSubpath()
        return path
    }

    /// The runner as a puck lying on the ground: contact shadow, a darker base
    /// peeking out under a white top (so it reads as having thickness), the
    /// coloured centre, and a pulse ring spreading across the ground. All of it
    /// is projected, so it foreshortens with the camera like the route does.
    private func drawRunner(_ ctx: CGContext, at p: SIMD3<Double>, proj: Projector, D: Double, scale s: CGFloat,
                            time: Double) {
        guard proj.project(p) != nil else { return }
        // Size it so the puck is ~15 points in radius at the look-at distance.
        let r = Double(19 * s) * D / proj.focal
        let thickness = r * 0.32
        let top = p + SIMD3(0, 0, thickness)

        // Bursts when passing a station, a distance marker or halfway.
        if let engine {
            for burst in engine.bursts {
                let t = (engine.time - burst.start) / FlyoverEngine.burstDuration
                guard t >= 0, t < 1 else { continue }
                for (i, color) in theme.color(for: burst.kind).enumerated() {
                    let tt = max(0, t - Double(i) * 0.12)
                    let ease = 1 - pow(1 - tt, 3)
                    guard let ring = groundCircle(proj, center: p, radius: r * (1.2 + 7 * ease)) else { continue }
                    ctx.addPath(ring)
                    ctx.setFillColor(color.withAlphaComponent(0.16 * CGFloat(1 - tt)).cgColor)
                    ctx.fillPath()
                    ctx.addPath(ring)
                    ctx.setStrokeColor(color.withAlphaComponent(0.9 * CGFloat(pow(1 - tt, 1.4))).cgColor)
                    ctx.setLineWidth(CGFloat(4.5 * (1 - tt) + 1) * s)
                    ctx.strokePath()
                }
            }
        }
        let pulse = (time * 0.9).truncatingRemainder(dividingBy: 1)
        if let ring = groundCircle(proj, center: p, radius: r * (1.25 + 2.2 * pulse)) {
            ctx.addPath(ring)
            ctx.setStrokeColor(theme.runner.withAlphaComponent(0.7 * CGFloat(1 - pulse)).cgColor)
            ctx.setLineWidth(2.5 * s)
            ctx.strokePath()
        }
        if let shadow = groundCircle(proj, center: p, radius: r * 1.18) {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 10 * s, color: NSColor.black.withAlphaComponent(0.7).cgColor)
            ctx.addPath(shadow)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        guard let base = groundCircle(proj, center: p, radius: r),
              let rim = groundCircle(proj, center: top, radius: r),
              let centre = groundCircle(proj, center: top, radius: r * 0.64) else { return }
        ctx.addPath(base)
        ctx.setFillColor(NSColor(white: 0.72, alpha: 1).cgColor)
        ctx.fillPath()
        ctx.addPath(rim)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.addPath(centre)
        ctx.setFillColor(theme.runner.cgColor)
        ctx.fillPath()
    }

}
