// Sources/EdgeRumCapture/RunLoopObserverCapture.swift
//
// F10 / T10.3 — main-thread `long_task` detector.
//
// Adds a `CFRunLoopObserver` to the main runloop for `.afterWaiting`
// and `.beforeWaiting`. The runloop sequence is:
//
//   wake (.afterWaiting) → run sources / blocks → go back to sleep (.beforeWaiting)
//
// The interval between `.afterWaiting` and the next `.beforeWaiting`
// is "work the main thread did before it could sleep again". When
// that interval exceeds `thresholdMs` (PLAN-iOS §6.12: 50 ms) we emit
// one `long_task` metric carrying `value` (the measured duration),
// `long_task.threshold_ms`, and a truncated `long_task.stack`
// snapshot.
//
// The stack is captured via `Thread.callStackReturnAddresses`
// (formatted by `StackFrames`, with `long_task.stack.truncated` and
// `long_task.binary_images` siblings) at the moment
// the `.beforeWaiting` activity fires — the work is already done by
// then, so the stack is the *current* main-thread frame, not the
// frame that was hot during the stall. Best-effort; flagged in
// `docs/decisions.md` ADR-006.
//
// Long tasks ≠ hangs (F33 disjoint rungs): with hang detection on, a
// span at or past the hang threshold (`ceilingMs`) is dropped — that
// stall is an `app.hang`. With it off, `long_task` keeps the full range.
//
// Refs: PLAN-iOS.md §F10/T10.3, §6.12; CLAUDE.md "eventName values" +
//       "When in doubt checklist" items 1, 2, 4.
//

import Foundation
import CoreFoundation
#if canImport(Darwin)
import Darwin
#endif
import os.log
#if canImport(EdgeRumCore)
import EdgeRumCore
#endif

/// F10 / T10.3 installer — `CFRunLoopObserver` on the main runloop.
public enum RunLoopObserverCapture {

    // MARK: Diagnostics

    private static let log = OSLog(subsystem: "com.edge.rum", category: "RunLoopObserverCapture")

    // MARK: Configuration

    /// PLAN-iOS §6.12 — anything below this lands in the noise floor
    /// and is dropped before the bag is built.
    public static let defaultThresholdMs: Double = 50.0

    /// Bound on the captured stack-symbol payload. Keeps the wire
    /// envelope from ballooning when a deep stack stalls.
    public static let maxStackBytes: Int = 4096

    // MARK: Once token

    nonisolated(unsafe) private static let installLock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()

    nonisolated(unsafe) private static var _installed: Bool = false

    /// `true` once `install(...)` has attached the observer.
    public static var isInstalled: Bool {
        os_unfair_lock_lock(installLock)
        defer { os_unfair_lock_unlock(installLock) }
        return _installed
    }

    // MARK: Public install

    /// Install the run-loop observer. Idempotent and concurrent-safe —
    /// `CFRunLoopAddObserver(CFRunLoopGetMain(), …)` is safe to call
    /// from any thread, and the once-token is serialised under
    /// `os_unfair_lock` so racing installs collapse to one swap.
    public static func install(debug: Bool = false, ceilingMs: Double? = nil) {
        performInstall(debug: debug, ceilingMs: ceilingMs)
    }

    // MARK: Pure decision core (testable without a runloop)

    /// Build the wire attribute bag for a measured run-loop span.
    /// Returns `nil` when `durationMs` is under threshold, or at or past
    /// `ceilingMs` (the hang threshold), so the emission path can
    /// short-circuit before allocating.
    public static func decideEmission(
        durationMs: Double,
        thresholdMs: Double,
        ceilingMs: Double? = nil,
        stack: [StackFrame]
    ) -> [String: AttributeValue]? {
        guard durationMs >= thresholdMs, durationMs < ceilingMs ?? .infinity else { return nil }
        let capped = StackFrames.capped(stack, maxBytes: maxStackBytes)
        var attrs: [String: AttributeValue] = [
            "value": .double(durationMs),
            "long_task.threshold_ms": .double(thresholdMs),
            "long_task.stack": .string(capped.stack)
        ]
        if capped.bytesRemoved > 0 {
            attrs["long_task.stack.truncated"] = .int(capped.bytesRemoved)
        }
        if let images = capped.binaryImages {
            attrs["long_task.binary_images"] = .string(images)
        }
        return attrs
    }

    // MARK: Emission seam

    /// Public seam — emit one `long_task` metric for the supplied
    /// span. Tests drive this directly.
    static func emit(durationMs: Double, thresholdMs: Double, ceilingMs: Double? = nil, stack: [StackFrame]) {
        guard let attrs = decideEmission(
            durationMs: durationMs,
            thresholdMs: thresholdMs,
            ceilingMs: ceilingMs,
            stack: stack
        ) else { return }
        let recorder = Recorder.shared
        guard recorder.isEnabled else { return }
        recorder.recordPerformance(name: "long_task", attributes: attrs)
    }

    // MARK: Driver

    private final class Driver {

        private let thresholdMs: Double
        private let ceilingMs: Double?
        private let debug: Bool
        private var observer: CFRunLoopObserver?
        private var lastResumeAt: UInt64 = 0
        private let timebase: mach_timebase_info_data_t

        init(thresholdMs: Double, ceilingMs: Double?, debug: Bool) {
            self.thresholdMs = thresholdMs
            self.ceilingMs = ceilingMs
            self.debug = debug
            var tb = mach_timebase_info_data_t()
            mach_timebase_info(&tb)
            self.timebase = tb
        }

        func start() {
            guard observer == nil else { return }
            let activities: CFRunLoopActivity = [.afterWaiting, .beforeWaiting]
            // Capture self weakly inside the handler so a stuck driver
            // can be torn down by the test harness.
            weak var weakSelf = self
            let obs = CFRunLoopObserverCreateWithHandler(
                kCFAllocatorDefault,
                activities.rawValue,
                true,  // repeats
                0      // order
            ) { _, activity in
                guard let self = weakSelf else { return }
                if activity.contains(.afterWaiting) {
                    self.lastResumeAt = mach_absolute_time()
                } else if activity.contains(.beforeWaiting) {
                    if self.lastResumeAt == 0 { return }
                    let end = mach_absolute_time()
                    let elapsedNs = self.machDeltaToNanos(start: self.lastResumeAt, end: end)
                    let ms = Double(elapsedNs) / 1_000_000.0
                    self.lastResumeAt = 0
                    if ms >= self.thresholdMs, ms < self.ceilingMs ?? .infinity {
                        let stack = StackFrames.symbolicate(
                            Thread.callStackReturnAddresses.map(\.uintValue)
                        )
                        RunLoopObserverCapture.emit(
                            durationMs: ms,
                            thresholdMs: self.thresholdMs,
                            ceilingMs: self.ceilingMs,
                            stack: stack
                        )
                        if self.debug {
                            os_log(
                                "long_task observed (%{public}.1fms ≥ %{public}.1fms)",
                                log: RunLoopObserverCapture.log,
                                type: .info,
                                ms,
                                self.thresholdMs
                            )
                        }
                    }
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
            self.observer = obs
        }

        func cancel() {
            if let obs = observer {
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), obs, .commonModes)
                CFRunLoopObserverInvalidate(obs)
            }
            observer = nil
            lastResumeAt = 0
        }

        private func machDeltaToNanos(start: UInt64, end: UInt64) -> UInt64 {
            guard end > start else { return 0 }
            let delta = end - start
            // (delta * numer) / denom — promote to UInt128-ish via
            // chunked multiplication when numer/denom differ, but on
            // every iOS device numer == denom == 1, so the fast path
            // covers reality.
            if timebase.numer == timebase.denom {
                return delta
            }
            return (delta * UInt64(timebase.numer)) / UInt64(timebase.denom)
        }
    }

    nonisolated(unsafe) private static var sharedDriver: Driver?

    private static func performInstall(debug: Bool, ceilingMs: Double?) {
        os_unfair_lock_lock(installLock)
        if _installed {
            os_unfair_lock_unlock(installLock)
            return
        }
        let driver = Driver(thresholdMs: defaultThresholdMs, ceilingMs: ceilingMs, debug: debug)
        driver.start()
        sharedDriver = driver
        _installed = true
        os_unfair_lock_unlock(installLock)
        if debug {
            os_log(
                "RunLoopObserverCapture installed (threshold=%{public}.0fms)",
                log: log,
                type: .info,
                defaultThresholdMs
            )
        }
    }

    // MARK: Test-only helpers

    #if DEBUG
    /// Remove the runloop observer and clear the install flag so the
    /// next test starts from a clean state.
    public static func _resetInstallFlagForTesting() {
        os_unfair_lock_lock(installLock)
        sharedDriver?.cancel()
        sharedDriver = nil
        _installed = false
        os_unfair_lock_unlock(installLock)
    }
    #endif
}
