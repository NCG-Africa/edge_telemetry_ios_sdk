// Sources/EdgeRum/RumTimer.swift
//
// Refs: PLAN-iOS.md §3.2, §F2/T2.5 (`end(attributes:)` idempotent,
//       `cancel()` idempotent, start moment from injectable Clock).
//

import Foundation
#if canImport(EdgeRumCore)
// SwiftPM: `EdgeRumCore` is a separate internal target. CocoaPods
// rolls every subspec into one `EdgeRum` module — the same types
// are already visible without an import.
import EdgeRumCore
#endif

/// Measures an interval of host-app code and records a single
/// performance data point at the end.
///
/// Obtain one with `EdgeRum.time(_:)`. Call `end()` exactly once to
/// record; second calls are no-ops. Call `cancel()` to discard.
///
/// ```swift
/// let timer = EdgeRum.time("checkout.submit")
/// performCheckout {
///     timer.end(attributes: ["payment.method": "card"])
/// }
/// ```
public final class RumTimer: @unchecked Sendable {

    private let name: String
    private let recorder: Recording
    private let clock: Clock
    private let start: Date

    private let lock = NSLock()
    private var settled: Bool = false

    internal init(name: String, recorder: Recording, clock: Clock) {
        self.name = name
        self.recorder = recorder
        self.clock = clock
        self.start = clock.now
    }

    /// Stop the timer and emit a single performance data point named
    /// after the original `EdgeRum.time(_:)` argument. Any
    /// `attributes` are merged with a `"duration_ms"` attribute the
    /// timer adds itself.
    ///
    /// Second and subsequent calls are no-ops.
    public func end(attributes: [String: AttributeValue]? = nil) {
        lock.lock()
        guard !settled else {
            lock.unlock()
            return
        }
        settled = true
        let elapsedMs = Int((clock.now.timeIntervalSince(start) * 1000.0).rounded())
        lock.unlock()

        var payload: [String: AttributeValue] = attributes ?? [:]
        payload["duration_ms"] = .int(elapsedMs)
        recorder.recordPerformance(name: name, attributes: payload)
    }

    /// Discard the timer without recording anything. After calling
    /// `cancel()`, subsequent `end()` calls are no-ops too. Calling
    /// `cancel()` more than once is a no-op.
    public func cancel() {
        lock.lock()
        settled = true
        lock.unlock()
    }
}
