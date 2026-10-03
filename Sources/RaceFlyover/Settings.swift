import AppKit
import ScreenSaver

enum VisualStyle: String, CaseIterable {
    case satellitePlain, satellite, map, mapLight, midnight, neon, daylight, blueprint, mono

    var title: String {
        switch self {
        case .satellitePlain: return "Apple Maps Satellite"
        case .satellite: return "Apple Maps Satellite + labels"
        case .map: return "Apple Maps (Dark)"
        case .mapLight: return "Apple Maps (Light)"
        case .midnight: return "Midnight"
        case .neon: return "Neon Grid"
        case .daylight: return "Daylight"
        case .blueprint: return "Blueprint"
        case .mono: return "Minimal Mono"
        }
    }

    /// Styles that lay Apple Maps imagery under the route (needs internet).
    var usesTiles: Bool { [.satellitePlain, .satellite, .map, .mapLight].contains(self) }
}

enum CameraMode: String, CaseIterable {
    case chase, northUp, overview

    var title: String {
        switch self {
        case .chase: return "Chase"
        case .northUp: return "North up"
        case .overview: return "Overview"
        }
    }
}

enum HUDMode: String, CaseIterable {
    case full, minimal, off

    var title: String {
        switch self {
        case .full: return "Full"
        case .minimal: return "Minimal"
        case .off: return "Off"
        }
    }
}

enum PanelStyle: String, CaseIterable {
    case solid, glass, clearGlass

    var title: String {
        switch self {
        case .solid: return "Solid"
        case .glass: return "Liquid Glass"
        case .clearGlass: return "Liquid Glass (Clear)"
        }
    }

    /// Liquid Glass needs macOS 26 or later; older systems use solid panels.
    static var glassAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    var usesGlass: Bool { self != .solid && PanelStyle.glassAvailable }
}

enum Typeface: String, CaseIterable {
    case system, rounded, serif, mono, avenir, helvetica, futura, gillSans, din

    var title: String {
        switch self {
        case .system: return "SF Pro (System)"
        case .rounded: return "SF Pro Rounded"
        case .serif: return "New York (Serif)"
        case .mono: return "SF Mono"
        case .avenir: return "Avenir Next"
        case .helvetica: return "Helvetica Neue"
        case .futura: return "Futura"
        case .gillSans: return "Gill Sans"
        case .din: return "DIN Condensed"
        }
    }

    /// Font family name for non-system faces.
    var family: String? {
        switch self {
        case .avenir: return "Avenir Next"
        case .helvetica: return "Helvetica Neue"
        case .futura: return "Futura"
        case .gillSans: return "Gill Sans"
        case .din: return "DIN Condensed"
        default: return nil
        }
    }
}

enum Units: String, CaseIterable {
    case km, mi

    var metresPerUnit: Double { self == .km ? 1000 : 1609.344 }
    var kmPerUnit: Double { metresPerUnit / 1000 }
    var label: String { rawValue }
}

/// Snapshot of every user-facing option. The renderer reads this once per
/// change instead of hitting UserDefaults every frame.
struct Config: Equatable {
    var selection = "majors"          // "majors", "all", or "course:<id>"
    var lapMinutes = 15.0             // time to fly the whole course
    var camera = CameraMode.chase
    var tiltDegrees = 66.0            // 0 = straight down
    var zoom = 0.42                   // 0 = street level, 1 = whole city
    var style = VisualStyle.midnight
    var exaggeration = 4.0            // elevation multiplier for stylized styles
    var units = Units.km
    var hud = HUDMode.full
    var showFluid = true
    var showFuel = true
    var showMarkers = true
    var smooth60 = false
    var typeface = Typeface.system
    var textScale = 1.0               // overlay size multiplier
    var panels = PanelStyle.solid

    /// Camera distance in metres for the chase camera.
    var cameraDistance: Double { 220 * pow(36, zoom) }
}

final class Settings {
    static let didChange = Notification.Name("RaceFlyoverSettingsDidChange")

    let defaults: UserDefaults

    init() {
        let id = Bundle(for: Settings.self).bundleIdentifier ?? "com.raceflyover.saver"
        defaults = ScreenSaverDefaults(forModuleWithName: id) ?? .standard
    }

    var config: Config {
        get {
            var c = Config()
            if Locale.current.measurementSystem == .us { c.units = .mi }
            let d = defaults
            if let v = d.string(forKey: "selection") { c.selection = v }
            if d.object(forKey: "lapMinutes") != nil { c.lapMinutes = d.double(forKey: "lapMinutes") }
            if let v = d.string(forKey: "camera").flatMap(CameraMode.init) { c.camera = v }
            if d.object(forKey: "tilt") != nil { c.tiltDegrees = d.double(forKey: "tilt") }
            if d.object(forKey: "zoom") != nil { c.zoom = d.double(forKey: "zoom") }
            if let v = d.string(forKey: "style").flatMap(VisualStyle.init) { c.style = v }
            if d.object(forKey: "exaggeration") != nil { c.exaggeration = d.double(forKey: "exaggeration") }
            if let v = d.string(forKey: "units").flatMap(Units.init) { c.units = v }
            if let v = d.string(forKey: "hud").flatMap(HUDMode.init) { c.hud = v }
            if d.object(forKey: "showFluid") != nil { c.showFluid = d.bool(forKey: "showFluid") }
            if d.object(forKey: "showFuel") != nil { c.showFuel = d.bool(forKey: "showFuel") }
            if d.object(forKey: "showMarkers") != nil { c.showMarkers = d.bool(forKey: "showMarkers") }
            if d.object(forKey: "smooth60") != nil { c.smooth60 = d.bool(forKey: "smooth60") }
            if let v = d.string(forKey: "typeface").flatMap(Typeface.init) { c.typeface = v }
            if let v = d.string(forKey: "panels").flatMap(PanelStyle.init) { c.panels = v }
            if d.object(forKey: "textScale") != nil { c.textScale = min(max(d.double(forKey: "textScale"), 0.6), 1.6) }
            return c
        }
        set {
            let d = defaults
            d.set(newValue.selection, forKey: "selection")
            d.set(newValue.lapMinutes, forKey: "lapMinutes")
            d.set(newValue.camera.rawValue, forKey: "camera")
            d.set(newValue.tiltDegrees, forKey: "tilt")
            d.set(newValue.zoom, forKey: "zoom")
            d.set(newValue.style.rawValue, forKey: "style")
            d.set(newValue.exaggeration, forKey: "exaggeration")
            d.set(newValue.units.rawValue, forKey: "units")
            d.set(newValue.hud.rawValue, forKey: "hud")
            d.set(newValue.showFluid, forKey: "showFluid")
            d.set(newValue.showFuel, forKey: "showFuel")
            d.set(newValue.showMarkers, forKey: "showMarkers")
            d.set(newValue.smooth60, forKey: "smooth60")
            d.set(newValue.typeface.rawValue, forKey: "typeface")
            d.set(newValue.panels.rawValue, forKey: "panels")
            d.set(newValue.textScale, forKey: "textScale")
            d.synchronize()
            NotificationCenter.default.post(name: Settings.didChange, object: nil)
        }
    }

    /// Courses imported from GPX through the Options sheet.
    var importedCourses: [CourseData] {
        get {
            guard let data = defaults.data(forKey: "importedCourses") else { return [] }
            return (try? JSONDecoder().decode([CourseData].self, from: data)) ?? []
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: "importedCourses")
            defaults.synchronize()
            CourseLibrary.invalidate()
            NotificationCenter.default.post(name: Settings.didChange, object: nil)
        }
    }
}

/// Bundled courses (JSON built by tools/build_courses.py, plus any GPX files
/// dropped into Resources/Courses at build time) and GPX imports.
enum CourseLibrary {
    private static var cache: [Course]?

    static func invalidate() { cache = nil }

    static func all(settings: Settings) -> [Course] {
        if let cache { return cache }
        var result: [Course] = []
        let bundle = Bundle(for: Settings.self)
        if let dir = bundle.resourceURL?.appendingPathComponent("Courses"),
           let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let data = try? Data(contentsOf: url) else { continue }
                var course: CourseData?
                switch url.pathExtension.lowercased() {
                case "json": course = try? JSONDecoder().decode(CourseData.self, from: data)
                case "gpx": course = try? GPXImporter.course(fromGPX: data, fileName: url.lastPathComponent)
                default: break
                }
                if let course, let c = Course(data: course) { result.append(c) }
            }
        }
        result += settings.importedCourses.compactMap(Course.init)
        result.sort { a, b in
            if a.isImported != b.isImported { return !a.isImported }
            if a.isMajor != b.isMajor { return a.isMajor }
            return a.name < b.name
        }
        cache = result
        return result
    }

    static func playlist(for selection: String, settings: Settings) -> [Course] {
        let courses = all(settings: settings)
        if selection.hasPrefix("course:") {
            let id = String(selection.dropFirst("course:".count))
            if let c = courses.first(where: { $0.id == id }) { return [c] }
        }
        if selection == "all" { return courses }
        let majors = courses.filter(\.isMajor)
        return majors.isEmpty ? courses : majors
    }
}
