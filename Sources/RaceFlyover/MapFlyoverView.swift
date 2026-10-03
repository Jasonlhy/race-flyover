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
        placePin(at: course.sample(at: engine.distance).coordinate)

        healSurface()
        diagnose()
    }

    /// Puck parts: contact shadow, darker base, white top with coloured centre.
    private let pinShadow = CALayer()
    private let pinBase = CALayer()
    private let pinTop = CALayer()

    private func buildPin() {
        let r: CGFloat = 15
        let scale = window?.backingScaleFactor ?? 2
        func disc(_ size: CGFloat, _ draw: @escaping (CGContext, CGRect) -> Void) -> CGImage? {
            let image = Self.image(size: size, draw)
            var rect = CGRect(x: 0, y: 0, width: size, height: size)
            return image.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform(scale: scale)])
        }
        let runner = theme.runner
        let shadowSize = r * 4
        pinShadow.contents = disc(shadowSize) { ctx, rect in
            Draw.radialGlow(ctx, center: CGPoint(x: rect.midX, y: rect.midY), radius: r * 1.9,
                            color: NSColor.black.withAlphaComponent(0.6))
        }
        pinBase.contents = disc(r * 2) { ctx, rect in
            ctx.setFillColor(NSColor(white: 0.72, alpha: 1).cgColor)
            ctx.fillEllipse(in: rect)
        }
        pinTop.contents = disc(r * 2) { ctx, rect in
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: rect)
            ctx.setFillColor(runner.cgColor)
            ctx.fillEllipse(in: rect.insetBy(dx: r * 0.36, dy: r * 0.36))
        }
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

    private func placePin(at coordinate: CLLocationCoordinate2D) {
        if pinColor != theme.runner {
            pinColor = theme.runner
            buildPin()
        }
        // Same camera MapKit just received, so the pin lands exactly on the route.
        let p = map.convert(coordinate, toPointTo: self)
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
        for layer in metalLayers {
            let b = layer.bounds.size
            guard b.width > 1, b.height > 1 else { continue }
            let want = CGSize(width: (b.width * scale).rounded(), height: (b.height * scale).rounded())
            if layer.contentsScale != scale { layer.contentsScale = scale }
            let have = layer.drawableSize
            if have.width < 1 || have.height < 1 {
                zeroDrawableFrames += 1
                layer.drawableSize = want
                healCount += 1
            } else if abs(have.width - want.width) > 2 || abs(have.height - want.height) > 2 {
                layer.drawableSize = want
                healCount += 1
            }
        }
        // If the surface keeps collapsing, or MapKit never loads, give up on the live map.
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
        let casing = MKPolyline(coordinates: coords, count: coords.count)
        casing.title = "casing"
        let route = MKPolyline(coordinates: coords, count: coords.count)
        route.title = "route"
        map.addOverlays([casing, route], level: .aboveRoads)

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

    /// The route's border: the chosen trail colour, or blue by default.
    private var trailBorder: NSColor {
        (engine?.config.trailColor.color ?? Theme.hex(0x0A84FF)).withAlphaComponent(0.95)
    }

    // MARK: - MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        let r = MKPolylineRenderer(overlay: overlay)
        r.lineCap = .round
        r.lineJoin = .round
        // A static route (white line with a coloured border) rather than a trail
        // that's rebuilt as the pin moves: MapKit re-tessellates replaced
        // overlays, which flickers. The pin shows progress.
        switch (overlay as? MKPolyline)?.title {
        case "casing":
            r.strokeColor = trailBorder
            r.lineWidth = 11
        default:
            r.strokeColor = NSColor.white.withAlphaComponent(0.95)
            r.lineWidth = 4.5
        }
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

    func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: Error) {
        Self.log.error("map failed loading: \(error.localizedDescription, privacy: .public)")
        if !failed { failed = true; onFailure?() }
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
