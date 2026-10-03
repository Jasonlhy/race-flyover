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
        distance = 0
        phase = .intro
        phaseTime = 0
        heading = config.camera == .northUp ? 0 : course.heading(at: 0, behind: 0, ahead: 600)
        updateCamera()
    }

    /// Jumps straight into the run at `fraction` of the course (for previews).
    func seek(fraction: Double) {
        distance = min(max(fraction, 0), 1) * course.length
        phase = .running
        phaseTime = 0
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
        updateCamera()
    }

    /// Moves the runner by `metres` (preview app arrow keys).
    func jump(by metres: Double) {
        if phase != .running { phase = .running; phaseTime = 0 }
        distance = min(max(distance + metres, 0), course.length - 1)
    }

    /// Shows the intro/finish sequences at a given moment (preview snapshots).
    func show(phase newPhase: Phase, at t: Double) {
        if newPhase == .finish { distance = course.length }
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
            if phaseTime >= Self.introDuration { phase = .running; phaseTime = 0 }
        case .running:
            moved = metresPerSecond * dt
            distance += moved
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
        updateHeading(dt: dt, moved: moved)
        updateCamera()
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
        return CameraState(target: SIMD3(s.x, s.y, s.ele), coordinate: s.coordinate, heading: heading,
                           tilt: config.tiltDegrees * .pi / 180, distance: config.cameraDistance)
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
