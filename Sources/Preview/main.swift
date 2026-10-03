import AppKit
import QuartzCore

// Race Flyover Preview: runs the screensaver in a normal window so you can try
// settings without opening System Settings. Keys: Space pause, ←/→ move 1 km,
// N next course, ⌘, Options.
//
// Snapshot mode renders a single PNG and exits:
//   RaceFlyoverPreview --snapshot out.png [--course berlin] [--style neon]
//       [--progress 0.4] [--tilt 60] [--zoom 0.4] [--camera chase|northUp|overview]
//       [--phase intro|finish --time 3] [--size 1920x1080] [--hud full|minimal|off]

let arguments = CommandLine.arguments

func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

func applyOverrides(_ view: RaceFlyoverView) {
    view.override { c in
        if let v = option("--course") { c.selection = "course:" + v }
        if let v = option("--style").flatMap(VisualStyle.init) { c.style = v }
        if let v = option("--tilt").flatMap(Double.init) { c.tiltDegrees = v }
        if let v = option("--zoom").flatMap(Double.init) { c.zoom = v }
        if let v = option("--camera").flatMap(CameraMode.init) { c.camera = v }
        if let v = option("--hud").flatMap(HUDMode.init) { c.hud = v }
        if let v = option("--units").flatMap(Units.init) { c.units = v }
        if let v = option("--exaggeration").flatMap(Double.init) { c.exaggeration = v }
        if let v = option("--lap").flatMap(Double.init) { c.lapMinutes = v }
        if let v = option("--font").flatMap(Typeface.init) { c.typeface = v }
        if let v = option("--panels").flatMap(PanelStyle.init) { c.panels = v }
        if let v = option("--text-scale").flatMap(Double.init) { c.textScale = v }
    }
}

func parseSize() -> NSSize {
    let parts = (option("--size") ?? "1920x1080").split(separator: "x").compactMap { Double($0) }
    return parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : NSSize(width: 1920, height: 1080)
}

let app = NSApplication.shared

/// Draws the tile layers with Core Graphics, mapping each through the corner
/// positions Core Animation itself computes (`convert` applies the full 3D
/// transform). A fine triangle mesh stands in for true perspective texturing.
func drawTiles(_ ground: CALayer, in ctx: CGContext) {
    for level in ground.sublayers ?? [] {
        for tile in level.sublayers ?? [] {
            guard let contents = tile.contents else { continue }
            let image = contents as! CGImage
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            let n = 8
            func dst(_ i: Int, _ j: Int) -> CGPoint {
                tile.convert(CGPoint(x: CGFloat(i) / CGFloat(n), y: CGFloat(j) / CGFloat(n)), to: ground)
            }
            func src(_ i: Int, _ j: Int) -> CGPoint { CGPoint(x: CGFloat(i) / CGFloat(n) * iw, y: CGFloat(j) / CGFloat(n) * ih) }
            for i in 0..<n {
                for j in 0..<n {
                    for tri in [[(i, j), (i + 1, j), (i + 1, j + 1)], [(i, j), (i + 1, j + 1), (i, j + 1)]] {
                        let d = tri.map { dst($0.0, $0.1) }, sp = tri.map { src($0.0, $0.1) }
                        // Affine map taking the source triangle onto the destination.
                        let sx1 = sp[1].x - sp[0].x, sy1 = sp[1].y - sp[0].y, sx2 = sp[2].x - sp[0].x, sy2 = sp[2].y - sp[0].y
                        let det = sx1 * sy2 - sx2 * sy1
                        guard abs(det) > 1e-9 else { continue }
                        let dx1 = d[1].x - d[0].x, dy1 = d[1].y - d[0].y, dx2 = d[2].x - d[0].x, dy2 = d[2].y - d[0].y
                        let a = (dx1 * sy2 - dx2 * sy1) / det, c = (dx2 * sx1 - dx1 * sx2) / det
                        let b = (dy1 * sy2 - dy2 * sy1) / det, dd = (dy2 * sx1 - dy1 * sx2) / det
                        let t = CGAffineTransform(a: a, b: b, c: c, d: dd,
                                                  tx: d[0].x - a * sp[0].x - c * sp[0].y,
                                                  ty: d[0].y - b * sp[0].x - dd * sp[0].y)
                        ctx.saveGState()
                        let path = CGMutablePath()
                        path.addLines(between: d)
                        path.closeSubpath()
                        ctx.addPath(path)
                        ctx.clip()
                        ctx.concatenate(t)
                        ctx.draw(image, in: CGRect(x: 0, y: 0, width: iw, height: ih))
                        ctx.restoreGState()
                    }
                }
            }
        }
    }
}

/// Snapshot for imagery styles: waits for tiles, renders the ground with
/// CARenderer, then composites the route/pins and HUD over it.
func snapshotTiles(view: RaceFlyoverView, size: NSSize, output: String) {
    let deadline = Date().addingTimeInterval(30)
    repeat {
        view.renderFrame()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    } while (AppleMapTiles.shared.pendingCount > 0 || AppleMapTiles.shared.loadedCount == 0) && Date() < deadline
    view.renderFrame()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    guard let ground = view.subviews.first(where: { $0 is TileGroundView }) as? TileGroundView else { exit(1) }
    func capture(_ v: NSView) -> CGImage {
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep.cgImage!
    }
    if ProcessInfo.processInfo.environment["RACEFLYOVER_DEBUG"] != nil {
        print("projection mismatch vs Core Animation: \(String(format: "%.4f", ground.debugMaxProjectionError())) pt")
    }
    let overlays = view.subviews.filter { $0 is StylizedView || $0 is HUDOverlayView }.map(capture)
    let scale: CGFloat = 2
    let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    ctx.setFillColor(ground.layer!.backgroundColor!)
    ctx.fill(CGRect(origin: .zero, size: size))
    drawTiles(ground.layer!, in: ctx)
    for img in overlays { ctx.draw(img, in: CGRect(origin: .zero, size: size)) }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
    print("map snapshots: loaded \(AppleMapTiles.shared.loadedCount), failed \(AppleMapTiles.shared.failedCount), pending \(AppleMapTiles.shared.pendingCount)")
    print("wrote \(output) (tiles loaded: \(AppleMapTiles.shared.loadedCount))")
}

if arguments.contains("--list") {
    for c in CourseLibrary.all(settings: Settings()) {
        print(String(format: "%-18@ %-28@ %6.2f km  %2d fluid  %d fuel%@", c.id as NSString, c.name as NSString,
                     c.data.distanceKm, c.fluidStations, c.fuelStations,
                     c.data.stationsEstimated == true ? "  (estimated)" : ""))
    }
    exit(0)
}

if let output = option("--snapshot-options") {
    guard let view = RaceFlyoverView(frame: NSRect(x: 0, y: 0, width: 800, height: 450), isPreview: false),
          let sheet = view.configureSheet, let content = sheet.contentView else { exit(1) }
    content.layoutSubtreeIfNeeded()
    if arguments.contains("--dump") {
        func walk(_ v: NSView, _ depth: Int) {
            let f = v.convert(v.bounds, to: content)
            var title = ""
            if let t = v as? NSTextField { title = t.stringValue }
            if let b = v as? NSButton { title = b.title }
            if let p = v as? NSPopUpButton { title = p.titleOfSelectedItem ?? "" }
            if v is NSTextField || v is NSButton || v is NSSlider || v is NSSegmentedControl {
                print(String(format: "%@ %.0f,%.0f %.0fx%.0f  %@", String(describing: type(of: v)), f.minX, f.minY, f.width, f.height, String(title.prefix(50))))
            }
            v.subviews.forEach { walk($0, depth + 1) }
        }
        print("content", content.bounds)
        walk(content, 0)
    }
    let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
    content.cacheDisplay(in: content.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
    print("wrote \(output)")
    exit(0)
}

if let output = option("--snapshot") {
    let size = parseSize()
    let preview = arguments.contains("--thumbnail")
    guard let view = RaceFlyoverView(frame: NSRect(origin: .zero, size: size), isPreview: preview) else { exit(1) }
    applyOverrides(view)
    guard let engine = view.engine else { print("no courses"); exit(1) }
    switch option("--phase") {
    case "intro": engine.show(phase: .intro, at: option("--time").flatMap(Double.init) ?? 3)
    case "finish": engine.show(phase: .finish, at: option("--time").flatMap(Double.init) ?? 2)
    default:
        engine.seek(fraction: option("--progress").flatMap(Double.init) ?? 0.3)
        // Give the neighbourhood lookup a moment, as it would have during playback.
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            view.renderFrame()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }
    if view.config.style.usesTiles && !preview {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = view
        view.useFlatMapImagery()
        snapshotTiles(view: view, size: size, output: output)
        exit(0)
    }
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.contentView = view
    view.renderFrame()
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
    view.cacheDisplay(in: view.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
    print("wrote \(output)")
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var saver: RaceFlyoverView!
    var timer: Timer?
    var sheetWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let size = option("--size") != nil ? parseSize() : NSSize(width: 1440, height: 810)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Race Flyover Preview"
        window.center()
        saver = RaceFlyoverView(frame: window.contentView!.bounds, isPreview: false)
        saver.autoresizingMask = [.width, .height]
        applyOverrides(saver)
        window.contentView = saver
        window.makeKeyAndOrderFront(nil)
        saver.startAnimation()
        scheduleTimer()
        NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleTimer()
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.sheetWindow == nil else { return event }
            switch event.keyCode {
            case 49: self.saver.paused.toggle()
            case 124: self.saver.engine?.jump(by: 1000)
            case 123: self.saver.engine?.jump(by: -1000)
            default:
                if event.charactersIgnoringModifiers == "n" { self.saver.engine?.nextCourse() } else { return event }
            }
            return nil
        }
        buildMenu()
        NSApp.activate(ignoringOtherApps: true)
    }

    func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: saver.animationTimeInterval, repeats: true) { [weak self] _ in
            self?.saver.animateOneFrame()
        }
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Options…", action: #selector(showOptions), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Race Flyover Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    @objc func showOptions() {
        guard sheetWindow == nil, let sheet = saver.configureSheet else { return }
        sheetWindow = sheet
        window.beginSheet(sheet) { [weak self] _ in self?.sheetWindow = nil }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
