import AppKit
import MapKit

/// The whole course as a single MapKit overlay. Drawn by `RouteRenderer`
/// inside the map rather than above it, so 3D buildings standing between the
/// camera and the road hide the route just as they hide the road.
final class RouteOverlay: NSObject, MKOverlay {
    let points: [MKMapPoint]
    /// Map-point length along the route to each point.
    let lengths: [Double]
    let boundingMapRect: MKMapRect
    let coordinate: CLLocationCoordinate2D
    private let course: Course

    init(course: Course) {
        self.course = course
        points = course.lat.indices.map { MKMapPoint(CLLocationCoordinate2D(latitude: course.lat[$0], longitude: course.lon[$0])) }
        var total = 0.0
        var lengths = [0.0]
        for i in 1..<points.count {
            total += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
            lengths.append(total)
        }
        self.lengths = lengths
        let xs = points.map(\.x), ys = points.map(\.y)
        boundingMapRect = MKMapRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        coordinate = course.centerCoordinate
        super.init()
        underground = (course.data.tunnels ?? []).compactMap { r in
            guard r.count == 2 else { return nil }
            let a = mapLength(atTraced: course.along(officialKm: r[0])), b = mapLength(atTraced: course.along(officialKm: r[1]))
            return min(a, b)...max(a, b)
        }
    }

    /// Underground stretches, as ranges of map-point length.
    private(set) var underground: [ClosedRange<Double>] = []

    /// Map-point length along the route at `d` traced metres.
    func mapLength(atTraced d: Double) -> Double {
        let (i, t) = course.locate(d)
        let j = min(i + 1, lengths.count - 1)
        return lengths[i] + (lengths[j] - lengths[i]) * t
    }

    /// Bounding rect of the route between two map-point lengths.
    func rect(from a: Double, to b: Double) -> MKMapRect {
        let lo = min(a, b), hi = max(a, b)
        var i = max(0, (lengths.firstIndex { $0 >= lo } ?? lengths.count - 1) - 1)
        var rect = MKMapRect.null
        while i < points.count {
            rect = rect.union(MKMapRect(origin: points[i], size: MKMapSize(width: 0, height: 0)))
            if lengths[i] > hi { break }
            i += 1
        }
        return rect
    }
}

/// Draws the route inside the map: the stretch still to run in a lighter,
/// see-through shade, the covered stretch in the trail colour with a white
/// edge, and tunnels dashed. As the runner moves only the small patch of map
/// around the end of the covered stretch is redrawn, so the rest of the line
/// never flickers.
final class RouteRenderer: MKOverlayRenderer {
    private let route: RouteOverlay
    private let lock = NSLock()
    private var covered = 0.0

    // Set on the main thread before the overlay is first drawn, or followed by `setNeedsDisplay()`.
    var aheadColor = NSColor.white.withAlphaComponent(0.55)
    var doneColor = NSColor.systemBlue
    var casingColor = NSColor.white.withAlphaComponent(0.92)
    /// Line widths in metres on the ground (the same in every tile, whatever
    /// its level of detail, so the line never steps in thickness).
    var aheadWidth: CGFloat = 8
    var coreWidth: CGFloat = 7.5
    var casingWidth: CGFloat = 10.5
    var mapPointsPerMetre: Double { MKMapPointsPerMeterAtLatitude(route.coordinate.latitude) }

    init(route: RouteOverlay) {
        self.route = route
        super.init(overlay: route)
    }

    /// Moves the end of the covered stretch to `length` (map points along the
    /// route) and redraws only the map around the change. `padding` (map
    /// points) must cover the widest line at the current zoom.
    func setCovered(_ length: Double, padding: Double) {
        lock.lock()
        let old = covered
        covered = length
        lock.unlock()
        guard abs(length - old) > 0 else { return }
        let dirty = route.rect(from: old, to: length).insetBy(dx: -padding, dy: -padding)
        setNeedsDisplay(dirty)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        lock.lock()
        let done = covered
        lock.unlock()
        let perMetre = mapPointsPerMetre
        let pad = Double(casingWidth) * perMetre
        let area = mapRect.insetBy(dx: -pad, dy: -pad)
        let tunnels = route.underground

        // Split every segment touching this tile into covered / still to run,
        // and surface / tunnel, joining consecutive pieces into continuous lines.
        var paths: [Int: CGMutablePath] = [:]       // key: covered(1/0) * 2 + tunnel(1/0)
        var ends: [Int: CGPoint] = [:]
        func add(_ key: Int, from a: MKMapPoint, to b: MKMapPoint) {
            let p = point(for: a), q = point(for: b)
            let path = paths[key] ?? CGMutablePath()
            if let end = ends[key], abs(end.x - p.x) < 0.001, abs(end.y - p.y) < 0.001 {
                path.addLine(to: q)
            } else {
                path.move(to: p)
                path.addLine(to: q)
            }
            paths[key] = path
            ends[key] = q
        }
        let pts = route.points, len = route.lengths
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let seg = MKMapRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            guard seg.intersects(area) else { continue }
            let l0 = len[i], l1 = len[i + 1]
            guard l1 > l0 else { continue }
            // Break points along this segment: covered boundary and tunnel edges.
            var cuts = [l0, l1]
            if done > l0 && done < l1 { cuts.append(done) }
            for t in tunnels {
                if t.lowerBound > l0 && t.lowerBound < l1 { cuts.append(t.lowerBound) }
                if t.upperBound > l0 && t.upperBound < l1 { cuts.append(t.upperBound) }
            }
            cuts.sort()
            func at(_ l: Double) -> MKMapPoint {
                let t = (l - l0) / (l1 - l0)
                return MKMapPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            for k in 0..<(cuts.count - 1) where cuts[k + 1] > cuts[k] {
                let mid = (cuts[k] + cuts[k + 1]) / 2
                let key = (mid < done ? 2 : 0) + (tunnels.contains { $0.contains(mid) } ? 1 : 0)
                add(key, from: at(cuts[k]), to: at(cuts[k + 1]))
            }
        }

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        func stroke(_ path: CGPath?, _ color: NSColor, _ width: CGFloat, dashed: Bool) {
            guard let path else { return }
            let w = width * CGFloat(perMetre)
            ctx.addPath(path)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(w)
            if dashed { ctx.setLineDash(phase: 0, lengths: [w * 0.9, w * 1.1]) } else { ctx.setLineDash(phase: 0, lengths: []) }
            ctx.strokePath()
        }
        // Still to run: composite as one layer so crossings and joins don't darken.
        if paths[0] != nil || paths[1] != nil {
            ctx.saveGState()
            ctx.setAlpha(aheadColor.alphaComponent)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            let solid = aheadColor.withAlphaComponent(1)
            stroke(paths[0], solid, aheadWidth, dashed: false)
            stroke(paths[1], solid, aheadWidth, dashed: true)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        // Covered: white edge, then the trail colour.
        stroke(paths[2], casingColor, casingWidth, dashed: false)
        stroke(paths[3], casingColor, casingWidth, dashed: true)
        stroke(paths[2], doneColor, coreWidth, dashed: false)
        stroke(paths[3], doneColor, coreWidth * 0.8, dashed: true)
    }
}
