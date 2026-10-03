import AppKit
import ObjectiveC

/// MapKit stops rendering, and removes its Metal surface, whenever its window
/// reports that it isn't visible. The screensaver host's window reports exactly
/// that even while the screensaver is on screen, so a live map goes grey.
///
/// For windows that host a live map, this reports the window (and the app) as
/// visible, which is true while the screensaver runs. Every other window keeps
/// its real occlusion state.
enum MapVisibility {
    private static var installed = false
    private static var windows = NSHashTable<NSWindow>.weakObjects()

    static func forceVisible(_ window: NSWindow) {
        installIfNeeded()
        guard !windows.contains(window) else { return }
        windows.add(window)
        // Let MapKit re-evaluate now rather than on the next real change.
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        NotificationCenter.default.post(name: NSApplication.didChangeOcclusionStateNotification, object: NSApp)
    }

    static func release(_ window: NSWindow?) {
        guard let window else { return }
        windows.remove(window)
    }

    static func isForced(_ window: NSWindow) -> Bool { windows.contains(window) }
    static var anyForced: Bool { windows.count > 0 }

    private static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        swap(NSWindow.self, #selector(getter: NSWindow.occlusionState), #selector(getter: NSWindow.rf_occlusionState))
        swap(NSApplication.self, #selector(getter: NSApplication.occlusionState),
             #selector(getter: NSApplication.rf_occlusionState))
    }

    private static func swap(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let a = class_getInstanceMethod(cls, original), let b = class_getInstanceMethod(cls, replacement) else { return }
        method_exchangeImplementations(a, b)
    }
}

extension NSWindow {
    /// After the swap this runs for `occlusionState`; calling `rf_occlusionState`
    /// inside reaches the original implementation.
    @objc dynamic var rf_occlusionState: NSWindow.OcclusionState {
        MapVisibility.isForced(self) ? [.visible] : rf_occlusionState
    }
}

extension NSApplication {
    @objc dynamic var rf_occlusionState: NSApplication.OcclusionState {
        MapVisibility.anyForced ? [.visible] : rf_occlusionState
    }
}
