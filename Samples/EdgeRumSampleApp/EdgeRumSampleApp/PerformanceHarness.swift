// Samples/EdgeRumSampleApp/EdgeRumSampleApp/PerformanceHarness.swift
//
// F19 / T19.7 — Synthetic 30 Hz event generator used by
// `EdgeRumSampleAppPerformanceUITests` to measure SDK CPU + memory
// under the steady-state throughput floor (§11.2 modern tier:
// < 2% CPU @ 30 ev/s).
//
// Started from `AppDelegate.didFinishLaunchingWithOptions` only when
// the host launches with `EDGE_RUM_UITEST_PERF=1`. Outside that env
// gate the harness is never instantiated.
//

import Foundation
import EdgeRum

final class PerformanceHarness {

    static let shared = PerformanceHarness()

    private var timer: Timer?

    private init() {}

    /// Start firing `EdgeRum.track("perf.tick", ...)` at 30 Hz on
    /// the main run loop. Idempotent — calling twice keeps the
    /// first timer.
    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
            EdgeRum.track("perf.tick", attributes: [
                "perf.harness": "fire30hz"
            ])
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// True when the host launched under the perf-budget UI test harness.
func isPerformanceUITestRun() -> Bool {
    ProcessInfo.processInfo.environment["EDGE_RUM_UITEST_PERF"] == "1"
}
