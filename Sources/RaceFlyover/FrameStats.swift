import Foundation
import QuartzCore
import os

/// Rolling frame-timing statistics, logged every few seconds to the unified log
/// (subsystem com.raceflyover, category perf) so slow frames can be diagnosed
/// inside the screensaver host.
final class FrameStats {
    static let shared = FrameStats()
    private static let log = Logger(subsystem: "com.raceflyover", category: "perf")

    private var intervals: [Double] = []
    private var timings: [String: [Double]] = [:]
    private var lastReport = CACurrentMediaTime()

    func frame(interval: Double) { intervals.append(interval) }

    func measure<T>(_ name: String, _ work: () -> T) -> T {
        let start = CACurrentMediaTime()
        let result = work()
        timings[name, default: []].append((CACurrentMediaTime() - start) * 1000)
        return result
    }

    func reportIfDue(label: String) {
        let now = CACurrentMediaTime()
        guard now - lastReport >= 5, !intervals.isEmpty else { return }
        let elapsed = now - lastReport
        lastReport = now
        let fps = Double(intervals.count) / elapsed
        let worst = (intervals.max() ?? 0) * 1000
        let slow = intervals.filter { $0 > 0.05 }.count
        var parts = [String(format: "%@ fps=%.1f worstGap=%.0fms slowFrames=%d", label, fps, worst, slow)]
        for (name, values) in timings.sorted(by: { $0.key < $1.key }) {
            let avg = values.reduce(0, +) / Double(values.count)
            parts.append(String(format: "%@ avg=%.1fms max=%.1fms", name, avg, values.max() ?? 0))
        }
        Self.log.notice("\(parts.joined(separator: " | "), privacy: .public)")
        intervals.removeAll(keepingCapacity: true)
        timings.removeAll(keepingCapacity: true)
    }
}
