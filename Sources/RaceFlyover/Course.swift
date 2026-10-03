import CoreLocation
import Foundation

/// An aid station along the course, positioned by official race distance.
struct Station: Codable, Hashable {
    var km: Double
    var fluid: Bool
    var fuel: Bool
    var label: String
}

/// On-disk course format (bundled JSON, or GPX converted on import).
struct CourseData: Codable {
    var id: String
    var name: String
    var city: String
    var month: String?
    var major: Bool?
    var distanceKm: Double
    var source: String?
    var stationsEstimated: Bool?
    var imported: Bool?
    /// ISO 3166-1 alpha-2 country code, for the flag in the HUD.
    var country: String?
    /// Famous landmarks along the route, by name; resolved with Apple Maps at runtime.
    var landmarks: [String]?
    var stations: [Station]
    /// `[latitude, longitude, elevation metres]`, evenly spaced along the route.
    var points: [[Double]]
}

struct CourseSample {
    var x: Double
    var y: Double
    var ele: Double
    var coordinate: CLLocationCoordinate2D
}

/// A course prepared for animation: local metric coordinates, cumulative
/// distance, and an elevation profile.
final class Course {
    let data: CourseData
    let x: [Double]
    let y: [Double]
    let ele: [Double]
    let lat: [Double]
    let lon: [Double]
    let cum: [Double]
    let length: Double
    let minEle: Double
    let maxEle: Double
    let elevationGain: Double
    let minX: Double, maxX: Double, minY: Double, maxY: Double
    /// Origin of the local metric frame (x east, y north).
    let lat0: Double, lon0: Double
    private static let metresPerDegree = Double.pi / 180 * 6_371_008.8
    /// Evenly spaced elevation samples for drawing the profile strip.
    let profile: [Double]

    var id: String { data.id }
    var name: String { data.name }
    var isMajor: Bool { data.major ?? false }
    var isImported: Bool { data.imported ?? false }
    var fluidStations: Int { data.stations.filter(\.fluid).count }
    var fuelStations: Int { data.stations.filter(\.fuel).count }

    init?(data: CourseData) {
        let pts = data.points.filter { $0.count >= 2 }
        guard pts.count >= 2 else { return nil }
        self.data = data
        let lat0 = pts.map { $0[0] }.reduce(0, +) / Double(pts.count)
        let lon0 = pts.map { $0[1] }.reduce(0, +) / Double(pts.count)
        self.lat0 = lat0
        self.lon0 = lon0
        let k = Course.metresPerDegree
        let cosLat = cos(lat0 * .pi / 180)
        lat = pts.map { $0[0] }
        lon = pts.map { $0[1] }
        x = pts.map { ($0[1] - lon0) * cosLat * k }
        y = pts.map { ($0[0] - lat0) * k }
        ele = pts.map { $0.count > 2 ? $0[2] : 0 }

        var c: [Double] = [0]
        c.reserveCapacity(pts.count)
        for i in 1..<pts.count {
            c.append(c[i - 1] + hypot(x[i] - x[i - 1], y[i] - y[i - 1]))
        }
        cum = c
        length = max(c.last ?? 1, 1)
        minEle = ele.min() ?? 0
        maxEle = ele.max() ?? 0
        minX = x.min()!; maxX = x.max()!
        minY = y.min()!; maxY = y.max()!

        var gain = 0.0
        for i in 1..<ele.count where ele[i] > ele[i - 1] {
            gain += ele[i] - ele[i - 1]
        }
        elevationGain = gain

        let n = 480
        var prof: [Double] = []
        prof.reserveCapacity(n)
        // Inline sampling (methods are unavailable before init completes).
        var j = 0
        for s in 0..<n {
            let d = Double(s) / Double(n - 1) * length
            while j < c.count - 2 && c[j + 1] < d { j += 1 }
            let seg = c[j + 1] - c[j]
            let t = seg > 0 ? min(max((d - c[j]) / seg, 0), 1) : 0
            prof.append(ele[j] + (ele[j + 1] - ele[j]) * t)
        }
        profile = prof
    }

    /// Converts between latitude/longitude and the course's local metric frame.
    func local(lat: Double, lon: Double) -> (x: Double, y: Double) {
        ((lon - lon0) * cos(lat0 * .pi / 180) * Course.metresPerDegree, (lat - lat0) * Course.metresPerDegree)
    }

    func coordinate(x: Double, y: Double) -> (lat: Double, lon: Double) {
        (lat0 + y / Course.metresPerDegree, lon0 + x / (cos(lat0 * .pi / 180) * Course.metresPerDegree))
    }

    /// Flag emoji for the course's country, if known.
    var flag: String? {
        guard let code = data.country?.uppercased(), code.count == 2 else { return nil }
        let scalars = code.unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Index of the segment containing distance `d` and the fraction along it.
    func locate(_ d: Double) -> (Int, Double) {
        let d = min(max(d, 0), length)
        var lo = 0, hi = cum.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cum[mid] <= d { lo = mid } else { hi = mid }
        }
        let seg = cum[hi] - cum[lo]
        return (lo, seg > 0 ? (d - cum[lo]) / seg : 0)
    }

    func sample(at d: Double) -> CourseSample {
        let (i, t) = locate(d)
        let j = min(i + 1, x.count - 1)
        return CourseSample(
            x: x[i] + (x[j] - x[i]) * t,
            y: y[i] + (y[j] - y[i]) * t,
            ele: ele[i] + (ele[j] - ele[i]) * t,
            coordinate: CLLocationCoordinate2D(latitude: lat[i] + (lat[j] - lat[i]) * t,
                                               longitude: lon[i] + (lon[j] - lon[i]) * t))
    }

    /// Direction of travel around `d` (radians clockwise from north), looking a
    /// little behind and ahead so single kinks don't jerk the camera.
    func heading(at d: Double, behind: Double = 120, ahead: Double = 320) -> Double {
        let a = sample(at: max(0, d - behind))
        let b = sample(at: min(length, d + ahead))
        if hypot(b.x - a.x, b.y - a.y) < 1 { return 0 }
        return atan2(b.x - a.x, b.y - a.y)
    }

    /// Converts traced metres to official race kilometres and back. GPS traces
    /// usually run a little long, so markers are scaled to the official distance.
    func officialKm(at d: Double) -> Double { d / length * data.distanceKm }
    func along(officialKm km: Double) -> Double { km / data.distanceKm * length }

    func elevation(at d: Double) -> Double { sample(at: d).ele }

    /// Gradient in percent over the next ~100 m.
    func grade(at d: Double) -> Double {
        let a = max(0, d - 50), b = min(length, d + 50)
        guard b - a > 1 else { return 0 }
        return (elevation(at: b) - elevation(at: a)) / (b - a) * 100
    }

    var centerCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: (lat.min()! + lat.max()!) / 2,
                               longitude: (lon.min()! + lon.max()!) / 2)
    }
}
