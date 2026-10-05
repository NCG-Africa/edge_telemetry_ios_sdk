// Sources/EdgeRumCapture/FrameSampler.swift
//
// F10 / T10.1 — frame render time sampler.
//
// F30 / #217 — motion windows. One `CADisplayLink` on `RunLoop.main`
// (`.common` modes) runs only inside a motion window: `noteMotion()`
// opens one on touch began/ended (`UIWindow.sendEvent` swizzle) and on
// screen transitions (`viewWillDisappear` / `viewDidAppear`). The window
// closes `idleCloseSeconds` after the last motion or at the
// `hardCapSeconds` cap, whichever is first; the link is paused otherwise,
// so static content never pins the panel at max refresh. Each window
// emits one `frame_render_time` carrying `frame.max_ms`, `frame.p95_ms`,
// `frame.dropped_count`, `frame.target_hz`, `frame.sample_count`,
// `frame.window_ms`, `frame.source = "displaylink"` (PLAN-iOS.md §6.10).
//
// iOS version paths:
//   - iOS 14: `preferredFramesPerSecond = 0` so UIKit uses the device's
//     native refresh; `frame.target_hz` reports `60` (non-ProMotion).
//   - iOS 15+: `preferredFrameRateRange` is used so ProMotion devices
//     drive 120 Hz; `frame.target_hz` reports the range's `maximum`.
//
// Gate: a window opens only while `SamplingGate` is open and the SDK is
// enabled. Resigning active, a low-power or thermal change that closes
// the gate, pauses the link and drops the open window unsent.
//
// ponytail: only touch began/ended arm (spec), so a drag held > 2 s or a
// momentum scroll past 2 s after lift is cut short. Arm on `.moved` too
// if long gestures turn out to matter.
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

/// Motion-window aggregator for `CADisplayLink` inter-frame deltas.
/// A window opens at `startedAt`, stays open while `noteMotion(now:)`
/// keeps arriving, and is due to close (`shouldFlush`) `idleCloseSeconds`
/// after the last motion or `hardCapSeconds` after it opened.
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
        /// Window length (ms) — `frame.window_ms`.
        public let windowMs: Int
    }

    /// A window closes this long after the last motion.
    public static let idleCloseSeconds: Double = 2.0
    /// A window never runs longer than this.
    public static let hardCapSeconds: Double = 10.0

    /// Native target refresh rate (Hz). Used as the expected
    /// frames-per-second for the dropped-frame estimate.
    public let targetHz: Int

    private var samples: [Double] = []
    private let windowStart: Date
    private var lastMotion: Date

    public init(targetHz: Int, startedAt: Date) {
        self.targetHz = targetHz
        self.windowStart = startedAt
        self.lastMotion = startedAt
    }

    /// Record an inter-frame delta in milliseconds.
    public mutating func recordDelta(_ ms: Double) {
        if ms.isFinite && ms >= 0 {
            samples.append(ms)
        }
    }

    /// Extend the window: it now closes `idleCloseSeconds` after `now`.
    public mutating func noteMotion(now: Date) {
        lastMotion = now
    }

    /// `true` once the window is idle long enough or hit the hard cap.
    public func shouldFlush(now: Date) -> Bool {
        now.timeIntervalSince(lastMotion) >= Self.idleCloseSeconds
            || now.timeIntervalSince(windowStart) >= Self.hardCapSeconds
    }

    /// Stats for the window ending at `now` (clamped to the hard cap).
    public func flush(now: Date) -> Stats {
        let seconds = min(max(0, now.timeIntervalSince(windowStart)), Self.hardCapSeconds)
        return Self.computeStats(samples: samples, windowSeconds: seconds, targetHz: targetHz)
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
            return Stats(maxMs: 0, p95Ms: 0, droppedCount: expected, sampleCount: 0,
                         windowMs: Int((windowSeconds * 1000).rounded()))
        }
        let sorted = samples.sorted()
        let maxMs = sorted.last ?? 0
        let p95Ms = percentile(sorted: sorted, fraction: 0.95)
        let expected = max(0, Int((Double(targetHz) * windowSeconds).rounded()))
        let observed = samples.count
        let dropped = max(0, expected - observed)
        return Stats(maxMs: maxMs, p95Ms: p95Ms, droppedCount: dropped, sampleCount: observed,
                     windowMs: Int((windowSeconds * 1000).rounded()))
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

    nonisolated(unsafe) private static let installLock: UnsafeMutablePointer<os_unfair_lock> = {
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

    /// Open or extend a motion window. Any thread (hops to main); no-op
    /// before `install`, while disabled or resigned, while the gate is
    /// closed, and on non-UIKit hosts.
    public static func noteMotion() {
        #if canImport(UIKit) && os(iOS)
        guard Thread.isMainThread else {
            DispatchQueue.main.async { noteMotion() }
            return
        }
        sharedDriver?.noteMotion()
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
        attrs["frame.window_ms"] = .int(stats.windowMs)
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

    // The CADisplayLink target. Main-thread only.
    private final class Driver: NSObject {

        private var displayLink: CADisplayLink?
        /// Non-nil while a motion window is open.
        private var window: FrameWindowAggregator?
        private var lastTimestamp: CFTimeInterval = 0
        private var active = true
        private let targetHz: Int
        private let debug: Bool

        init(targetHz: Int, debug: Bool) {
            self.targetHz = targetHz
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
            link.isPaused = true
            link.add(to: .main, forMode: .common)
            self.displayLink = link
        }

        func noteMotion() {
            let now = Date()
            if window != nil {
                window?.noteMotion(now: now)
                return
            }
            guard active, Recorder.shared.isEnabled, SamplingGate.isOpen() else { return }
            window = FrameWindowAggregator(targetHz: targetHz, startedAt: now)
            // Fresh baseline so the first delta isn't the idle gap.
            lastTimestamp = 0
            displayLink?.isPaused = false
        }

        #if DEBUG
        var isSampling: Bool { window != nil && displayLink?.isPaused == false }
        #endif

        func setActive(_ value: Bool) {
            active = value
            if !value { closeWindow() }
        }

        /// Low power / thermal changed: drop an open window the gate
        /// now forbids, so the link stops mid-window, not at its end.
        func gateMayHaveClosed() {
            if window != nil, !SamplingGate.isOpen() { closeWindow() }
        }

        private func closeWindow() {
            displayLink?.isPaused = true
            window = nil
        }

        @objc
        private func tick(_ link: CADisplayLink) {
            guard var current = window else { return }
            let ts = link.targetTimestamp
            if lastTimestamp != 0 {
                current.recordDelta((ts - lastTimestamp) * 1000.0)
            }
            lastTimestamp = ts
            window = current
            let now = Date()
            guard current.shouldFlush(now: now) else { return }
            closeWindow()
            guard SamplingGate.isOpen() else { return }
            let stats = current.flush(now: now)
            FrameSampler.emit(stats: stats, targetHz: targetHz)
            if debug {
                os_log(
                    "frame window: %{public}dms max=%{public}.2fms p95=%{public}.2fms dropped=%{public}d",
                    log: FrameSampler.log,
                    type: .info,
                    stats.windowMs,
                    stats.maxMs,
                    stats.p95Ms,
                    stats.droppedCount
                )
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
            sharedDriver?.setActive(false)
        }
        let become = nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            sharedDriver?.setActive(true)
        }
        // F30: the gate's power inputs — close a window they forbid.
        let power = [
            ProcessInfo.thermalStateDidChangeNotification,
            Notification.Name.NSProcessInfoPowerStateDidChange
        ].map {
            nc.addObserver(forName: $0, object: nil, queue: .main) { _ in
                sharedDriver?.gateMayHaveClosed()
            }
        }
        lifecycleObservers = [resign, become] + power
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
    #if canImport(UIKit) && os(iOS)
    /// `true` while a motion window is open and the display link runs.
    static var _isSamplingForTesting: Bool { sharedDriver?.isSampling ?? false }
    #endif

    /// Tear down the running display link and lifecycle observers and
    /// clear the install flag so subsequent tests can drive `install()`
    /// from a clean state.
    public static func _resetInstallFlagForTesting() {
        #if canImport(UIKit) && os(iOS)
        os_unfair_lock_lock(installLock)
        sharedDriver?.setActive(false)
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
