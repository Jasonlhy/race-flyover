import CoreLocation
import Foundation
import simd

struct CameraState {
    /// Look-at point: x/y metres in course space, z = terrain elevation metres.
    var target: SIMD3<Double>
    var coordinate: CLLocationCoordinate2D
    /// Radians clockwise from north.
    var heading: Double
    /// Radians from straight down.
    var tilt: Double
    /// Metres from camera to target.
    var distance: Double
}

/// Drives playback: which course is showing, how far along the runner is, and
/// where the camera sits. Renderers only read from it.
final class FlyoverEngine {
    enum Phase { case intro, running, finish, fadeOut }

    /// A ring pulse from the pin when the runner passes something.
    struct Burst {
        enum Kind { case fluid, fuel, both, marker, half }
        let kind: Kind
        let start: Double
    }
    static let burstDuration = 1.6
    private(set) var bursts: [Burst] = []

    /// A place where the runner slows down and the camera frames the view.
    struct Stop {
        enum Kind { case landmark, station, marker }
        let kind: Kind
        /// Traced metres along the course.
        let d: Double
        /// Where a landmark actually is (course x/y), which may be off the road.
        let focus: SIMD2<Double>?
        /// Rough size of what's there, in metres.
        let radius: Double

        var hold: Double { kind == .landmark ? 5.5 : (kind == .station ? 2.6 : 2.0) }
        var slowest: Double { kind == .landmark ? 0.04 : (kind == .station ? 0.12 : 0.16) }
    }

    /// The stop being visited and when the visit began.
    struct Visit {
        let stop: Stop
        let start: Double
    }
    private(set) var visit: Visit?
    private var stops: [Stop] = []
    private var stopsKey = ""
    static let slowIn = 1.8, slowOut = 1.8, settle = 1.6

    /// Set each frame by the view: whether everything for the start has loaded.
    var sceneReady = true
    static let maxLoadWait = 25.0
    static let introDuration = 7.0
    static let finishDuration = 7.0
    static let fadeDuration = 1.2
    static let fieldOfView = 50.0 * Double.pi / 180

    private(set) var playlist: [Course]
    private(set) var index: Int
    private(set) var phase = Phase.intro
    private(set) var phaseTime = 0.0
    private(set) var time = 0.0
    /// Metres travelled along the traced course.
    private(set) var distance = 0.0
    private(set) var camera: CameraState
    var config: Config
    var aspect = 16.0 / 9.0
    private var heading = 0.0
    /// Smoothed building density at the runner (0 open … 1 dense), for automatic tilt.
    /// How straight the road ahead is, eased over time (0 bendy … 1 a long straight).
    private var straight = 0.0
    /// Raw straightness every `straightStep` metres along the current course.
    private var straightProfile: [Double] = []
    private var straightCourse = ""
    private static let straightStep = 50.0
    /// How much tall buildings crowd the route, eased over time (0 none … 1 towers all round).
    private var builtUp = 0.0

    var course: Course { playlist[index] }

    init(playlist: [Course], config: Config, startIndex: Int = 0) {
        precondition(!playlist.isEmpty)
        self.playlist = playlist
        self.config = config
        index = min(max(startIndex, 0), playlist.count - 1)
        camera = CameraState(target: .zero, coordinate: CLLocationCoordinate2D(), heading: 0, tilt: 0, distance: 1000)
        beginCourse()
    }

    /// Applies new options. Keeps the current course if it is still in the playlist.
    func update(playlist newList: [Course], config newConfig: Config) {
        config = newConfig
        guard !newList.isEmpty else { return }
        let currentID = course.id
        playlist = newList
        if let i = newList.firstIndex(where: { $0.id == currentID }) {
            index = i
        } else {
            index = 0
            beginCourse()
        }
        updateCamera()
    }

    private func beginCourse() {
        visit = nil
        distance = 0
        phase = .intro
        phaseTime = 0
        heading = config.camera == .northUp ? 0 : course.heading(at: 0, behind: 0, ahead: 600)
        straight = straightness(at: 0)
        builtUp = crowding(atKm: 0)
        updateCamera()
    }

    /// Jumps straight into the run at `fraction` of the course (for previews).
    func seek(fraction: Double) {
        distance = min(max(fraction, 0), 1) * course.length
        visit = nil
        phase = .running
        phaseTime = 0
        straight = straightness(at: distance)
        builtUp = crowding(atKm: course.officialKm(at: distance))
        heading = config.camera == .northUp ? 0 : course.heading(at: distance)
        updateCamera()
    }

    /// Copies another engine's playback state ("same course on every screen").
    /// The camera is still computed here, for this screen's shape.
    func mirror(_ other: FlyoverEngine) {
        if playlist.map(\.id) != other.playlist.map(\.id) { playlist = other.playlist }
        index = min(other.index, playlist.count - 1)
        phase = other.phase
        phaseTime = other.phaseTime
        time = other.time
        distance = other.distance
        heading = other.heading
        straight = other.straight
        builtUp = other.builtUp
        visit = other.visit
        bursts = other.bursts
        updateCamera()
    }

    /// Keeps this engine in step with another screen's while still advancing on
    /// its own clock (call after `step`). Copying the other engine every frame
    /// instead made motion uneven, because the screens' frames don't line up,
    /// and lost the pulses. `lag` is how much later this frame is shown than
    /// the other engine's latest one, in seconds.
    func sync(to other: FlyoverEngine, lag: Double) {
        guard other.index == index, other.course.id == course.id, other.phase == phase else {
            mirror(other)
            return
        }
        let lag = min(max(lag, -0.1), 0.1)
        let expectedTime = other.time + lag
        if phase == .running {
            let expected = min(course.length, other.distance + other.metresPerSecond * other.speedFactor * lag)
            let error = expected - distance
            if abs(error) > max(30, metresPerSecond * 0.5) {
                mirror(other)
                time = expectedTime
                return
            }
            // Ease out small differences over a few frames, invisibly.
            distance += error * 0.1
            // Visits are decided by each engine at the same spot; follow the
            // other screen's if they disagree, on this engine's clock.
            if other.visit?.stop.d != visit?.stop.d {
                visit = other.visit.map { Visit(stop: $0.stop, start: $0.start - other.time + time) }
            }
        } else {
            phaseTime += (other.phaseTime + lag - phaseTime) * 0.1
        }
        time += (expectedTime - time) * 0.1
    }

    /// Moves the runner by `metres` (preview app arrow keys).
    func jump(by metres: Double) {
        if phase != .running { phase = .running; phaseTime = 0 }
        distance = min(max(distance + metres, 0), course.length - 1)
        visit = nil
    }

    /// Shows the intro/finish sequences at a given moment (preview snapshots).
    func show(phase newPhase: Phase, at t: Double) {
        if newPhase == .finish { distance = course.length }
        visit = nil
        phase = newPhase
        phaseTime = t
        updateCamera()
    }

    func nextCourse() {
        index = (index + 1) % playlist.count
        beginCourse()
    }

    var metresPerSecond: Double { course.length / max(config.lapMinutes * 60, 30) }

    func step(_ dt: Double) {
        time += dt
        phaseTime += dt
        var moved = 0.0
        switch phase {
        case .intro:
            // Hold at the start line until the scene has finished loading (map
            // imagery, 3D buildings, landmarks), but not for ever: offline, or
            // on a slow connection, the run starts anyway.
            if phaseTime >= Self.introDuration, sceneReady || phaseTime >= Self.introDuration + Self.maxLoadWait {
                phase = .running
                phaseTime = 0
            }
        case .running:
            updateVisit()
            moved = metresPerSecond * speedFactor * dt
            let before = distance
            distance += moved
            detectBursts(from: before, to: min(distance, course.length))
            if distance >= course.length {
                distance = course.length
                phase = .finish
                phaseTime = 0
            }
        case .finish:
            if phaseTime >= Self.finishDuration { phase = .fadeOut; phaseTime = 0 }
        case .fadeOut:
            if phaseTime >= Self.fadeDuration { nextCourse(); return }
        }
        bursts.removeAll { time - $0.start > Self.burstDuration }
        // Ease towards how straight the road ahead is over a few seconds, so the
        // camera glides between views rather than jumping at each corner.
        straight += (straightness(at: distance) - straight) * (1 - exp(-dt / 3.0))
        builtUp += (crowding(atKm: course.officialKm(at: distance)) - builtUp) * (1 - exp(-dt / 3.0))
        updateHeading(dt: dt, moved: moved)
        updateCamera()
    }

    private func detectBursts(from a: Double, to b: Double) {
        guard b > a, config.showBursts else { return }
        let k0 = course.officialKm(at: a), k1 = course.officialKm(at: b)
        for st in course.data.stations where st.km > k0 && st.km <= k1 {
            let fluid = st.fluid && config.showFluid, fuel = st.fuel && config.showFuel
            if fluid || fuel { bursts.append(Burst(kind: fluid && fuel ? .both : (fluid ? .fluid : .fuel), start: time)) }
        }
        let total = course.data.distanceKm
        if total > 40, k0 < total / 2, k1 >= total / 2 {
            bursts.append(Burst(kind: .half, start: time))
        } else if config.showMarkers {
            let unit = config.units.kmPerUnit
            if floor(k1 / unit) > floor(k0 / unit) { bursts.append(Burst(kind: .marker, start: time)) }
        }
    }

    // MARK: - Slowing down at stops

    /// The stops for the current course and options (landmarks arrive from
    /// Apple Maps a little after a course starts, so this is refreshed as they do).
    private func refreshStops() {
        let mode = config.slowDown
        let landmarks = mode.landmarks ? LandmarkStore.shared.landmarks(for: course) : []
        let key = "\(course.id)|\(mode)|\(landmarks.count)|\(config.showFluid)|\(config.showFuel)|\(config.units)"
        guard key != stopsKey else { return }
        stopsKey = key
        var list: [Stop] = landmarks.map { l in
            let p = course.local(lat: l.lat, lon: l.lon)
            return Stop(kind: .landmark, d: course.along(officialKm: l.km), focus: SIMD2(p.x, p.y), radius: l.estimatedRadius)
        }
        if mode.stations {
            for st in course.data.stations where (st.fluid && config.showFluid) || (st.fuel && config.showFuel) {
                list.append(Stop(kind: .station, d: course.along(officialKm: st.km), focus: nil, radius: 40))
            }
        }
        if mode.markers {
            let unit = config.units.kmPerUnit
            var k = 5.0
            while k * unit < course.data.distanceKm - 0.3 {
                list.append(Stop(kind: .marker, d: course.along(officialKm: k * unit), focus: nil, radius: 40))
                k += 5
            }
            if course.data.distanceKm > 40 {
                list.append(Stop(kind: .marker, d: course.length / 2, focus: nil, radius: 40))
            }
        }
        stops = list.sorted { $0.d < $1.d }
    }

    /// Ends a finished visit and starts the next one early enough that the
    /// runner reaches the stop in the middle of the slow part.
    private func updateVisit() {
        if let v = visit, time - v.start > Self.slowIn + v.stop.hold + Self.slowOut + Self.settle { visit = nil }
        guard visit == nil, config.slowDown != .off, config.camera != .overview else { return }
        refreshStops()
        let v = metresPerSecond
        guard let next = stops.first(where: { $0.d > distance }) else { return }
        let lead = v * Self.slowIn * (1 + next.slowest) / 2 + v * next.slowest * next.hold / 2
        if distance >= next.d - lead { visit = Visit(stop: next, start: time) }
    }

    /// Fraction of normal speed: eases down to a crawl, holds, eases back.
    private var speedFactor: Double {
        guard let v = visit else { return 1 }
        let t = time - v.start, m = v.stop.slowest, hold = v.stop.hold
        if t < Self.slowIn { return 1 - (1 - m) * smoothstep(t / Self.slowIn) }
        if t < Self.slowIn + hold { return m }
        return m + (1 - m) * smoothstep((t - Self.slowIn - hold) / Self.slowOut)
    }

    /// How far the camera has moved to frame the stop (0 normal … 1 framed).
    private var visitWeight: Double {
        guard let v = visit else { return 0 }
        let t = time - v.start
        return smoothstep(t / (Self.slowIn + 0.8))
            * (1 - smoothstep((t - Self.slowIn - v.stop.hold) / (Self.slowOut + Self.settle)))
    }

    /// The chase camera moved to show the stop: pulled back to fit a landmark
    /// and the runner together (further for big ones), with a slow sweep around
    /// it; closer in for stations and markers.
    private func framed(_ cam: CameraState, stop: Stop, since start: Double) -> CameraState {
        var out = cam
        let runner = SIMD2(cam.target.x, cam.target.y)
        switch stop.kind {
        case .landmark:
            let focus = stop.focus ?? runner
            let gap = simd_length(focus - runner)
            let centre = runner + (focus - runner) * 0.55
            let span = max(stop.radius * 2.6, gap * 1.3 + stop.radius * 1.4, 180)
            let fit = span / 2 / tan(Self.fieldOfView / 2) * 1.15
            out.target = SIMD3(centre.x, centre.y, cam.target.z)
            let c = course.coordinate(x: centre.x, y: centre.y)
            out.coordinate = CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon)
            out.distance = min(max(fit, 220), 4000)
            out.tilt = 52 * .pi / 180
            let total = Self.slowIn + stop.hold + Self.slowOut
            out.heading = wrapAngle(cam.heading + 0.45 * ((time - start) / total - 0.5))
        case .station:
            out.distance = cam.distance * 0.55
        case .marker:
            out.distance = cam.distance * 0.65
        }
        return out
    }

    private func updateHeading(dt: Double, moved: Double) {
        guard config.camera != .northUp else { heading = 0; return }
        let target = course.heading(at: distance)
        // Smooth over a distance that grows with camera height, plus a slow
        // time-based settle so the camera finishes turning when paused.
        let span = max(160, config.cameraDistance * 0.55)
        let alpha = 1 - exp(-(moved / span) - dt / 2.5)
        var delta = wrapAngle(target - heading) * alpha
        let maxStep = 45 * Double.pi / 180 * dt
        delta = min(max(delta, -maxStep), maxStep)
        heading = wrapAngle(heading + delta)
    }

    // MARK: - Camera

    private func chaseCamera() -> CameraState {
        let s = course.sample(at: distance)
        var tilt = config.tiltDegrees
        var distance = config.cameraDistance
        if config.autoTilt {
            // Dynamic tilt: on a long straight, a higher, more top-down view down
            // the road; through bends and short blocks, a lower, tilted flyover.
            tilt = 62 + (25 - 62) * straight
            distance *= 0.85 + (1.35 - 0.85) * straight
            // Among tall buildings a low camera loses the street (and the runner)
            // behind them: look down more steeply and sit higher.
            tilt = min(tilt, 62 - 40 * builtUp)
            distance *= 1 + 0.35 * builtUp
        }
        let cam = CameraState(target: SIMD3(s.x, s.y, s.ele), coordinate: s.coordinate, heading: heading,
                              tilt: tilt * .pi / 180, distance: distance)
        guard let v = visit, case let w = visitWeight, w > 0 else { return cam }
        return blend(cam, framed(cam, stop: v.stop, since: v.start), w)
    }

    /// How much buildings would hide the street from a low camera: mostly tall
    /// buildings, with a little for dense low-rise.
    private func crowding(atKm km: Double) -> Double {
        max(course.tallness(atKm: km) ?? 0, 0.4 * (course.density(atKm: km) ?? 0))
    }

    /// How straight the road is from just behind `d` to 800 m ahead: the
    /// straight-line distance over the distance along the road, mapped so that
    /// 1 is a long straight and 0 is bendy (corners, short blocks, turns).
    private func straightness(at d: Double) -> Double {
        if straightCourse != course.id {
            straightCourse = course.id
            let c = course
            straightProfile = stride(from: 0.0, through: c.length, by: Self.straightStep).map { x in
                let a = max(0, x - 100), b = min(c.length, x + 800)
                guard b - a > 50 else { return 1 }
                let p = c.sample(at: a), q = c.sample(at: b)
                let ratio = hypot(q.x - p.x, q.y - p.y) / (b - a)
                // Only very nearly straight counts (gentle curves are bends here),
                // which keeps city courses roughly half low, half top-down.
                return smoothstep((ratio - 0.93) / (0.995 - 0.93))
            }
        }
        guard !straightProfile.isEmpty else { return 0.5 }
        let f = min(max(d / Self.straightStep, 0), Double(straightProfile.count - 1))
        let i = Int(f), j = min(i + 1, straightProfile.count - 1)
        return straightProfile[i] + (straightProfile[j] - straightProfile[i]) * (f - Double(i))
    }

    private func overviewCamera(rotating: Bool) -> CameraState {
        let c = course
        let w = c.maxX - c.minX, h = c.maxY - c.minY
        // The view may be rotated to any heading, so fit the diagonal.
        let span = hypot(w, h)
        let tilt = min(config.tiltDegrees, 45) * .pi / 180
        let fit = (span / 2) / tan(Self.fieldOfView / 2) * (aspect < 1 ? 1 / aspect : 1) * 1.12
        let distance = max(fit, config.cameraDistance)
        let spin = rotating && config.camera != .northUp ? time * 0.03 : 0
        return CameraState(
            target: SIMD3((c.minX + c.maxX) / 2, (c.minY + c.maxY) / 2, (c.minEle + c.maxEle) / 2),
            coordinate: c.centerCoordinate,
            heading: wrapAngle((config.camera == .northUp ? 0 : heading) + spin),
            tilt: tilt, distance: distance)
    }

    private func updateCamera() {
        if config.camera == .overview {
            camera = overviewCamera(rotating: true)
            return
        }
        switch phase {
        case .intro:
            camera = blend(overviewCamera(rotating: false), chaseCamera(),
                           smoothstep((phaseTime - 1.2) / 5.3))
        case .running:
            camera = chaseCamera()
        case .finish:
            camera = blend(chaseCamera(), overviewCamera(rotating: false),
                           smoothstep((phaseTime - 1.5) / 5.0))
        case .fadeOut:
            camera = overviewCamera(rotating: false)
        }
    }

    private func blend(_ a: CameraState, _ b: CameraState, _ t: Double) -> CameraState {
        CameraState(
            target: a.target + (b.target - a.target) * t,
            coordinate: CLLocationCoordinate2D(
                latitude: a.coordinate.latitude + (b.coordinate.latitude - a.coordinate.latitude) * t,
                longitude: a.coordinate.longitude + (b.coordinate.longitude - a.coordinate.longitude) * t),
            heading: wrapAngle(a.heading + wrapAngle(b.heading - a.heading) * t),
            tilt: a.tilt + (b.tilt - a.tilt) * t,
            distance: exp(log(a.distance) + (log(b.distance) - log(a.distance)) * t))
    }

    // MARK: - Overlay timing

    /// Opacity of the course title card shown during the intro.
    var titleAlpha: Double {
        guard phase == .intro else { return 0 }
        return ramp(phaseTime, 0.5, 1.3) * (1 - ramp(phaseTime, 4.6, 5.8))
    }

    var finishAlpha: Double {
        switch phase {
        case .finish: return ramp(phaseTime, 0.4, 1.2) * (1 - ramp(phaseTime, 5.8, 6.8))
        default: return 0
        }
    }

    /// Black overlay used to cross-fade between courses.
    var fade: Double {
        switch phase {
        case .intro: return 1 - ramp(phaseTime, 0, 1.0)
        case .fadeOut: return ramp(phaseTime, 0, Self.fadeDuration)
        default: return 0
        }
    }

    /// Shows the HUD's live numbers only while the runner is on course.
    var hudAlpha: Double {
        switch phase {
        case .intro: return ramp(phaseTime, 5.6, 6.9)  // after the bottom title card fades
        case .running: return 1
        case .finish: return 1
        case .fadeOut: return 1 - ramp(phaseTime, 0, Self.fadeDuration)
        }
    }
}

func wrapAngle(_ a: Double) -> Double {
    var a = a.truncatingRemainder(dividingBy: 2 * .pi)
    if a > .pi { a -= 2 * .pi }
    if a < -.pi { a += 2 * .pi }
    return a
}

func smoothstep(_ t: Double) -> Double {
    let t = min(max(t, 0), 1)
    return t * t * (3 - 2 * t)
}

func ramp(_ v: Double, _ a: Double, _ b: Double) -> Double {
    smoothstep((v - a) / (b - a))
}
