import AppKit
import ScreenSaver

@objc(RaceFlyoverView)
public final class RaceFlyoverView: ScreenSaverView {
    /// Every live instance in this process. The screensaver host creates a new
    /// view each time the preview restarts or settings change, and doesn't always
    /// release the old ones, so we stop the ones it has detached.
    private static let instances = NSHashTable<RaceFlyoverView>.weakObjects()
    private static var nextSerial = 0
    /// Creation order, used to pick which screen leads when screens show the same course.
    private let serial: Int = {
        RaceFlyoverView.nextSerial += 1
        return RaceFlyoverView.nextSerial
    }()

    private let settings = Settings()
    private(set) var config: Config
    private(set) var engine: FlyoverEngine?
    /// Live Apple Maps with 3D terrain and buildings (first choice for map styles).
    private var liveMap: MapFlyoverView?
    /// Flat Apple Maps imagery under the route, used if the live map can't draw.
    private var tileGround: TileGroundView?
    private let stylized = StylizedView()
    private let glassLayer = GlassPanelsView()
    private let hud = HUDOverlayView()
    private let areaNamer = AreaNamer()
    private var lastTick: CFTimeInterval = 0
    /// Display-synchronised clock (falls back to the screensaver timer if the
    /// host never delivers callbacks).
    private var link: CADisplayLink?
    private var lastLinkTick: CFTimeInterval = 0
    /// Set if the live 3D map can't draw in this host; map styles then use flat imagery.
    private var liveFailed = false
    /// Set if Apple Maps couldn't produce imagery at all; map styles then use Midnight.
    private var mapFailed = false
    private var sheetController: ConfigSheetController?
    /// Used by the preview app.
    var paused = false

    public override init?(frame: NSRect, isPreview: Bool) {
        config = settings.config
        super.init(frame: frame, isPreview: isPreview)
        Draw.typeface = config.typeface
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        Self.instances.add(self)
        for view in [stylized, glassLayer, hud] as [NSView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        rebuildEngine()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: Settings.didChange, object: nil)
        // legacyScreenSaver keeps running after the screensaver is dismissed on
        // recent macOS versions; stop animating so it doesn't burn CPU or GPU.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenSaverWillStop),
                                                            name: .init("com.apple.screensaver.willstop"), object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    /// Uses the flat Apple Maps imagery instead of the live map (snapshots: the
    /// live map's Metal surface can't be captured).
    func useFlatMapImagery() {
        liveFailed = true
        installContent()
    }

    /// Set once the preview app overrides options from the command line, so
    /// saved settings don't replace them.
    private var hasOverrides = false

    /// Overrides options without saving them (preview app snapshots).
    func override(_ change: (inout Config) -> Void) {
        hasOverrides = true
        change(&config)
        applyConfig()
    }

    private func rebuildEngine() {
        let playlist = CourseLibrary.playlist(for: config.selection, settings: settings)
        guard !playlist.isEmpty else { return }
        let start = playlist.count > 1 ? Int.random(in: 0..<playlist.count) : 0
        engine = FlyoverEngine(playlist: playlist, config: config, startIndex: start)
        installContent()
        animationTimeInterval = config.smooth60 ? 1.0 / 60 : 1.0 / 30
    }

    private func applyConfig() {
        Draw.typeface = config.typeface
        let playlist = CourseLibrary.playlist(for: config.selection, settings: settings)
        if let engine {
            engine.update(playlist: playlist, config: config)
        } else {
            rebuildEngine()
        }
        installContent()
        animationTimeInterval = config.smooth60 ? 1.0 / 60 : 1.0 / 30
        updateLinkRate()
        renderFrame()
    }

    @objc private func settingsChanged() {
        config = settings.config
        applyConfig()
    }

    @objc private func screenSaverWillStop() {
        guard !isPreview else { return }
        stopAnimationIfNeeded()
    }

    // MARK: - Content

    /// Map styles use Apple Maps except in the tiny System Settings thumbnail,
    /// which shows the Midnight look instead.
    private var wantsMap: Bool {
        config.style.usesTiles && !isPreview && !mapFailed && window != nil && bounds.width > 200
    }
    private var wantsLive: Bool { wantsMap && !liveFailed }
    private var wantsTiles: Bool { wantsMap && liveFailed }

    /// With "main display only", every other screen stays black and does no work.
    private var isIdleScreen: Bool {
        guard !isPreview, config.displays == .mainOnly, let screen = window?.screen else { return false }
        return screen != NSScreen.screens.first
    }

    /// The instance other screens follow when showing the same course.
    private var leader: RaceFlyoverView? {
        guard config.displays == .same, !isPreview else { return nil }
        let earliest = Self.instances.allObjects
            .filter { $0 !== self && !$0.isPreview && $0.window != nil && $0.isAnimating && !$0.isIdleScreen && $0.engine != nil }
            .min { $0.serial < $1.serial }
        guard let earliest, earliest.serial < serial else { return nil }
        return earliest
    }

    private func installContent() {
        guard let engine else { return }
        let idle = isIdleScreen
        for v in [stylized, glassLayer, hud] as [NSView] { v.isHidden = idle }
        if idle {
            tearDownLiveMap()
            tileGround?.removeFromSuperview()
            tileGround = nil
            return
        }
        if wantsLive {
            Self.reapOrphans()
            if liveMap == nil {
                let v = MapFlyoverView(frame: bounds)
                v.autoresizingMask = [.width, .height]
                v.onFailure = { [weak self] in
                    self?.liveFailed = true
                    self?.installContent()
                }
                addSubview(v, positioned: .below, relativeTo: stylized)
                liveMap = v
            }
            liveMap?.engine = engine
        } else {
            tearDownLiveMap()
        }
        stylized.isHidden = wantsLive
        if wantsTiles {
            if tileGround == nil {
                let v = TileGroundView(frame: bounds)
                v.autoresizingMask = [.width, .height]
                v.onFailure = { [weak self] in
                    self?.mapFailed = true
                    self?.installContent()
                }
                addSubview(v, positioned: .below, relativeTo: stylized)
                tileGround = v
            }
            tileGround?.style = config.style
        } else {
            tileGround?.removeFromSuperview()
            tileGround = nil
        }
        let theme = Theme.forStyle(config.style.usesTiles && !wantsMap ? .midnight : config.style)
            .with(pin: config.pinColor, trail: config.trailColor)
        stylized.engine = engine
        stylized.theme = theme
        stylized.tileMode = wantsTiles
        stylized.attribution = tileGround?.attribution
        stylized.isThumbnail = isPreview
        hud.engine = engine
        hud.area = isPreview ? nil : areaNamer
        hud.theme = theme
        hud.isThumbnail = isPreview
        hud.usesGlass = config.panels.usesGlass
        glassLayer.clear = config.panels == .clearGlass
        glassLayer.isHidden = !config.panels.usesGlass || isPreview
    }

    private func tearDownLiveMap() {
        guard let liveMap else { return }
        liveMap.shutDown()
        liveMap.removeFromSuperview()
        self.liveMap = nil
    }

    /// Stops instances the host has detached but kept alive, and frees their maps.
    private static func reapOrphans() {
        for view in instances.allObjects where view.window == nil {
            view.stopAnimationIfNeeded()
            view.tearDownLiveMap()
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAnimationIfNeeded()
            tearDownLiveMap()
        } else {
            Self.reapOrphans()
            installContent()
            if isAnimating { startLink() }
        }
    }

    private var targetFPS: Float { config.smooth60 ? 60 : 30 }

    private func startLink() {
        guard link == nil, window != nil else { return }
        if #available(macOS 14.0, *) {
            let l = displayLink(target: self, selector: #selector(linkTick(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: min(24, targetFPS), maximum: targetFPS, preferred: targetFPS)
            l.add(to: .main, forMode: .common)
            link = l
        }
    }

    private func updateLinkRate() {
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: min(24, targetFPS), maximum: targetFPS, preferred: targetFPS)
    }

    @objc private func linkTick(_ l: CADisplayLink) {
        lastLinkTick = CACurrentMediaTime()
        // Advance to when this frame will actually be on screen, so motion is
        // even regardless of when the callback ran.
        advance(to: l.targetTimestamp)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // The host sometimes creates the view at 0×0 and resizes it later.
        if config.style.usesTiles && (liveMap == nil) == wantsLive { installContent() }
    }

    // MARK: - Animation

    private func stopAnimationIfNeeded() {
        if isAnimating { stopAnimation() }
    }

    public override func startAnimation() {
        super.startAnimation()
        lastTick = 0
        startLink()
        // Settings may have changed in another process (System Settings) since
        // this instance was created.
        let latest = settings.config
        if !hasOverrides && latest != config {
            config = latest
            applyConfig()
        }
    }

    public override func stopAnimation() {
        super.stopAnimation()
        link?.invalidate()
        link = nil
    }

    public override func animateOneFrame() {
        // The display link drives frames when it's running; this timer is the fallback.
        if CACurrentMediaTime() - lastLinkTick < 0.5 { return }
        advance(to: CACurrentMediaTime())
    }

    private func advance(to time: CFTimeInterval) {
        let dt = lastTick == 0 ? 0 : max(0, time - lastTick)
        lastTick = time
        guard window != nil, !isIdleScreen else { return }
        if dt > 0 { FrameStats.shared.frame(interval: dt) }
        if let leader = leader, let lead = leader.engine, let engine {
            engine.mirror(lead)
        } else if !paused {
            engine?.step(min(0.25, dt))
        }
        FrameStats.shared.measure("renderFrame") { renderFrame() }
        FrameStats.shared.reportIfDue(label: "\(config.style.rawValue) \(Int(bounds.width))x\(Int(bounds.height))")
    }

    func renderFrame() {
        guard let engine else { needsDisplay = true; return }
        engine.aspect = Double(bounds.width / max(bounds.height, 1))
        if !isPreview && config.hud == .full && engine.phase != .intro {
            areaNamer.update(courseID: engine.course.id, coordinate: engine.course.sample(at: engine.distance).coordinate,
                             now: CACurrentMediaTime())
        }
        if let liveMap { FrameStats.shared.measure("mapCamera") { liveMap.render() } }
        tileGround?.update(camera: engine.camera, course: engine.course)
        if liveMap == nil { stylized.needsDisplay = true }
        hud.refresh()
        // Glass follows the panel positions from the HUD's previous draw (one
        // frame behind, which is invisible at these speeds).
        glassLayer.update(hud.usesGlass ? hud.glassPanels : [])
    }

    public override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
        if engine == nil {
            let msg = Draw.text("No courses found in the screensaver bundle.", size: 16, color: .white)
            Draw.string(msg, at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: 0.5)
        }
    }

    // MARK: - Options sheet

    public override var hasConfigureSheet: Bool { true }

    /// System Settings may ask for the sheet more than once; always hand back the
    /// same window, kept alive by this view, with its controls refreshed.
    public override var configureSheet: NSWindow? {
        if sheetController == nil { sheetController = ConfigSheetController(settings: settings) }
        sheetController?.prepare()
        return sheetController?.window
    }
}
