import AppKit
import MapKit
import os

private final class RunnerAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate = CLLocationCoordinate2D()
}

private final class StationAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let station: Station
    init(_ station: Station, at coordinate: CLLocationCoordinate2D) {
        self.station = station
        self.coordinate = coordinate
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

    private static let log = Logger(subsystem: "com.raceflyover", category: "map")
    private let map = MKMapView()
    private let runner = RunnerAnnotation()
    private var appliedStyle: String?
    private var builtKey = ""
    private var doneLine: MKPolyline?
    private var doneDistance = -1.0
    private var doneUpdatedAt = 0.0
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
        let key = "\(course.id)|\(config.showFluid)|\(config.showFuel)|\(config.showMarkers)|\(config.units)|\(config.typeface)|\(appliedStyle ?? "")"
        if key != builtKey { rebuild(course, config: config, key: key) }

        let cam = engine.camera
        let camera = MKMapCamera(lookingAtCenter: cam.coordinate, fromDistance: cam.distance,
                                 pitch: CGFloat(cam.tilt * 180 / .pi), heading: cam.heading * 180 / .pi)
        map.setCamera(camera, animated: false)
        runner.coordinate = course.sample(at: engine.distance).coordinate

        // Keep the trail glued to the pin: refresh it every few metres (scaled to
        // the zoom so it's always sub-pixel-ish), at most ~12 times a second.
        let now = CACurrentMediaTime()
        let step = max(4, cam.distance / 300)
        if engine.distance < doneDistance || (engine.distance - doneDistance >= step && now - doneUpdatedAt > 0.08) {
            updateDoneLine(course, at: engine.distance)
            doneUpdatedAt = now
        }

        healSurface()
        diagnose()
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
            + "loaded=\(loaded) heals=\(healCount) zeroFrames=\(zeroDrawableFrames) metal=[\(metal)]"
        Self.log.notice("\(line, privacy: .public)")
    }

    // MARK: - Overlays

    private func rebuild(_ course: Course, config: Config, key: String) {
        builtKey = key
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)
        doneLine = nil
        doneDistance = -1

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
        annotations.append(MarkerAnnotation("START", at: coords[0]))
        annotations.append(MarkerAnnotation("FINISH", at: coords[coords.count - 1], highlight: true))
        map.addAnnotations(annotations)
        map.addAnnotation(runner)
    }

    private func updateDoneLine(_ course: Course, at distance: Double) {
        doneDistance = distance
        let old = doneLine
        let (i, _) = course.locate(distance)
        if distance > 1 {
            var coords = (0...i).map { CLLocationCoordinate2D(latitude: course.lat[$0], longitude: course.lon[$0]) }
            coords.append(course.sample(at: distance).coordinate)
            let line = MKPolyline(coordinates: coords, count: coords.count)
            line.title = "done"
            // Add the new trail before removing the old one so it never flickers.
            map.addOverlay(line, level: .aboveRoads)
            doneLine = line
        } else {
            doneLine = nil
        }
        if let old { map.removeOverlay(old) }
    }

    // MARK: - MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        let r = MKPolylineRenderer(overlay: overlay)
        r.lineCap = .round
        r.lineJoin = .round
        switch (overlay as? MKPolyline)?.title {
        case "casing":
            r.strokeColor = NSColor.black.withAlphaComponent(0.45)
            r.lineWidth = 9
        case "done":
            r.strokeColor = theme.routeDone
            r.lineWidth = 10
        default:
            r.strokeColor = theme.routeAhead
            r.lineWidth = 4
        }
        return r
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        let view = MKAnnotationView(annotation: annotation, reuseIdentifier: nil)
        view.collisionMode = .none
        view.displayPriority = .required
        let theme = self.theme
        switch annotation {
        case is RunnerAnnotation:
            view.image = Self.image(size: 56) { ctx, r in
                Draw.radialGlow(ctx, center: CGPoint(x: r.midX, y: r.midY), radius: 28, color: theme.runner.withAlphaComponent(0.45))
                Theme.drawPin(ctx, at: CGPoint(x: r.midX, y: r.midY), radius: 15, color: theme.runner)
            }
            view.zPriority = .max
        case let st as StationAnnotation:
            view.image = Self.image(size: 30) { ctx, r in
                Draw.stationBadge(ctx, center: CGPoint(x: r.midX, y: r.midY), radius: 12, station: st.station,
                                  theme: theme, alpha: 1)
            }
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
