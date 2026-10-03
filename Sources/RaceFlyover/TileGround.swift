import AppKit
import MapKit
import QuartzCore
import simd

/// Renders Apple Maps imagery for a square of the Web Mercator grid with
/// MKMapSnapshotter. Snapshots are rendered offscreen by MapKit, so they work
/// inside the screensaver host, where a live MKMapView's Metal surface is given
/// no size and stays grey. Results are cached in memory and on disk.
final class AppleMapTiles {
    static let shared = AppleMapTiles()

    private let images = NSCache<NSString, CGImage>()
    private var inflight = Set<String>()
    private var queue: [(key: String, start: () -> Void)] = []
    private let maxConcurrent = 4
    private let diskDir: URL?
    private(set) var loadedCount = 0
    private(set) var failedCount = 0
    var pendingCount: Int { inflight.count + queue.count }

    private init() {
        images.countLimit = 300
        diskDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RaceFlyoverAppleMaps", isDirectory: true)
        if let diskDir { try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true) }
    }

    static func cacheKey(style: VisualStyle, z: Int, x: Int, y: Int) -> String { "\(style.rawValue)-\(z)-\(x)-\(y)" }

    /// Returns the image if ready; otherwise queues a snapshot (nearest first,
    /// as callers ask in priority order) and calls `ready` when it arrives.
    func image(style: VisualStyle, z: Int, x: Int, y: Int, ready: @escaping (CGImage) -> Void) -> CGImage? {
        let key = Self.cacheKey(style: style, z: z, x: x, y: y)
        if let img = images.object(forKey: key as NSString) { return img }
        if let url = diskDir?.appendingPathComponent(key + ".png"),
           let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            images.setObject(img, forKey: key as NSString)
            return img
        }
        guard !inflight.contains(key), !queue.contains(where: { $0.key == key }) else { return nil }
        queue.append((key, { [weak self] in self?.snapshot(key: key, style: style, z: z, x: x, y: y, ready: ready) }))
        pump()
        return nil
    }

    /// Drops queued requests that are no longer needed (camera moved on).
    func retainOnly(_ keys: Set<String>) {
        queue.removeAll { !keys.contains($0.key) }
    }

    private func pump() {
        while inflight.count < maxConcurrent, !queue.isEmpty {
            let next = queue.removeFirst()
            inflight.insert(next.key)
            next.start()
        }
    }

    private func snapshot(key: String, style: VisualStyle, z: Int, x: Int, y: Int, ready: @escaping (CGImage) -> Void) {
        let world = MKMapSize.world.width
        let size = world / Double(1 << z)
        let options = MKMapSnapshotter.Options()
        options.mapRect = MKMapRect(x: Double(x) * size, y: Double(y) * size, width: size, height: size)
        options.size = NSSize(width: 512, height: 512)
        options.preferredConfiguration = Self.configuration(for: style)
        options.appearance = NSAppearance(named: style == .mapLight ? .aqua : .darkAqua)
        MKMapSnapshotter(options: options).start(with: .global(qos: .userInitiated)) { [weak self] snap, error in
            var image: CGImage?
            if let snap {
                var rect = CGRect(origin: .zero, size: snap.image.size)
                image = snap.image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            }
            if let image, let url = self?.diskDir?.appendingPathComponent(key + ".png"),
               let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.inflight.remove(key)
                if let image {
                    self.images.setObject(image, forKey: key as NSString)
                    self.loadedCount += 1
                    ready(image)
                } else {
                    self.failedCount += 1
                    if let error { NSLog("RaceFlyover: Apple Maps snapshot failed: %@", error.localizedDescription) }
                }
                self.pump()
            }
        }
    }

    static func configuration(for style: VisualStyle) -> MKMapConfiguration {
        switch style {
        case .satellitePlain:
            return MKImageryMapConfiguration(elevationStyle: .flat)
        case .satellite:
            let c = MKHybridMapConfiguration(elevationStyle: .flat)
            c.pointOfInterestFilter = .excludingAll
            return c
        default:
            let c = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            c.pointOfInterestFilter = .excludingAll
            return c
        }
    }
}

/// Apple Maps imagery laid out as a ground plane in 3D. Each map square is a
/// Core Animation layer whose projective transform matches the stylized
/// `Projector`, so the route and pins drawn on top line up exactly.
final class TileGroundView: NSView {
    private struct Key: Hashable { let z: Int; let x: Int; let y: Int }

    private var levels: [CALayer] = []
    private var tiles: [Key: CALayer] = [:]
    var style: VisualStyle = .satellite {
        didSet {
            guard style != oldValue else { return }
            tiles.values.forEach { $0.removeFromSuperlayer() }
            tiles.removeAll()
        }
    }
    /// Called if Apple Maps keeps failing to produce imagery (e.g. offline).
    var onFailure: (() -> Void)?

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.06, green: 0.07, blue: 0.09, alpha: 1).cgColor
        layer?.masksToBounds = true
        // Coarse → fine.
        for _ in 0..<3 {
            let l = CALayer()
            l.actions = ["sublayers": NSNull()]
            layer?.addSublayer(l)
            levels.append(l)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var attribution: String { "Apple Maps" }

    private var lastProjector: Projector?
    private var lastRects: [Key: (x: Double, y: Double, w: Double, h: Double)] = [:]

    /// Largest distance (points) between where Core Animation places a tile
    /// corner and where the stylized projector puts the same ground point.
    func debugMaxProjectionError() -> Double {
        guard let proj = lastProjector, let root = layer else { return .nan }
        var worst = 0.0
        for (key, layer) in tiles {
            guard let r = lastRects[key] else { continue }
            let pad = 0.004
            let ox = r.x - r.w * pad, oy = r.y - r.h * pad, w = r.w * (1 + 2 * pad), h = r.h * (1 + 2 * pad)
            for (a, b) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
                let ca = layer.convert(CGPoint(x: a, y: b), to: root)
                let ours = proj.screen(proj.toCamera(SIMD3(ox + a * w, oy + b * h, 0)))
                worst = max(worst, hypot(Double(ca.x - ours.x), Double(ca.y - (bounds.height - ours.y))))
            }
        }
        return worst
    }

    /// Repositions map squares for the current camera. Ground sits at z = 0 to
    /// match the flat route the stylized view draws in map styles.
    func update(camera: CameraState, course: Course) {
        let size = bounds.size
        guard size.width > 10, size.height > 10 else { return }
        if AppleMapTiles.shared.failedCount >= 6 && AppleMapTiles.shared.loadedCount == 0 {
            onFailure?()
            return
        }
        var cam = camera
        let target = SIMD3(cam.target.x, cam.target.y, 0)
        cam.target = target
        let proj = Projector(camera: cam, target: target, size: size)
        lastProjector = proj
        let D = cam.distance
        let center = course.coordinate(x: target.x, y: target.y)
        let cosLat = cos(center.lat * .pi / 180)
        let earth = 40_075_016.686

        // Each snapshot covers one Web Mercator square ~1.5× the camera distance
        // near the runner, 4× and 16× larger further out.
        let fine = min(18, max(3, Int((log2(earth * cosLat / max(D * 1.5, 80))).rounded())))
        let tilt = sin(cam.tilt)
        let plan: [(z: Int, radius: Double, level: Int)] = [
            (fine, D * 2.2, 2),
            (max(2, fine - 2), D * (3 + 7 * tilt * tilt), 1),
            (max(2, fine - 4), D * (6 + 34 * pow(tilt, 4)), 0),
        ]

        var wanted = Set<Key>()
        var wantedKeys = Set<String>()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Fine level first so its snapshots are queued ahead of coarser ones.
        for step in plan {
            let z = step.z
            let n = Double(1 << z)
            let (latA, lonA) = course.coordinate(x: target.x - step.radius, y: target.y - step.radius)
            let (latB, lonB) = course.coordinate(x: target.x + step.radius, y: target.y + step.radius)
            let x0 = Int(floor(Self.tileX(lonA, n))), x1 = Int(floor(Self.tileX(lonB, n)))
            let y0 = Int(floor(Self.tileY(latB, n))), y1 = Int(floor(Self.tileY(latA, n)))
            guard x1 - x0 < 24, y1 - y0 < 24 else { continue }
            var candidates: [(Key, Double, CATransform3D, (x: Double, y: Double, w: Double, h: Double))] = []
            // Squares that reach behind the camera are split into their quarters
            // (more detailed snapshots) so the foreground has no holes.
            func consider(_ z: Int, _ tx: Int, _ ty: Int, splitsLeft: Int) {
                let n = Double(1 << z)
                let w = course.local(lat: Self.lat(Double(ty + 1), n), lon: Self.lon(Double(tx), n))
                let e = course.local(lat: Self.lat(Double(ty), n), lon: Self.lon(Double(tx + 1), n))
                let rect = (x: w.x, y: w.y, w: e.x - w.x, h: e.y - w.y)
                let dx = max(rect.x - target.x, 0, target.x - (rect.x + rect.w))
                let dy = max(rect.y - target.y, 0, target.y - (rect.y + rect.h))
                let dist = hypot(dx, dy)
                guard dist <= step.radius else { return }
                switch Self.placement(rect: rect, proj: proj, size: size) {
                case .visible(let transform):
                    candidates.append((Key(z: z, x: tx, y: ty), dist, transform, rect))
                case .behindCamera where splitsLeft > 0 && z < 19:
                    for (cx, cy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                        consider(z + 1, tx * 2 + cx, ty * 2 + cy, splitsLeft: splitsLeft - 1)
                    }
                default:
                    break
                }
            }
            for tx in x0...x1 {
                for ty in y0...y1 {
                    consider(z, tx, ty, splitsLeft: step.level == 2 ? 3 : 1)
                }
            }
            for (key, _, transform, rect) in candidates.sorted(by: { $0.1 < $1.1 }) {
                wanted.insert(key)
                wantedKeys.insert(AppleMapTiles.cacheKey(style: style, z: key.z, x: key.x, y: key.y))
                let layer = tiles[key] ?? makeTile(key, level: step.level)
                layer.transform = transform
                lastRects[key] = rect
            }
        }
        for (key, layer) in tiles where !wanted.contains(key) {
            layer.removeFromSuperlayer()
            tiles[key] = nil
            lastRects[key] = nil
        }
        CATransaction.commit()
        AppleMapTiles.shared.retainOnly(wantedKeys)
    }

    private func makeTile(_ key: Key, level: Int) -> CALayer {
        let l = CALayer()
        l.anchorPoint = .zero
        l.position = .zero
        l.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        l.contentsGravity = .resize
        l.edgeAntialiasingMask = []
        l.isDoubleSided = true
        l.minificationFilter = .trilinear
        l.actions = ["contents": NSNull(), "transform": NSNull(), "opacity": NSNull()]
        levels[level].addSublayer(l)
        tiles[key] = l
        if let img = AppleMapTiles.shared.image(style: style, z: key.z, x: key.x, y: key.y, ready: { [weak l] img in
            l?.contents = img
        }) {
            l.contents = img
        }
        return l
    }

    /// Projective transform taking the unit square onto the tile's ground
    /// rectangle as seen by `proj`, in this (unflipped) layer's coordinates.
    /// Reports when part of the tile is behind the camera (it can't be drawn
    /// as one projective quad) or when it's entirely off screen.
    private enum Placement { case visible(CATransform3D), behindCamera, offScreen }

    private static func placement(rect: (x: Double, y: Double, w: Double, h: Double), proj: Projector,
                                  size: CGSize) -> Placement {
        // Overlap neighbours slightly so no hairline seams show between tiles.
        let pad = 0.004
        let ox = rect.x - rect.w * pad, oy = rect.y - rect.h * pad
        let w = rect.w * (1 + 2 * pad), h = rect.h * (1 + 2 * pad)

        let corners = [SIMD3(ox, oy, 0), SIMD3(ox + w, oy, 0), SIMD3(ox, oy + h, 0), SIMD3(ox + w, oy + h, 0)]
        let cam = corners.map(proj.toCamera)
        guard cam.allSatisfy({ $0.z > proj.near }) else {
            return cam.allSatisfy({ $0.z <= proj.near }) ? .offScreen : .behindCamera
        }
        let pts = cam.map(proj.screen)
        let W = Double(size.width), H = Double(size.height)
        if pts.allSatisfy({ $0.x < 0 }) || pts.allSatisfy({ $0.x > W })
            || pts.allSatisfy({ $0.y < 0 }) || pts.allSatisfy({ $0.y > H }) { return .offScreen }

        // Screen (unflipped) = (gX·v, gY·v) / (gW·v), with v = p - eye in world space.
        let f = proj.forward, r = proj.right, u = proj.up
        let gX = proj.cx * f + proj.focal * r
        let gY = (H - proj.cy) * f + proj.focal * u
        let gW = f
        let v0 = SIMD3(ox, oy, 0) - proj.eye
        var m = CATransform3DIdentity
        m.m11 = CGFloat(w * gX.x); m.m12 = CGFloat(w * gY.x); m.m13 = 0; m.m14 = CGFloat(w * gW.x)
        m.m21 = CGFloat(h * gX.y); m.m22 = CGFloat(h * gY.y); m.m23 = 0; m.m24 = CGFloat(h * gW.y)
        m.m31 = 0; m.m32 = 0; m.m33 = 1; m.m34 = 0
        m.m41 = CGFloat(simd_dot(gX, v0)); m.m42 = CGFloat(simd_dot(gY, v0)); m.m43 = 0
        m.m44 = CGFloat(simd_dot(gW, v0))
        return .visible(m)
    }

    // Web Mercator tile maths.
    private static func tileX(_ lon: Double, _ n: Double) -> Double { (lon + 180) / 360 * n }
    private static func tileY(_ lat: Double, _ n: Double) -> Double {
        let r = lat * .pi / 180
        return (1 - log(tan(r) + 1 / cos(r)) / .pi) / 2 * n
    }
    private static func lon(_ x: Double, _ n: Double) -> Double { x / n * 360 - 180 }
    private static func lat(_ y: Double, _ n: Double) -> Double {
        atan(sinh(.pi * (1 - 2 * y / n))) * 180 / .pi
    }
}
