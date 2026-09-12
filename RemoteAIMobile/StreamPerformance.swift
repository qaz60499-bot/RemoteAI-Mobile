import Foundation
import UIKit

// Bounded numeric samples only. No message content, per-delta file I/O, or
// synchronous full-stream encoding is needed to measure the active row.
struct StreamDurationSamples {
    private var values: [Double] = []
    private(set) var count = 0
    private(set) var maximum = 0.0

    mutating func add(_ milliseconds: Double) {
        count += 1
        maximum = max(maximum, milliseconds)
        if values.count < 4096 { values.append(milliseconds) }
        else { values[(count - 1) % 4096] = milliseconds }
    }

    func fields(_ prefix: String) -> [String: String] {
        let sorted = values.sorted()
        func percentile(_ p: Double) -> String {
            guard !sorted.isEmpty else { return "unmeasured" }
            return String(format: "%.3f", sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))])
        }
        return [prefix + "Count": String(count), prefix + "P50Ms": percentile(0.50),
                prefix + "P95Ms": percentile(0.95), prefix + "MaxMs": String(format: "%.3f", maximum)]
    }
}

final class StreamPerformance: NSObject {
    // CADisplayLink is diagnostic instrumentation, not part of the rendering path.
    // Keeping a 60 Hz display link alive for an entire long generation prevents the
    // main run loop from becoming quiescent and adds avoidable work to production.
    // CI's dedicated performance sampler opts in explicitly when frame metrics are
    // required; normal app/UI-test streaming only records event-driven timings.
    private static var frameSamplingEnabled: Bool {
        ProcessInfo.processInfo.environment["REMOTEAI_STREAM_FRAME_SAMPLING"] == "1"
    }
    var merge = StreamDurationSamples()
    var apply = StreamDurationSamples()
    var preparation = StreamDurationSamples()
    var flushToFrame = StreamDurationSamples()
    var frameIntervals = StreamDurationSamples()
    private var visibleUpdateIntervals = StreamDurationSamples()
    private var lastVisibleUpdate: Double?
    private var lastVisibleBytes: Int?
    private var firstDeltaMs: Double?
    let beganAt = ProcessInfo.processInfo.systemUptime
    private var displayLink: CADisplayLink?
    private var previousFrame: CFTimeInterval?
    private var pendingFlush: CFTimeInterval?
    private var firstVisibleMs: Double?
    private var frameSeconds = 0.0
    private var frameCount = 0
    private var stallCount = 0

    static var now: Double { ProcessInfo.processInfo.systemUptime }

    func receivedDelta() {
        if firstDeltaMs == nil { firstDeltaMs = (Self.now - beganAt) * 1000 }
    }

    func rowUpdated(bytes: Int) {
        guard bytes != lastVisibleBytes else { return }
        let now = Self.now
        if let previous = lastVisibleUpdate { visibleUpdateIntervals.add((now - previous) * 1000) }
        lastVisibleUpdate = now
        lastVisibleBytes = bytes
    }

    func published() {
        if pendingFlush == nil { pendingFlush = Self.now }
    }

    func startFrames() {
        guard Self.frameSamplingEnabled, displayLink == nil else { return }
        previousFrame = nil
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stopFrames() {
        displayLink?.invalidate()
        displayLink = nil
        previousFrame = nil
        pendingFlush = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = Self.now
        if firstVisibleMs == nil { firstVisibleMs = (now - beganAt) * 1000 }
        if let pendingFlush {
            flushToFrame.add((now - pendingFlush) * 1000)
            self.pendingFlush = nil
        }
        if let previousFrame {
            let seconds = now - previousFrame
            frameIntervals.add(seconds * 1000)
            frameSeconds += seconds
            frameCount += 1
            if seconds > 0.1 { stallCount += 1 }
        }
        previousFrame = now
    }

    func summary() -> [String: String] {
        var result = ["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                      "durationMs": String(format: "%.3f", (Self.now - beganAt) * 1000),
                      "firstVisibleMs": firstVisibleMs.map { String(format: "%.3f", $0) } ?? "unmeasured",
                      "firstDeltaAfterStreamInitMs": firstDeltaMs.map { String(format: "%.3f", $0) } ?? "unmeasured",
                      "visibleCadenceDefinition": "row body observes a changed byte count; includes offscreen intervals",
                      "callbackFPS": frameSeconds > 0 ? String(format: "%.2f", Double(frameCount) / frameSeconds) : "unmeasured",
                      "mainThreadStallsOver100Ms": String(stallCount),
                      "renderDefinition": "preparation and flush-to-display-link; GPU render measured externally",
                      "percentileWindow": "last 4096 samples; max covers entire stream"]
        for fields in [merge.fields("merge"), apply.fields("apply"), preparation.fields("preparation"),
                       flushToFrame.fields("flushToFrame"), frameIntervals.fields("frameInterval"),
                       visibleUpdateIntervals.fields("visibleUpdateInterval")] {
            result.merge(fields) { _, new in new }
        }
        return result
    }
}
