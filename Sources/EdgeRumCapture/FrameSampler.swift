// Sources/EdgeRumCapture/FrameSampler.swift
//
// F10 / T10.1 — frame render time sampler.
//
// Driven by a single `CADisplayLink` attached to `RunLoop.main` in
// `.common` modes so the callback fires once per display refresh, even
// while UIKit tracks a scroll. Each callback adds one inter-frame delta
// (current `targetTimestamp` minus previous `targetTimestamp`, in ms)
// to a per-second `FrameWindowAggregator`. Every ~1 s a `flush` drains
// the window and emits one `frame_render_time` metric carrying
// `frame.max_ms`, `frame.p95_ms`, `frame.dropped_count`,
// `frame.target_hz`, `frame.source = "displaylink"` (PLAN-iOS.md §6.10).
//
// iOS version paths:
//   - iOS 14: `preferredFramesPerSecond = 0` so UIKit uses the device's
//     native refresh; `frame.target_hz` reports `60` (non-ProMotion).
//   - iOS 15+: `preferredFrameRateRange` is used so ProMotion devices
//     drive 120 Hz; `frame.target_hz` reports the range's `maximum`.
//
// Backgrounding: the display link is paused on
// `UIApplication.willResignActiveNotification` and resumed on
// `didBecomeActiveNotification`. Pausing avoids battery drain while
// suspended and avoids a bogus burst of "dropped" frames on resume.
//
// Recorder access: live `Recorder.shared` is fetched per emission;
// tests swap a probe via `Recorder.installShared(_:)`.
//
// All UIKit code is gated behind `#if canImport(UIKit) && os(iOS)`
// so `swift test` on the macOS CI host still compiles this file.
//
// Refs: PLAN-iOS.md §F10/T10.1, §6.10; CLAUDE.md "eventName values" +
//       "When in doubt checklist" items 1, 2, 4, 10.
//

import Foundation
#if canImport(UIKit) && os(iOS)
import UIKit
import QuartzCore
#endif
import os.log
#if canImport(EdgeRumCore)
import EdgeRumCore
#endif

// MARK: - Aggregator (pure, testable without CADisplayLink)

/// Rolling per-window aggregator for `CADisplayLink` inter-frame
/// deltas. One window = `windowSeconds` of wall time; on `flush(now:)`
/// the aggregate stats are returned and the internal state resets.
///
/// `public` here only means "visible to other internal SDK targets
/// and the test target". `EdgeRumCapture` is not a SwiftPM `product`,
/// so consumers who write `import EdgeRum` never see this type.
public struct FrameWindowAggregator: Sendable {

    public struct Stats: Equatable, Sendable {
        public let maxMs: Double
        public let p95Ms: Double
        public let droppedCount: Int
        public let sampleCount: Int
    }

    /// Window length used to compute the expected-frames count for the
    /// dropped-frame estimate. 1 s matches the PLAN cadence.
    public let windowSeconds: Double

    /// Native target refresh rate (Hz). Used as the expected
    /// frames-per-window for the dropped-frame estimate.
    public let targetHz: Int

    private var samples: [Double] = []
    private var windowStart: Date

    public init(windowSeconds: Double = 1.0, targetHz: Int, startedAt: Date) {
        self.windowSeconds = windowSeconds
        self.targetHz = targetHz
        self.windowStart = startedAt
    }

    /// Record an inter-frame delta in milliseconds.
    public mutating func recordDelta(_ ms: Double) {
        if ms.isFinite && ms >= 0 {
            samples.append(ms)
        }
    }

    /// Returns `true` when the window has elapsed and a `flush` is due.
    public func shouldFlush(now: Date) -> Bool {
        now.timeIntervalSince(windowStart) >= windowSeconds
    }

    /// Drain the current window and reset for the next.
    public mutating func flush(now: Date) -> Stats {
        let stats = Self.computeStats(
            samples: samples,
            windowSeconds: windowSeconds,
            targetHz: targetHz
        )
        samples.removeAll(keepingCapacity: true)
        windowStart = now
        return stats
    }

    /// Pure stat computation; broken out so tests can drive it
    /// independently of any window state.
    public static func computeStats(
        samples: [Double],
        windowSeconds: Double,
        targetHz: Int
    ) -> Stats {
        if samples.isEmpty {
            // Expected frames within an empty window — every one missed.
            let expected = max(0, Int((Double(targetHz) * windowSeconds).rounded()))
            return Stats(maxMs: 0, p95Ms: 0, droppedCount: expected, sampleCount: 0)
        }
        let sorted = samples.sorted()
        let maxMs = sorted.last ?? 0
        let p95Ms = percentile(sorted: sorted, fraction: 0.95)
        let expected = max(0, Int((Double(targetHz) * windowSeconds).rounded()))
        let observed = samples.count
        let dropped = max(0, expected - observed)
        return Stats(maxMs: maxMs, p95Ms: p95Ms, droppedCount: dropped, sampleCount: observed)
    }

    /// Nearest-rank percentile (https://en.wikipedia.org/wiki/Percentile —
    /// the variant the F8 `resource_timing` metric also uses).
    private static func percentile(sorted: [Double], fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let clamped = min(max(fraction, 0.0), 1.0)
        let rank = max(1, Int((clamped * Double(sorted.count)).rounded(.up)))
        let index = min(sorted.count - 1, rank - 1)
        return sorted[index]
    }
}

// MARK: - Capture shell

/// F10 / T10.1 installer — `CADisplayLink`-driven frame sampler.
public enum FrameSampler {

    // MARK: Diagnostics

    private static let log = OSLog(subsystem: "com.edge.rum", category: "FrameSampler")

    // MARK: Once token

    private static let installLock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()

    nonisolated(unsafe) private static var _installed: Bool = false

    /// `true` once `install(...)` has spun up the display link.
    public static var isInstalled: Bool {
        os_unfair_lock_lock(installLock)
        defer { os_unfair_lock_unlock(installLock) }
        return _installed
    }

    // MARK: Public install

    /// Install the frame sampler. Idempotent + main-thread-safe.
    /// On non-UIKit hosts (the macOS unit-test runner) this is a no-op.
    public static func install(debug: Bool = false) {
        #if canImport(UIKit) && os(iOS)
        if Thread.isMainThread {
            performInstall(debug: debug)
        } else {
            DispatchQueue.main.sync { performInstall(debug: debug) }
        }
        #else
        _ = debug
        #endif
    }

    // MARK: UIKit driver

    #if canImport(UIKit) && os(iOS)

    /// Resolved target Hz for the host display. Returned as `frame.target_hz`.
    /// Exposed `internal` so the test target can assert the resolution path.
    static func resolveTargetHz() -> Int {
        if #available(iOS 15.0, *) {
            // The default range on a ProMotion device reports
            // `maximum = 120`; on a 60 Hz device it reports `60`.
            let max = UIScreen.main.maximumFramesPerSecond
            return max > 0 ? max : 60
        } else {
            return 60
        }
    }

    /// Public seam — assemble the metric attribute bag from a window's
    /// `Stats`. Pure; tests drive it directly.
    static func makeAttributes(stats: FrameWindowAggregator.Stats, targetHz: Int) -> [String: AttributeValue] {
        var attrs: [String: AttributeValue] = [
            "frame.max_ms": .double(stats.maxMs),
            "frame.p95_ms": .double(stats.p95Ms),
            "frame.dropped_count": .int(stats.droppedCount),
            "frame.target_hz": .int(targetHz),
            "frame.source": .string("displaylink"),
            // The Recorder's value-extraction path pulls `value` off
            // the bag and stamps it on the metric envelope. We carry
            // `max_ms` as the headline scalar — it surfaces the worst
            // single frame of the window so a downstream dashboard can
            // sort by it without parsing the attribute bag.
            "value": .double(stats.maxMs)
        ]
        attrs["frame.sample_count"] = .int(stats.sampleCount)
        return attrs
    }

    /// Public seam — emit a frame_render_time metric for `stats`.
    /// Called by the runtime display-link driver and by tests.
    static func emit(stats: FrameWindowAggregator.Stats, targetHz: Int) {
        let recorder = Recorder.shared
        guard recorder.isEnabled else { return }
        recorder.recordPerformance(
            name: "frame_render_time",
            attributes: makeAttributes(stats: stats, targetHz: targetHz)
        )
    }

    // The CADisplayLink target. UIKit retains the link's target weakly
    // via the runloop; we hold a strong reference here so the driver
    // outlives the install call.
    private final class Driver: NSObject {

        private var displayLink: CADisplayLink?
        private var aggregator: FrameWindowAggregator
        private var lastTimestamp: CFTimeInterval = 0
        private let targetHz: Int
        private let debug: Bool

        init(targetHz: Int, debug: Bool) {
            self.targetHz = targetHz
            self.aggregator = FrameWindowAggregator(
                windowSeconds: 1.0,
                targetHz: targetHz,
                startedAt: Date()
            )
            self.debug = debug
            super.init()
        }

        func start() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            if #available(iOS 15.0, *) {
                link.preferredFrameRateRange = CAFrameRateRange(
                    minimum: 30,
                    maximum: Float(targetHz),
                    preferred: Float(targetHz)
                )
            } else {
                link.preferredFramesPerSecond = 0
            }
            link.add(to: .main, forMode: .common)
            self.displayLink = link
            self.lastTimestamp = 0
            self.aggregator = FrameWindowAggregator(
                windowSeconds: 1.0,
                targetHz: targetHz,
                startedAt: Date()
            )
        }

        func pause() {
            displayLink?.isPaused = true
        }

        func resume() {
            // Reset the inter-frame baseline so the first delta after
            // resume isn't a multi-second spike (foregrounding gap).
            lastTimestamp = 0
            aggregator = FrameWindowAggregator(
                windowSeconds: 1.0,
                targetHz: targetHz,
                startedAt: Date()
            )
            displayLink?.isPaused = false
        }

        @objc
        private func tick(_ link: CADisplayLink) {
            let ts = link.targetTimestamp
            defer { lastTimestamp = ts }
            if lastTimestamp != 0 {
                let deltaMs = (ts - lastTimestamp) * 1000.0
                aggregator.recordDelta(deltaMs)
            }
            let now = Date()
            if aggregator.shouldFlush(now: now) {
                let stats = aggregator.flush(now: now)
                FrameSampler.emit(stats: stats, targetHz: targetHz)
                if debug {
                    os_log(
                        "frame window: max=%{public}.2fms p95=%{public}.2fms dropped=%{public}d",
                        log: FrameSampler.log,
                        type: .info,
                        stats.maxMs,
                        stats.p95Ms,
                        stats.droppedCount
                    )
                }
            }
        }
    }

    nonisolated(unsafe) private static var sharedDriver: Driver?
    nonisolated(unsafe) private static var lifecycleObservers: [NSObjectProtocol] = []

    private static func performInstall(debug: Bool) {
        os_unfair_lock_lock(installLock)
        if _installed {
            os_unfair_lock_unlock(installLock)
            return
        }
        let targetHz = resolveTargetHz()
        let driver = Driver(targetHz: targetHz, debug: debug)
        driver.start()
        sharedDriver = driver
        let nc = NotificationCenter.default
        let resign = nc.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            sharedDriver?.pause()
        }
        let become = nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            sharedDriver?.resume()
        }
        lifecycleObservers = [resign, become]
        _installed = true
        os_unfair_lock_unlock(installLock)
        if debug {
            os_log(
                "FrameSampler installed (target_hz=%{public}d)",
                log: log,
                type: .info,
                targetHz
            )
        }
    }
    #endif

    // MARK: Test-only helpers

    #if DEBUG
    /// Tear down the running display link and lifecycle observers and
    /// clear the install flag so subsequent tests can drive `install()`
    /// from a clean state.
    public static func _resetInstallFlagForTesting() {
        #if canImport(UIKit) && os(iOS)
        os_unfair_lock_lock(installLock)
        sharedDriver?.pause()
        sharedDriver = nil
        let nc = NotificationCenter.default
        for token in lifecycleObservers {
            nc.removeObserver(token)
        }
        lifecycleObservers.removeAll()
        _installed = false
        os_unfair_lock_unlock(installLock)
        #else
        os_unfair_lock_lock(installLock)
        _installed = false
        os_unfair_lock_unlock(installLock)
        #endif
    }
    #endif
}
