import AppKit
import MapKit
import os

private final class StationAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let station: Station
    init(_ station: Station, at coordinate: CLLocationCoordinate2D) {
        self.station = station
        self.coordinate = coordinate
    }
}

private final class LandmarkAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let name: String
    init(_ l: Landmark) {
        name = l.name
        coordinate = CLLocationCoordinate2D(latitude: l.lat, longitude: l.lon)
    }
}

private final class MarkerAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let text: String
    let highlight: Bool
    init(_ text: String, at coordinate: CLLocationCoordinate2D, highlight: Bool = false) {
        self.text = text
        self.coordinate = coordinate
        self.highlight = highlight
    }
}

/// Live Apple Maps flyover with realistic 3D terrain and buildings.
///
/// Inside the screensaver host (legacyScreenSaver) MapKit's Metal surface can
/// end up with no drawable size, leaving a grey map. This view re-applies the
/// surface size and scale every frame, logs what it sees to the unified log
/// (subsystem com.raceflyover, category map) for diagnosis, and reports
/// `onFailure` if the map still can't draw so the saver can fall back to flat
/// Apple Maps imagery.
final class MapFlyoverView: NSView, MKMapViewDelegate {
    weak var engine: FlyoverEngine?
    var onFailure: (() -> Void)?

    static let log = Logger(subsystem: "com.raceflyover", category: "map")
    private let map = MKMapView()
    /// The runner's pin, drawn in our own layer above the map and positioned
    /// from the camera each frame. (A MapKit annotation is repositioned on
    /// MapKit's own schedule, so at speed it jitters against the moving map.)
    private let pinLayer = CALayer()
    /// The route is drawn inside the map by `RouteRenderer`, so buildings hide
    /// it like the road. These faint dotted "x-ray" lines on top keep the parts
    /// a building hides (or a GPS point inside a building) traceable; where
    /// the route is visible they blend into it.
    private let ghostDone = CAShapeLayer()
    private let ghostAhead = CAShapeLayer()
    private var routeRenderer: RouteRenderer?
    private var routeOverlay: RouteOverlay?
    private var lastCoveredUpdate = 0.0
    private var pinColor: NSColor?
    private var appliedStyle: String?
    private var builtKey = ""
    private var theme = Theme.forStyle(.satellite)
    private let createdAt = CACurrentMediaTime()
    private var lastDiagnostic = 0.0
    private var loaded = false
    private var healCount = 0
    private var zeroDrawableFrames = 0
    private var isShutDown = false
    private var failed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        map.frame = bounds
        map.autoresizingMask = [.width, .height]
        map.delegate = self
        map.isZoomEnabled = false
        map.isScrollEnabled = false
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsCompass = false
        map.showsZoomControls = false
        map.showsScale = false
        map.showsUserLocation = false
        addSubview(map)
        for (l, z) in [(ghostAhead, 5.0), (ghostDone, 6.0)] {
            l.zPosition = CGFloat(z)
            l.fillColor = nil
            l.lineCap = .round
            l.lineJoin = .round
            l.actions = ["path": NSNull(), "lineWidth": NSNull(), "strokeColor": NSNull(), "hidden": NSNull(),
                         "lineDashPattern": NSNull()]
            layer?.addSublayer(l)
        }
        pinLayer.zPosition = 10
        pinLayer.actions = ["position": NSNull(), "contents": NSNull(), "hidden": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(pinLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func apply(_ config: Config) {
        let style = config.style
        let key = "\(style)|\(config.map3D)|\(config.pinColor)|\(config.trailColor)"
        guard key != appliedStyle else { return }
        appliedStyle = key
        theme = Theme.forStyle(style).with(pin: config.pinColor, trail: config.trailColor)
        // By default the pin matches the trail it leaves (blue on Apple Maps).
        if config.pinColor == .auto { theme.runner = config.trailColor.color ?? Theme.hex(0x0A84FF) }
        // Realistic elevation (3D terrain and buildings) is MapKit's heaviest mode.
        let elevation: MKMapConfiguration.ElevationStyle = config.map3D ? .realistic : .flat
        switch style {
        case .satellitePlain:
            map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: elevation)
        case .satellite:
            let c = MKHybridMapConfiguration(elevationStyle: elevation)
            c.pointOfInterestFilter = .excludingAll
            map.preferredConfiguration = c
        default:
            let c = MKStandardMapConfiguration(elevationStyle: elevation, emphasisStyle: .muted)
            c.pointOfInterestFilter = .excludingAll
            map.preferredConfiguration = c
        }
        map.appearance = NSAppearance(named: style == .mapLight ? .aqua : .darkAqua)
        builtKey = ""
    }

    /// Stops MapKit work and drops its resources. MapKit views left alive in the
    /// screensaver host pile up GPU resources until the map stops drawing.
    func shutDown() {
        isShutDown = true
        MapVisibility.release(window)
        map.delegate = nil
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)
        map.removeFromSuperview()
        engine = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { MapVisibility.release(window) }
    }

    func render() {
        guard !isShutDown, let engine else { return }
        if let window { MapVisibility.forceVisible(window) }
        let config = engine.config
        apply(config)
        let course = engine.course
        let landmarks = config.showLandmarks ? LandmarkStore.shared.landmarks(for: course) : []
        let key = "\(course.id)|\(config.showFluid)|\(config.showFuel)|\(config.showMarkers)|\(config.units)|\(config.typeface)|\(appliedStyle ?? "")|\(landmarks.count)"
        if key != builtKey { rebuild(course, config: config, key: key) }
        let cam = engine.camera
        let camera = MKMapCamera(lookingAtCenter: cam.coordinate, fromDistance: cam.distance,
                                 pitch: CGFloat(cam.tilt * 180 / .pi), heading: cam.heading * 180 / .pi)
        map.setCamera(camera, animated: false)
        let projection = makeProjection(course: course, distance: engine.distance)
        updateRouteWidth(cameraDistance: engine.camera.distance, config: config, projection: projection)
        FrameStats.shared.measure("trail") {
            updateCovered(distance: engine.distance)
            drawGhost(course: course, distance: engine.distance, projection: projection)
        }
        placePin(course: course, distance: engine.distance, projection: projection)

        healSurface()
        diagnose()
    }

    /// Puck parts: contact shadow, darker base, white top with coloured centre.
    private let pinShadow = CALayer()
    private let pinBase = CALayer()
    private let pinTop = CALayer()
    private let pinArrow = CAShapeLayer()
    private var pinKey = ""

    private var pinRadius: CGFloat { 15 * (engine?.config.pinSize.scale ?? 2) }

    private func buildPin() {
        let r = pinRadius
        let scale = window?.backingScaleFactor ?? 2
        func disc(_ size: CGFloat, _ draw: @escaping (CGContext, CGRect) -> Void) -> CGImage? {
            let image = Self.image(size: size, draw)
            var rect = CGRect(x: 0, y: 0, width: size, height: size)
            return image.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform(scale: scale)])
        }
        let runner = theme.runner
        let glass = engine?.config.pinStyle.usesGlass ?? false
        let shadowSize = r * 4
        pinShadow.contents = disc(shadowSize) { ctx, rect in
            Draw.radialGlow(ctx, center: CGPoint(x: rect.midX, y: rect.midY), radius: r * 1.9,
                            color: NSColor.black.withAlphaComponent(glass ? 0.32 : 0.6))
        }
        // Solid: a grey base under a white top with a coloured centre. Glass: a
        // see-through edge and face with a see-through coloured centre.
        let light = theme.isLight
        pinBase.contents = disc(r * 2) { ctx, rect in
            let inner = rect.insetBy(dx: 1, dy: 1)
            if glass {
                Draw.glassEdge(ctx, CGPath(ellipseIn: inner, transform: nil), light: light, lineScale: 1.4)
            } else {
                ctx.setFillColor(NSColor(white: 0.72, alpha: 1).cgColor)
                ctx.fillEllipse(in: rect)
            }
        }
        pinTop.contents = disc(r * 2) { ctx, rect in
            if glass {
                let inner = rect.insetBy(dx: 1, dy: 1)
                Draw.glassFace(ctx, rim: CGPath(ellipseIn: inner, transform: nil),
                               centre: CGPath(ellipseIn: rect.insetBy(dx: r * 0.38, dy: r * 0.38), transform: nil),
                               color: runner, light: light, lineScale: 1.4)
            } else {
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fillEllipse(in: rect)
                ctx.setFillColor(runner.cgColor)
                ctx.fillEllipse(in: rect.insetBy(dx: r * 0.36, dy: r * 0.36))
            }
        }
        // Direction arrow on the puck's face (rotated with the heading each frame).
        let a = r * 0.5
        let arrowPath = CGMutablePath()
        arrowPath.move(to: CGPoint(x: 0, y: a))
        arrowPath.addLine(to: CGPoint(x: a * 0.72, y: -a * 0.64))
        arrowPath.addLine(to: CGPoint(x: 0, y: -a * 0.24))
        arrowPath.addLine(to: CGPoint(x: -a * 0.72, y: -a * 0.64))
        arrowPath.closeSubpath()
        pinArrow.path = arrowPath
        pinArrow.fillColor = NSColor.white.cgColor
        pinArrow.shadowColor = NSColor.black.cgColor
        pinArrow.shadowOpacity = 0.45
        pinArrow.shadowRadius = 2
        pinArrow.shadowOffset = .zero
        pinArrow.shadowPath = arrowPath
        pinArrow.zPosition = 3
        pinArrow.bounds = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
        pinArrow.actions = ["position": NSNull(), "transform": NSNull()]
        if pinArrow.superlayer == nil { pinLayer.addSublayer(pinArrow) }
        for (layer, size) in [(pinShadow, shadowSize), (pinBase, r * 2), (pinTop, r * 2)] {
            layer.contentsScale = scale
            layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            layer.actions = ["position": NSNull(), "transform": NSNull(), "contents": NSNull()]
            if layer.superlayer == nil { pinLayer.addSublayer(layer) }
        }
        pinLayer.contents = nil
        pinLayer.bounds = CGRect(x: 0, y: 0, width: shadowSize, height: shadowSize)
    }

    private var lastBurstStart = -1.0

    /// Spawns an expanding, fading ring under the puck for each new burst.
    private func spawnBursts(squash: CGFloat) {
        guard let engine else { return }
        for burst in engine.bursts where burst.start > lastBurstStart {
            lastBurstStart = burst.start
            for (i, color) in theme.color(for: burst.kind).enumerated() {
                let ring = CAShapeLayer()
                let r: CGFloat = 16
                ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
                ring.fillColor = color.withAlphaComponent(0.15).cgColor
                ring.strokeColor = color.cgColor
                ring.lineWidth = 3
                ring.position = CGPoint(x: pinLayer.bounds.midX, y: pinLayer.bounds.midY)
                ring.opacity = 0
                pinLayer.insertSublayer(ring, below: pinShadow)
                let start = CATransform3DMakeScale(1.1, 1.1 * squash, 1)
                let end = CATransform3DMakeScale(7, 7 * squash, 1)
                let grow = CABasicAnimation(keyPath: "transform")
                grow.fromValue = NSValue(caTransform3D: start)
                grow.toValue = NSValue(caTransform3D: end)
                grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.95
                fade.toValue = 0
                let group = CAAnimationGroup()
                group.animations = [grow, fade]
                group.duration = FlyoverEngine.burstDuration
                group.beginTime = CACurrentMediaTime() + Double(i) * 0.18
                group.fillMode = .backwards
                ring.transform = end
                ring.add(group, forKey: "burst")
                DispatchQueue.main.asyncAfter(deadline: .now() + FlyoverEngine.burstDuration + 0.4) { ring.removeFromSuperlayer() }
            }
        }
    }

    private func placePin(course: Course, distance: Double, projection: FrameProjection?) {
        let config = engine?.config
        let key = "\(theme.runner)|\(config?.pinSize.rawValue ?? "")|\(config?.pinStyle.usesGlass ?? false)|\(theme.isLight)"
        if pinKey != key {
            pinKey = key
            pinColor = theme.runner
            buildPin()
        }
        // Matched to the map as it's shown, so the pin lands exactly on the route.
        let p = projection?.pin ?? map.convert(course.sample(at: distance).coordinate, toPointTo: self)
        let onScreen = p.x.isFinite && p.y.isFinite && bounds.insetBy(dx: -60, dy: -60).contains(p)
        // Lie flat on the ground: foreshorten by the map's actual pitch (MapKit may
        // cap it), and lift the white top above the base to show its thickness.
        let pitch = map.camera.pitch * .pi / 180
        let squash = CGFloat(max(0.12, cos(pitch)))
        let lift = 5 * CGFloat(sin(pitch))
        let flatten = CATransform3DMakeScale(1, squash, 1)
        let mid = CGPoint(x: pinLayer.bounds.midX, y: pinLayer.bounds.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pinLayer.isHidden = !onScreen
        if onScreen { pinLayer.position = CGPoint(x: p.x.rounded(), y: p.y.rounded()) }
        for layer in [pinShadow, pinBase, pinTop] { layer.transform = flatten }
        // The arrow lies on the puck: turn it to the road's direction right here
        // (relative to the map's actual heading), then flatten with the tilt.
        let heading = course.travelHeading(at: distance) - map.camera.heading * .pi / 180
        pinArrow.transform = CATransform3DConcat(CATransform3DMakeRotation(CGFloat(-heading), 0, 0, 1), flatten)
        pinArrow.position = CGPoint(x: mid.x, y: mid.y + lift)
        spawnBursts(squash: squash)
        pinShadow.position = mid
        pinBase.position = mid
        pinTop.position = CGPoint(x: mid.x, y: mid.y + lift)   // unflipped: +y is up
        CATransaction.commit()
    }

    // MARK: - Surface repair and diagnostics

    /// MapKit's Metal surfaces anywhere under the map view (VectorKit moves
    /// them around as it reconfigures).
    private var metalLayers: [CAMetalLayer] {
        func find(_ l: CALayer, depth: Int) -> [CAMetalLayer] {
            guard depth < 12 else { return [] }
            return ((l as? CAMetalLayer).map { [$0] } ?? []) + (l.sublayers ?? []).flatMap { find($0, depth: depth + 1) }
        }
        return map.layer.map { find($0, depth: 0) } ?? []
    }

    private var backingScale: CGFloat {
        let s = window?.backingScaleFactor ?? 0
        return s > 0 ? s : (NSScreen.main?.backingScaleFactor ?? 2)
    }

    /// Gives MapKit's Metal layer a real size and scale if the host left them zeroed.
    private func healSurface() {
        let scale = backingScale
        var collapsed = false
        for layer in metalLayers {
            let b = layer.bounds.size
            guard b.width > 1, b.height > 1 else { continue }
            let want = CGSize(width: (b.width * scale).rounded(), height: (b.height * scale).rounded())
            if layer.contentsScale != scale { layer.contentsScale = scale }
            let have = layer.drawableSize
            if have.width < 1 || have.height < 1 {
                collapsed = true
                layer.drawableSize = want
                healCount += 1
            } else if abs(have.width - want.width) > 2 || abs(have.height - want.height) > 2 {
                layer.drawableSize = want
                healCount += 1
            }
        }
        // Count frames in a row: MapKit briefly rebuilds its surface while the
        // camera swoops, which is harmless; a surface that stays collapsed isn't.
        zeroDrawableFrames = collapsed ? zeroDrawableFrames + 1 : 0
        // If the surface stays collapsed (~3 s), or MapKit never loads, give up on the live map.
        let age = CACurrentMediaTime() - createdAt
        if !failed && ((zeroDrawableFrames > 90 && age > 6) || (!loaded && age > 15)) {
            failed = true
            Self.log.error("live map unusable (zeroDrawableFrames=\(self.zeroDrawableFrames, privacy: .public), loaded=\(self.loaded, privacy: .public)); falling back")
            onFailure?()
        }
    }

    private func diagnose() {
        let age = CACurrentMediaTime() - createdAt
        guard age < 30, age - lastDiagnostic >= 2 else { return }
        lastDiagnostic = age
        let w = window
        let occluded = w.map { !$0.occlusionState.contains(.visible) } ?? true
        let metal = metalLayers.map {
            "drawable=\(Int($0.drawableSize.width))x\(Int($0.drawableSize.height)) scale=\($0.contentsScale) bounds=\(Int($0.bounds.width))x\(Int($0.bounds.height)) hidden=\($0.isHidden)"
        }.joined(separator: "; ")
        let line = "t=\(Int(age))s window=\(w.map { String(describing: type(of: $0)) } ?? "nil") "
            + "visible=\(w?.isVisible ?? false) occluded=\(occluded) backing=\(w?.backingScaleFactor ?? 0) "
            + "screen=\(w?.screen != nil) view=\(Int(bounds.width))x\(Int(bounds.height)) "
            + "loaded=\(loaded) heals=\(healCount) zeroFrames=\(zeroDrawableFrames) metal=[\(metal)] "
            + "pin=\(Int(pinLayer.position.x)),\(Int(pinLayer.position.y)) centre=\(Int(bounds.midX)),\(Int(bounds.midY)) pinHidden=\(pinLayer.isHidden)"
        Self.log.notice("\(line, privacy: .public)")
    }

    // MARK: - Overlays

    private func rebuild(_ course: Course, config: Config, key: String) {
        builtKey = key
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)

        let coords = course.lat.indices.map { CLLocationCoordinate2D(latitude: course.lat[$0], longitude: course.lon[$0]) }
        let route = RouteOverlay(course: course)
        routeOverlay = route
        routeRenderer = nil
        lastCoveredUpdate = 0
        map.addOverlay(route, level: .aboveRoads)
        ghostDone.strokeColor = trailTint.withAlphaComponent(0.4).cgColor
        ghostAhead.strokeColor = aheadTint.withAlphaComponent(0.3).cgColor

        var annotations: [MKAnnotation] = []
        for st in course.data.stations where (st.fluid && config.showFluid) || (st.fuel && config.showFuel) {
            annotations.append(StationAnnotation(st, at: course.sample(at: course.along(officialKm: st.km)).coordinate))
        }
        if config.showMarkers {
            let unit = config.units.kmPerUnit
            var k = 5
            while Double(k) * unit < course.data.distanceKm - 0.3 {
                let text = config.units == .km ? "\(k)K" : "MI \(k)"
                annotations.append(MarkerAnnotation(text, at: course.sample(at: course.along(officialKm: Double(k) * unit)).coordinate))
                k += 5
            }
            if course.data.distanceKm > 40 {
                annotations.append(MarkerAnnotation("HALF", at: course.sample(at: course.length / 2).coordinate, highlight: true))
            }
        }
        if config.showLandmarks {
            annotations += LandmarkStore.shared.landmarks(for: course).map(LandmarkAnnotation.init)
        }
        annotations.append(MarkerAnnotation("START", at: coords[0]))
        annotations.append(MarkerAnnotation("FINISH", at: coords[coords.count - 1], highlight: true))
        map.addAnnotations(annotations)
    }

    private var routeWidth: CGFloat = 1

    /// Thicker route when zoomed in (and per the option); only re-renders when it
    /// changes noticeably, e.g. during the intro swoop, not every frame.
    /// Metres on the ground per screen point at the runner, for the route's width.
    private var metresPerPoint = 1.0
    private var appliedWidth = 0.0

    /// The route inside the map has a width in metres, like a painted road:
    /// MapKit draws it in tiles at several levels of detail (nearer tiles finer
    /// when tilted), and a width in screen points came out a different
    /// thickness on each, with steps and breaks where tiles met. A width on the
    /// ground is the same in every tile, and narrows smoothly into the
    /// distance. It's chosen to look the set thickness at the runner, and
    /// only re-applied when the zoom changes noticeably (redrawing every tile).
    private func updateRouteWidth(cameraDistance: Double, config: Config, projection: FrameProjection?) {
        routeWidth = PathWidth.zoomFactor(cameraDistance: cameraDistance) * config.pathWidth.scale
        if let proj = projection, let a = proj.ground.apply(0, 0) {
            let h = map.camera.heading * .pi / 180
            // Across the view (no foreshortening): 10 m to the side of the runner.
            if let b = proj.ground.apply(cos(h) * 10, -sin(h) * 10) {
                let points = hypot(b.x - a.x, b.y - a.y)
                if points > 0.5 { metresPerPoint = 10 / Double(points) }
            }
        }
        let width = Double(routeWidth) * metresPerPoint
        guard appliedWidth == 0 || abs(width - appliedWidth) / appliedWidth > 0.12 else { return }
        appliedWidth = width
        if let r = routeRenderer {
            applyWidths(r)
            r.setNeedsDisplay()
        }
    }

    private func applyWidths(_ r: RouteRenderer) {
        let w = CGFloat(appliedWidth > 0 ? appliedWidth : Double(routeWidth) * metresPerPoint)
        r.aheadWidth = Self.aheadWidth * w
        r.coreWidth = Self.coreWidth * w
        r.casingWidth = Self.casingWidth * w
    }

    /// Moves the end of the covered route to the runner, about ten times a
    /// second (the pin hides the few metres in between).
    private func updateCovered(distance: Double) {
        guard let route = routeOverlay, let r = routeRenderer else { return }
        let now = CACurrentMediaTime()
        guard now - lastCoveredUpdate >= 0.1 else { return }
        lastCoveredUpdate = now
        // Widest line (metres → map points), with room to spare.
        r.setCovered(route.mapLength(atTraced: distance), padding: Double(r.casingWidth) * r.mapPointsPerMetre * 2)
    }

    private static let aheadWidth: CGFloat = 8
    private static let coreWidth: CGFloat = 7.5
    private static let casingWidth: CGFloat = 10.5

    /// The trail colour (blue by default on Apple Maps).
    private var trailTint: NSColor {
        engine?.config.trailColor.color ?? Theme.hex(0x0A84FF)
    }

    /// The route still to run: a lighter, see-through shade of the trail colour.
    private var aheadTint: NSColor {
        (trailTint.blended(withFraction: 0.45, of: .white) ?? trailTint).withAlphaComponent(0.55)
    }

    /// The x-ray lines: the route near the camera, projected onto the screen
    /// through a plane-to-screen transform fitted to four points MapKit projects
    /// around the runner (exact for flat ground, and far cheaper than asking
    /// MapKit for every point).
    /// Where things go on screen this frame, matched to the map you actually
    /// see. MapKit shows a new camera about one screen refresh (~25 ms) after
    /// it's set, while our layers show their positions at once; with the
    /// camera moving, the map then lags the pin, so the road and the route
    /// look ahead of it and, on bends, off to one side. So positions are taken
    /// that same refresh earlier: blended between this frame and the last.
    private struct FrameProjection {
        let here: CourseSample
        /// Ground (metres from the runner) to screen, as the map is shown.
        let ground: Homography
        /// The runner's spot, as the map is shown.
        let pin: CGPoint
    }

    /// How late MapKit shows a camera change, in seconds (measured: a little more than a 60 Hz refresh).
    private static let mapLatency = 0.025
    private var previous: (ground: Homography, pin: CGPoint, time: Double, origin: SIMD2<Double>)?

    private func makeProjection(course: Course, distance: Double) -> FrameProjection? {
        let here = course.sample(at: distance)
        let reach = max(60, map.camera.centerCoordinateDistance * 0.2)
        let h = map.camera.heading * .pi / 180
        let f = (sin(h), cos(h)), side = (cos(h), -sin(h))
        let refs = [(f.0 * reach, f.1 * reach), (-f.0 * reach * 0.5, -f.1 * reach * 0.5),
                    (side.0 * reach, side.1 * reach), (-side.0 * reach, -side.1 * reach)]
        let screen = refs.map { r -> CGPoint in
            let c = course.coordinate(x: here.x + r.0, y: here.y + r.1)
            return map.convert(CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon), toPointTo: self)
        }
        let pinNow = map.convert(here.coordinate, toPointTo: self)
        guard screen.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), pinNow.x.isFinite, pinNow.y.isFinite,
              let now = Homography(from: refs, to: screen.map { (Double($0.x), Double($0.y)) }) else {
            previous = nil
            return nil
        }
        let time = CACurrentMediaTime()
        let origin = SIMD2(here.x, here.y)
        defer { previous = (now, pinNow, time, origin) }
        guard let prev = previous, time > prev.time, time - prev.time < 0.25 else {
            return FrameProjection(here: here, ground: now, pin: pinNow)
        }
        // Blend towards the last frame by the share of a frame MapKit is behind.
        let lag = min(1, Self.mapLatency / (time - prev.time))
        // The last frame's mapping, re-based on this frame's runner position.
        let shift = origin - prev.origin
        let prevHere = prev.ground.shifted(by: shift.x, shift.y)
        let pin = CGPoint(x: pinNow.x + (prev.pin.x - pinNow.x) * lag, y: pinNow.y + (prev.pin.y - pinNow.y) * lag)
        return FrameProjection(here: here, ground: now.blended(with: prevHere, by: lag), pin: pin)
    }

    private func drawGhost(course: Course, distance: Double, projection: FrameProjection?) {
        guard let proj = projection else {
            ghostDone.path = nil
            ghostAhead.path = nil
            return
        }
        let here = proj.here
        // Only near the runner, where buildings get in the way and flat ground is
        // a close enough guess; further out the line would drift off the road.
        let radius = max(400, map.camera.centerCoordinateDistance * 1.5)
        let (index, _) = course.locate(distance)
        let pin = proj.pin
        func build(_ range: StrideThrough<Int>, endAtPin: Bool, startAtPin: Bool) -> CGPath {
            let path = CGMutablePath()
            var drawing = false
            if startAtPin { path.move(to: pin); drawing = true }
            for i in range {
                let dx = course.x[i] - here.x, dy = course.y[i] - here.y
                guard dx * dx + dy * dy < radius * radius, let p = proj.ground.apply(dx, dy) else { drawing = false; continue }
                if drawing { path.addLine(to: p) } else { path.move(to: p); drawing = true }
            }
            if endAtPin && drawing { path.addLine(to: pin) }
            return path
        }
        let done = build(stride(from: 0, through: index, by: 1), endAtPin: true, startAtPin: false)
        let ahead = build(stride(from: index + 1, through: course.x.count - 1, by: 1), endAtPin: false, startAtPin: true)
        let w = routeWidth
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (l, path) in [(ghostDone, done), (ghostAhead, ahead)] {
            l.lineWidth = 2.2 * w
            l.lineDashPattern = [0, NSNumber(value: Double(7 * w))]   // round dots
            l.path = path
        }
        CATransaction.commit()
    }

    // MARK: - MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let route = overlay as? RouteOverlay else { return MKOverlayRenderer(overlay: overlay) }
        let r = RouteRenderer(route: route)
        r.aheadColor = aheadTint
        r.doneColor = trailTint
        applyWidths(r)
        if let engine { r.setCovered(route.mapLength(atTraced: engine.distance), padding: 0) }
        routeRenderer = r
        return r
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        let view = MKAnnotationView(annotation: annotation, reuseIdentifier: nil)
        view.collisionMode = .none
        view.displayPriority = .required
        let theme = self.theme
        switch annotation {
        case let st as StationAnnotation:
            view.image = Self.image(size: 30) { ctx, r in
                Draw.stationBadge(ctx, center: CGPoint(x: r.midX, y: r.midY), radius: 12, station: st.station,
                                  theme: theme, alpha: 1)
            }
            view.zPriority = .defaultSelected
        case let l as LandmarkAnnotation:
            let label = NSMutableAttributedString(attributedString: Draw.text("★ ", size: 12, weight: .bold, color: Theme.landmark))
            label.append(Draw.text(l.name, size: 12.5, weight: .semibold, color: .white))
            let ts = label.size()
            let w = ceil(ts.width + 18), h = ceil(ts.height + 8)
            view.image = NSImage(size: NSSize(width: w, height: h), flipped: true) { rect in
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                Draw.roundedRect(ctx, rect.insetBy(dx: 0.5, dy: 0.5), radius: h / 2,
                                 fill: NSColor.black.withAlphaComponent(0.7), stroke: Theme.landmark.withAlphaComponent(0.85))
                label.draw(at: CGPoint(x: 9, y: 4))
                return true
            }
            view.centerOffset = CGPoint(x: 0, y: -h)
            view.zPriority = .defaultSelected
        case let m as MarkerAnnotation:
            let text = Draw.text(m.text, size: 11, weight: .heavy, color: m.highlight ? .black : .white, tracking: 1)
            let ts = text.size()
            let w = ceil(ts.width + 16), h = ceil(ts.height + 6)
            view.image = NSImage(size: NSSize(width: w, height: h), flipped: true) { rect in
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                Draw.roundedRect(ctx, rect.insetBy(dx: 0.5, dy: 0.5), radius: h / 2,
                                 fill: m.highlight ? theme.accent : NSColor.black.withAlphaComponent(0.7),
                                 stroke: NSColor.white.withAlphaComponent(0.8))
                text.draw(at: CGPoint(x: 8, y: 3))
                return true
            }
            view.centerOffset = CGPoint(x: 0, y: -h)
        default:
            return nil
        }
        return view
    }

    func mapViewWillStartLoadingMap(_ mapView: MKMapView) {
        Self.log.notice("map will start loading")
    }

    func mapViewDidFinishLoadingMap(_ mapView: MKMapView) {
        loaded = true
        Self.log.notice("map finished loading")
    }

    /// Usually a brief network hiccup while fetching new map data (a lost
    /// connection, a bad server reply): MapKit retries as the camera moves, so
    /// keep the 3D map. A map that never loads at all is caught in `healSurface`.
    func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: Error) {
        Self.log.error("map failed loading (keeping the live map; MapKit retries): \(error.localizedDescription, privacy: .public)")
    }

    func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
        loaded = true
    }

    private static func image(size: CGFloat, _ draw: @escaping (CGContext, CGRect) -> Void) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(ctx, rect)
            return true
        }
    }
}

/// Maps flat ground (metres east and north of a reference point) to the screen.
private struct Homography {
    fileprivate var m: [Double]   // row-major 3×3, m[8] = 1

    /// Fitted to four ground points and where they appear on screen.
    init?(from ground: [(Double, Double)], to screen: [(Double, Double)]) {
        guard ground.count == 4, screen.count == 4 else { return nil }
        var a = [[Double]]()
        for ((x, y), (u, v)) in zip(ground, screen) {
            a.append([x, y, 1, 0, 0, 0, -u * x, -u * y, u])
            a.append([0, 0, 0, x, y, 1, -v * x, -v * y, v])
        }
        // Gaussian elimination with partial pivoting on the 8×9 augmented matrix.
        for col in 0..<8 {
            guard let pivot = (col..<8).max(by: { abs(a[$0][col]) < abs(a[$1][col]) }),
                  abs(a[pivot][col]) > 1e-12 else { return nil }
            a.swapAt(col, pivot)
            for row in 0..<8 where row != col {
                let k = a[row][col] / a[col][col]
                if k != 0 { for c in col..<9 { a[row][c] -= k * a[col][c] } }
            }
        }
        m = (0..<8).map { a[$0][8] / a[$0][$0] } + [1]
    }

    /// The same mapping for points given relative to an origin moved by `(dx, dy)`.
    func shifted(by dx: Double, _ dy: Double) -> Homography {
        var h = self
        // p' = p + d, so H' = H · T(d): the last column picks up H·(dx, dy, 0).
        h.m[2] += m[0] * dx + m[1] * dy
        h.m[5] += m[3] * dx + m[4] * dy
        h.m[8] += m[6] * dx + m[7] * dy
        let n = h.m[8]
        for k in 0..<9 { h.m[k] /= n }
        return h
    }

    /// A mapping part of the way (`t`, 0…1) towards `other`.
    func blended(with other: Homography, by t: Double) -> Homography {
        var h = self
        for k in 0..<9 { h.m[k] = m[k] + (other.m[k] - m[k]) * t }
        let n = h.m[8]
        for k in 0..<9 { h.m[k] /= n }
        return h
    }

    /// Screen point for a ground point, or nil if it's behind the camera.
    func apply(_ x: Double, _ y: Double) -> CGPoint? {
        let w = m[6] * x + m[7] * y + 1
        guard w > 0.02 else { return nil }
        return CGPoint(x: (m[0] * x + m[1] * y + m[2]) / w, y: (m[3] * x + m[4] * y + m[5]) / w)
    }
}
