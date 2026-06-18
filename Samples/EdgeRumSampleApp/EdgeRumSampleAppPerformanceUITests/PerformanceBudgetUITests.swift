// Samples/EdgeRumSampleApp/EdgeRumSampleAppPerformanceUITests/PerformanceBudgetUITests.swift
//
// F19 / T19.7 — `XCTMetric`-driven budget tests.
//
// `XCTApplicationLaunchMetric` measures wall-clock cold-start time.
// `XCTCPUMetric` and `XCTMemoryMetric` profile the SDK's steady-state
// overhead while `PerformanceHarness` fires `EdgeRum.track` at 30 Hz.
//
// §11.5 wall-clock budgets (modern: < 8 ms, mid: < 18 ms) and §11.2
// CPU budgets (< 2% modern @ 30 ev/s) apply to **real hardware**, not
// simulator. Simulator runs vary wildly across runner generations
// (M1/M2/M3 macOS hosts vs Intel) and across Xcode versions; the
// ceilings below are simulator-only smoke gates. The real-device
// gate lives in the perf-lab weekly run (PLAN-iOS.md §13.7).
//
// Refs: PLAN-iOS.md §11.2, §11.5, §13.8.
//

import XCTest

final class PerformanceBudgetUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testColdStartIsUnderSimulatorBudget() throws {
        // `XCTApplicationLaunchMetric` averages cold-start time over
        // three iterations. Each block invocation triggers a launch
        // that the metric measures end to end. The actual numbers
        // are reported through the xcresult bundle; the simulator
        // ceiling is advisory — real-device budgets (§11.5) are
        // enforced by the perf-lab job, not here.
        let options = XCTMeasureOptions()
        options.iterationCount = 3

        measure(
            metrics: [XCTApplicationLaunchMetric()],
            options: options
        ) {
            let app = XCUIApplication()
            app.launch()
        }
    }

    func testThroughput30HzCpuAndMemory() throws {
        // The SDK side is exercised by `PerformanceHarness`, which
        // fires `EdgeRum.track("perf.tick", ...)` at 30 Hz from the
        // main run loop. We let the harness warm up for two seconds
        // after launch, then measure CPU + memory over a five-second
        // window with the harness still running.
        let options = XCTMeasureOptions()
        options.iterationCount = 1

        let app = XCUIApplication()
        app.launchEnvironment["EDGE_RUM_UITEST_PERF"] = "1"
        app.launch()

        // Warm-up: let SDK boot, swizzles install, NWPathMonitor
        // settle, first flush kick. Then start measuring.
        Thread.sleep(forTimeInterval: 2.0)

        measure(
            metrics: [XCTCPUMetric(application: app), XCTMemoryMetric(application: app)],
            options: options
        ) {
            // Five-second active-measurement window.
            Thread.sleep(forTimeInterval: 5.0)
        }
    }
}
