import CoreLocation
import MapKit

/// Names the neighbourhood the runner is passing through, using Apple's
/// reverse geocoding. Lookups are throttled (one every ~350 m, never more than
/// one in flight) and cached on a ~300 m grid, so a replayed course costs nothing.
final class AreaNamer {
    private(set) var name: String?
    private(set) var previousName: String?
    private(set) var changedAt = 0.0

    private var cache: [String: String] = [:]
    private var lastQuery: CLLocation?
    private var lastQueryTime = 0.0
    private var inFlight = false
    private var courseID = ""

    /// Call every frame with the runner's position.
    func update(courseID id: String, coordinate: CLLocationCoordinate2D, now: Double) {
        if id != courseID {
            courseID = id
            set(nil, now: now)
            lastQuery = nil
        }
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let key = Self.cellKey(coordinate)
        if let cached = cache[key] {
            if cached != name { set(cached, now: now) }
            return
        }
        guard !inFlight, now - lastQueryTime > 1.5 else { return }
        if let last = lastQuery, last.distance(from: here) < 350, name != nil { return }
        inFlight = true
        lastQuery = here
        lastQueryTime = now
        Self.lookUp(here) { [weak self] result in
            guard let self else { return }
            self.inFlight = false
            guard let result else { return }
            self.cache[key] = result
            if self.courseID == id, result != self.name { self.set(result, now: CACurrentMediaTime()) }
        }
    }

    private func set(_ new: String?, now: Double) {
        previousName = name
        name = new
        changedAt = now
    }

    private static func cellKey(_ c: CLLocationCoordinate2D) -> String {
        "\(Int((c.latitude / 0.003).rounded())):\(Int((c.longitude / 0.004).rounded()))"
    }

    /// "Back Bay · Boston", or just "Brooklyn" when neighbourhood and city match.
    private static func caption(neighbourhood: String?, city: String?) -> String? {
        switch (neighbourhood?.nilIfEmpty, city?.nilIfEmpty) {
        case let (n?, c?):
            if c.localizedCaseInsensitiveContains(n) { return c }
            if n.localizedCaseInsensitiveContains(c) { return n }
            return "\(n) · \(c)"
        case let (n?, nil): return n
        case let (nil, c?): return c
        default: return nil
        }
    }

    private static func lookUp(_ location: CLLocation, completion: @escaping (String?) -> Void) {
        if #available(macOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location) else { completion(nil); return }
            request.getMapItems { items, _ in
                guard let item = items?.first else { completion(nil); return }
                // The neighbourhood (subLocality) is only exposed on the placemark.
                completion(caption(neighbourhood: item.placemark.subLocality,
                                   city: item.addressRepresentations?.cityName ?? item.placemark.locality))
            }
        } else {
            CLGeocoder().reverseGeocodeLocation(location) { placemarks, _ in
                let p = placemarks?.first
                DispatchQueue.main.async { completion(caption(neighbourhood: p?.subLocality, city: p?.locality)) }
            }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
