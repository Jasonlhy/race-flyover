import CoreLocation
import MapKit
import os

struct Landmark: Codable, Equatable {
    var name: String
    var lat: Double
    var lon: Double
    /// Official race kilometre of the closest point on the route.
    var km: Double

    /// Rough radius in metres, guessed from the name (Apple Maps doesn't give a
    /// landmark's size): parks and palaces are big, statues small.
    var estimatedRadius: Double {
        let n = name.lowercased()
        let words = n.split(whereSeparator: { !$0.isLetter }).map(String.init)
        func has(_ list: [String]) -> Bool { list.contains { k in words.contains(k) || (k.count > 5 && n.contains(k)) } }
        if has(["park", "garden", "gardens", "palace", "castle", "stadium", "bridge", "lake", "river", "common",
                "harbour", "harbor", "square", "plaza", "zoo", "university", "campus", "cemetery", "forest", "circuit"]) { return 320 }
        if has(["statue", "monument", "column", "fountain", "arch", "memorial", "obelisk", "clock", "sculpture", "bell"]) { return 45 }
        return 120
    }
}

/// Finds famous landmarks along a course with Apple Maps.
///
/// MapKit's points-of-interest data has no notion of fame (statues and plaques
/// sit alongside Tower Bridge), so curated courses list their landmarks by name
/// and MapKit only resolves where each one is. Other courses (and GPX imports)
/// fall back to a filtered points-of-interest search along the route. Results
/// are cached on disk per course.
final class LandmarkStore {
    static let shared = LandmarkStore()
    private static let log = Logger(subsystem: "com.raceflyover", category: "landmarks")

    private var results: [String: [Landmark]] = [:]
    private var inFlight = Set<String>()
    private let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("RaceFlyoverLandmarks", isDirectory: true)

    /// Landmarks for `course` if known; otherwise starts resolving them.
    func landmarks(for course: Course) -> [Landmark] {
        if let r = results[course.id] { return r }
        if let cached = load(course) {
            results[course.id] = cached
            return cached
        }
        resolve(course)
        return []
    }

    /// Stable across launches (Swift's hashValue isn't), so the disk cache is found again.
    private func cacheKey(_ c: Course) -> String {
        var h: UInt32 = 5381
        for b in (c.data.landmarks ?? []).joined(separator: "|").utf8 { h = (h &* 33) ^ UInt32(b) }
        return "\(c.id)-\(String(h, radix: 16))-v1"
    }

    private func load(_ course: Course) -> [Landmark]? {
        guard let url = dir?.appendingPathComponent(cacheKey(course) + ".json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([Landmark].self, from: data)
    }

    private func save(_ course: Course, _ list: [Landmark]) {
        guard let dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(list).write(to: dir.appendingPathComponent(cacheKey(course) + ".json"))
    }

    private func resolve(_ course: Course) {
        guard !inFlight.contains(course.id) else { return }
        inFlight.insert(course.id)
        let curated = !(course.data.landmarks ?? []).isEmpty
        let finish: ([Landmark]) -> Void = { [weak self] found in
            guard let self else { return }
            // Keep landmarks in race order and not crowded together (searched ones
            // more sparsely, and at most ten).
            let spacing = curated ? 0.0 : 2.0
            var picked: [Landmark] = []
            for l in found.sorted(by: { $0.km < $1.km }) where !picked.contains(where: {
                $0.name == l.name || (spacing > 0 && abs($0.km - l.km) < spacing)
            }) {
                if curated || picked.count < 10 { picked.append(l) }
            }
            self.results[course.id] = picked
            self.inFlight.remove(course.id)
            if !found.isEmpty { self.save(course, picked) }
            Self.log.notice("\(course.id, privacy: .public): \(picked.count) landmarks — \(picked.map(\.name).joined(separator: ", "), privacy: .public)")
        }
        if curated, let names = course.data.landmarks {
            resolveNamed(names, course: course, found: [], completion: finish)
        } else {
            searchAlong(course, completion: finish)
        }
    }

    /// Distance (m) from a coordinate to the route, and the official km there.
    private func nearest(_ c: CLLocationCoordinate2D, on course: Course) -> (Double, Double) {
        let p = course.local(lat: c.latitude, lon: c.longitude)
        var best = Double.infinity, bestIndex = 0
        for i in stride(from: 0, to: course.x.count, by: 2) {
            let d = hypot(course.x[i] - p.x, course.y[i] - p.y)
            if d < best { best = d; bestIndex = i }
        }
        return (best, course.officialKm(at: course.cum[bestIndex]))
    }

    private var routeRegion: (Course) -> MKCoordinateRegion = { c in
        let pad = 2000.0
        let sw = c.coordinate(x: c.minX - pad, y: c.minY - pad), ne = c.coordinate(x: c.maxX + pad, y: c.maxY + pad)
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (sw.lat + ne.lat) / 2, longitude: (sw.lon + ne.lon) / 2),
                                  span: MKCoordinateSpan(latitudeDelta: ne.lat - sw.lat, longitudeDelta: ne.lon - sw.lon))
    }

    /// Looks names up one at a time (MapKit rate-limits searches).
    private func resolveNamed(_ names: [String], course: Course, found: [Landmark], completion: @escaping ([Landmark]) -> Void) {
        guard let name = names.first else { completion(found); return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = name
        request.region = routeRegion(course)
        request.resultTypes = .pointOfInterest
        MKLocalSearch(request: request).start { [weak self] response, _ in
            guard let self else { return }
            var next = found
            let candidates = (response?.mapItems ?? []).prefix(5)
            if let match = candidates.map({ ($0, self.nearest($0.placemark.coordinate, on: course)) })
                .filter({ $0.1.0 < 900 }).min(by: { $0.1.0 < $1.1.0 }) {
                let c = match.0.placemark.coordinate
                next.append(Landmark(name: name, lat: c.latitude, lon: c.longitude, km: match.1.1))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.resolveNamed(Array(names.dropFirst()), course: course, found: next, completion: completion)
            }
        }
    }

    private static let noise = ["statue", "plaque", "award", "scavenger", "hunt", "site of", "residence", "bust",
                                "sculpture", "office", "entrance", "information", "memorial stone", "marker"]

    /// Fallback: notable points of interest within ~300 m of the route.
    private func searchAlong(_ course: Course, completion: @escaping ([Landmark]) -> Void) {
        let samples = stride(from: 0.0, to: course.length, by: 3500).map { course.sample(at: $0).coordinate }
        var found: [Landmark] = []
        func step(_ i: Int) {
            guard i < samples.count else { completion(found); return }
            let request = MKLocalPointsOfInterestRequest(center: samples[i], radius: 700)
            let categories: [MKPointOfInterestCategory]
            if #available(macOS 15.0, *) {
                categories = [.landmark, .nationalMonument, .castle, .fortress, .stadium]
            } else {
                categories = [.museum, .stadium]
            }
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: categories)
            MKLocalSearch(request: request).start { [weak self] response, _ in
                guard let self else { return }
                for item in (response?.mapItems ?? []).prefix(6) {
                    guard let name = item.name, name.count <= 40,
                          !Self.noise.contains(where: { name.lowercased().contains($0) }) else { continue }
                    let (d, km) = self.nearest(item.placemark.coordinate, on: course)
                    if d < 300 { found.append(Landmark(name: name, lat: item.placemark.coordinate.latitude,
                                                       lon: item.placemark.coordinate.longitude, km: km)) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { step(i + 1) }
            }
        }
        step(0)
    }
}
