import Foundation

/// Converts a GPX file (track or route, with optional waypoints for aid
/// stations) into `CourseData`.
enum GPXImporter {
    enum ImportError: LocalizedError {
        case noTrack
        var errorDescription: String? { "The file has no track or route points." }
    }

    static let resampleMetres = 25.0

    static func course(fromGPX data: Data, fileName: String) throws -> CourseData {
        let parser = Parser()
        let xml = XMLParser(data: sanitized(data))
        xml.delegate = parser
        xml.parse()
        let raw = parser.track.isEmpty ? parser.route : parser.track
        guard raw.count >= 2 else { throw ImportError.noTrack }

        let (pts, total) = resample(raw)
        let hasElevation = raw.contains { $0.ele != nil }
        var eles = pts.map { $0.ele ?? 0 }
        if hasElevation { eles = smooth(eles, radius: 3) }

        let km = total / 1000
        let official: Double
        if (41.4...43.6).contains(km) { official = 42.195 }
        else if (20.6...21.8).contains(km) { official = 21.0975 }
        else { official = (km * 100).rounded() / 100 }

        // Waypoints usually come in race order; matching forward from the previous
        // station keeps out-and-back sections on the right leg.
        var lastAlong = 0.0
        var stations = parser.waypoints.compactMap { wp -> Station? in
            guard let kind = classify(name: wp.name, desc: wp.desc),
                  let along = project(lat: wp.lat, lon: wp.lon, onto: pts, after: max(0, lastAlong - 300))
                    ?? project(lat: wp.lat, lon: wp.lon, onto: pts, after: 0) else { return nil }
            lastAlong = along
            return Station(km: along / total * official, fluid: kind.fluid, fuel: kind.fuel, label: kind.label)
        }
        .sorted { $0.km < $1.km }

        var estimated = false
        if stations.isEmpty && official >= 10 {
            estimated = true
            stations = stride(from: 5.0, to: official, by: 5.0).map {
                Station(km: $0, fluid: true, fuel: false, label: "Refreshments (typical)")
            }
        }

        let base = (fileName as NSString).deletingPathExtension
        let name = parser.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? base
        return CourseData(
            id: "gpx-" + base.lowercased().replacingOccurrences(of: " ", with: "-"),
            name: name,
            city: "Imported from \(fileName)",
            month: nil,
            major: false,
            distanceKm: official,
            source: fileName,
            stationsEstimated: estimated,
            imported: true,
            stations: stations,
            points: zip(pts, eles).map { [$0.lat, $0.lon, ($1 * 10).rounded() / 10] })
    }

    /// Escapes stray ampersands, which some exporters leave in waypoint names
    /// and which otherwise abort XML parsing.
    static func sanitized(_ data: Data) -> Data {
        guard var text = String(data: data, encoding: .utf8), text.contains("&") else { return data }
        let pattern = "&(?!(amp|lt|gt|quot|apos|#[0-9]+|#x[0-9a-fA-F]+);)"
        text = text.replacingOccurrences(of: pattern, with: "&amp;", options: .regularExpression)
        return Data(text.utf8)
    }

    // MARK: - Classification (mirrors tools/build_courses.py)

    private static let fuelWords = ["gel", "maurten", "gu ", "shot", "banana", "food", "bread", "candy",
                                    "chocolate", "orange", "fruit", "energy", "fuel", "carb"]
    private static let fluidWords = ["water", "gatorade", "drink", "electrolyte", "fluid", "refreshment",
                                     "isotonic", "sports drink", "aid", "sponge", "hydration", "food"]

    static func classify(name: String, desc: String) -> (fluid: Bool, fuel: Bool, label: String)? {
        let text = " \(name) \(desc) ".lowercased()
        let fuel = fuelWords.contains { text.contains($0) }
        let fluid = fluidWords.contains { text.contains($0) }
        guard fuel || fluid else { return nil }
        let label = desc.isEmpty || desc == name ? name : desc
        return (fluid, fuel, label.isEmpty ? (fuel ? "Fuel" : "Fluids") : label)
    }

    // MARK: - Geometry

    struct Point { var lat: Double; var lon: Double; var ele: Double? }

    static func distance(_ a: Point, _ b: Point) -> Double {
        let r = 6_371_008.8
        let la1 = a.lat * .pi / 180, la2 = b.lat * .pi / 180
        let dla = la2 - la1, dlo = (b.lon - a.lon) * .pi / 180
        let h = sin(dla / 2) * sin(dla / 2) + cos(la1) * cos(la2) * sin(dlo / 2) * sin(dlo / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    static func resample(_ raw: [Point]) -> ([Point], Double) {
        var pts = [raw[0]]
        for p in raw.dropFirst() where distance(p, pts[pts.count - 1]) > 0.5 { pts.append(p) }
        var cum = [0.0]
        for i in 1..<pts.count { cum.append(cum[i - 1] + distance(pts[i - 1], pts[i])) }
        let total = cum.last ?? 0
        guard pts.count >= 2, total > 0 else { return (pts, total) }
        var out: [Point] = []
        var j = 0
        var s = 0.0
        while s < total {
            while cum[j + 1] < s { j += 1 }
            let seg = cum[j + 1] - cum[j]
            let t = seg > 0 ? (s - cum[j]) / seg : 0
            let a = pts[j], b = pts[j + 1]
            var ele: Double?
            if let ea = a.ele, let eb = b.ele { ele = ea + (eb - ea) * t }
            out.append(Point(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t, ele: ele))
            s += resampleMetres
        }
        out.append(pts[pts.count - 1])
        return (out, total)
    }

    static func smooth(_ v: [Double], radius: Int) -> [Double] {
        v.indices.map { i in
            let lo = max(0, i - radius), hi = min(v.count, i + radius + 1)
            return v[lo..<hi].reduce(0, +) / Double(hi - lo)
        }
    }

    /// Distance along `pts` of the closest point at or beyond `after` metres, if within 400 m.
    static func project(lat: Double, lon: Double, onto pts: [Point], after: Double) -> Double? {
        let target = Point(lat: lat, lon: lon, ele: nil)
        var best = Double.infinity, bestIndex = 0
        let start = min(pts.count - 1, Int(after / resampleMetres))
        for (i, p) in pts.enumerated().dropFirst(start) {
            let d = distance(p, target)
            if d < best { best = d; bestIndex = i }
        }
        guard best < 400 else { return nil }
        return Double(bestIndex) * resampleMetres
    }

    // MARK: - XML

    private final class Parser: NSObject, XMLParserDelegate {
        struct Waypoint { var lat: Double; var lon: Double; var name = ""; var desc = "" }
        var track: [Point] = []
        var route: [Point] = []
        var waypoints: [Waypoint] = []
        var name: String?

        private var current: Point?
        private var currentKind = ""
        private var currentWaypoint: Waypoint?
        private var text = ""
        private var depthInTrack = false

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            let el = element.lowercased()
            let lat = Double(attributes["lat"] ?? "")
            let lon = Double(attributes["lon"] ?? "")
            switch el {
            case "trkpt", "rtept":
                if let lat, let lon { current = Point(lat: lat, lon: lon, ele: nil); currentKind = el }
            case "wpt":
                if let lat, let lon { currentWaypoint = Waypoint(lat: lat, lon: lon) }
            case "trk", "rte":
                depthInTrack = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                    qualifiedName: String?) {
            let el = element.lowercased()
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch el {
            case "ele":
                if current != nil { current?.ele = Double(value) }
            case "name":
                if currentWaypoint != nil { currentWaypoint?.name = value }
                else if current == nil, name == nil, !value.isEmpty { name = value }
            case "desc", "cmt", "type", "sym":
                if currentWaypoint != nil, !value.isEmpty {
                    let existing = currentWaypoint!.desc
                    currentWaypoint?.desc = existing.isEmpty ? value : existing + ", " + value
                }
            case "trkpt", "rtept":
                if let p = current { if currentKind == "trkpt" { track.append(p) } else { route.append(p) } }
                current = nil
            case "wpt":
                if let w = currentWaypoint { waypoints.append(w) }
                currentWaypoint = nil
            default: break
            }
            text = ""
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
