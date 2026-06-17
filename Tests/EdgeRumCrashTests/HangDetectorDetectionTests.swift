// Tests/EdgeRumCrashTests/HangDetectorDetectionTests.swift
//
// State-machine coverage for the `HangWatchdog.tick(currentHeartbeat:)`
// decision logic. The watchdog tick is the single point at which the
// detector decides whether to emit an `app.crash`, so the tests drive
// it directly with a `FixedClock` rather than relying on a real
// 5-second main-thread block. This keeps the suite fast (sub-millisecond
// per test) and deterministic on noisy CI runners.
//
// Refs: PLAN-iOS.md §6.8, §F15/T15.1 acceptance ("synthetic 6 s main-
// thread block emits one `app.crash` with `crash.cause = "Hang"`").
//

import XCTest
@testable import EdgeRumCrash
import EdgeRumCore

final class HangDetectorDetectionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HangDetector._resetForTests()
    }

    override func tearDown() {
        HangDetector._resetForTests()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeWatchdog(
        threshold: TimeInterval,
        clock: FixedClock,
        recorder: Recording,
        stack: [String] = ["hang-test-frame"],
        cpu: Double? = nil,
        debug: Bool = false
    ) -> HangWatchdog {
        HangWatchdog(
            threshold: threshold,
            clock: clock,
            recorder: recorder,
            stackProvider: { stack },
            cpuProvider: { cpu },
            debug: debug,
            log: .default
        )
    }

    // MARK: - Tests

    func testStalledMainThreadEmitsOneAppCrash() throws {
        let probe = HangProbeRecorder()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_000_000))
        let watchdog = makeWatchdog(threshold: 5.0, clock: clock, recorder: probe,
                                    stack: ["mainThreadFrame", "innerFrame"])

        // Tick 1: first observation — heartbeat already at 1 because
        // the runloop has fired once. Watchdog records the baseline.
        XCTAssertFalse(watchdog.tick(currentHeartbeat: 1))
        // Tick 2 (+0.25s wall clock): no heartbeat advance, stall begins.
        clock.advance(by: 0.25)
        XCTAssertFalse(watchdog.tick(currentHeartbeat: 1))
        // Tick 3 (+5.25s wall clock total since stall start): exactly
        // at the threshold — fires.
        clock.advance(by: 5.0)
        XCTAssertTrue(watchdog.tick(currentHeartbeat: 1))

        // Exactly one event recorded.
        XCTAssertEqual(probe.calls.count, 1)
        let call = try XCTUnwrap(probe.calls.first)
        XCTAssertEqual(call.name, "app.crash")
        XCTAssertEqual(call.attributes["cause"], .string("Hang"))
        XCTAssertEqual(call.attributes["runtime"], .string("native"))
        guard case let .double(durationMs) = call.attributes["hang.duration_ms"] else {
            return XCTFail("hang.duration_ms missing or wrong type")
        }
        XCTAssertGreaterThanOrEqual(durationMs, 5_000)
        XCTAssertEqual(call.attributes["hang.threshold_ms"], .double(5_000))
        // Stack supplied via the injected provider.
        guard case let .string(stack) = call.attributes["crash.thread.main_stack"] else {
            return XCTFail("crash.thread.main_stack missing")
        }
        XCTAssertTrue(stack.contains("mainThreadFrame"))
    }

    func testContinuedStallDoesNotEmitDuplicateEvents() {
        let probe = HangProbeRecorder()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_000_000))
        let watchdog = makeWatchdog(threshold: 5.0, clock: clock, recorder: probe)

        // Baseline observation.
        _ = watchdog.tick(currentHeartbeat: 1)
        // Stall begins on the next tick (stalledStart is set to `now`).
        clock.advance(by: 0.25)
        _ = watchdog.tick(currentHeartbeat: 1)
        // Threshold crossed on a later tick: now - stalledStart ≥ 5.0.
        clock.advance(by: 5.0)
        _ = watchdog.tick(currentHeartbeat: 1)
        XCTAssertEqual(probe.calls.count, 1, "fires exactly once at threshold crossing")

        // Subsequent ticks while the stall continues must NOT emit
        // additional events — one event per stall window.
        clock.advance(by: 2.0)
        _ = watchdog.tick(currentHeartbeat: 1)
        clock.advance(by: 2.0)
        _ = watchdog.tick(currentHeartbeat: 1)
        XCTAssertEqual(probe.calls.count, 1, "continued stall must not duplicate")
    }

    func testHeartbeatAdvancingEmitsNothing() {
        let probe = HangProbeRecorder()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_000_000))
        let watchdog = makeWatchdog(threshold: 5.0, clock: clock, recorder: probe)

        for beat in 1...40 {
            clock.advance(by: 0.25)
            _ = watchdog.tick(currentHeartbeat: UInt64(beat))
        }
        XCTAssertTrue(probe.calls.isEmpty,
                      "advancing heartbeat must never fire a hang event")
    }

    func testTwoBackToBackHangsEmitTwoSeparateEvents() throws {
        let probe = HangProbeRecorder()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_000_000))
        let watchdog = makeWatchdog(threshold: 2.0, clock: clock, recorder: probe)

        // Baseline observation.
        _ = watchdog.tick(currentHeartbeat: 1)
        // Stall #1 — fires once.
        clock.advance(by: 0.25)
        _ = watchdog.tick(currentHeartbeat: 1)
        clock.advance(by: 2.0)
        _ = watchdog.tick(currentHeartbeat: 1)
        XCTAssertEqual(probe.calls.count, 1)

        // Heartbeat advances → stall ends, state resets.
        clock.advance(by: 0.25)
        _ = watchdog.tick(currentHeartbeat: 2)

        // Stall #2 — fires a second, distinct event.
        clock.advance(by: 0.25)
        _ = watchdog.tick(currentHeartbeat: 2)
        clock.advance(by: 2.0)
        _ = watchdog.tick(currentHeartbeat: 2)

        XCTAssertEqual(probe.calls.count, 2,
                       "two distinct stalls must emit two events")
        let first = try XCTUnwrap(probe.calls.first?.attributes["crash.timestamp"])
        let second = try XCTUnwrap(probe.calls.last?.attributes["crash.timestamp"])
        XCTAssertNotEqual(first, second,
                          "two events must carry distinct timestamps")
    }

    func testBaselineNeverFiresBeforeFirstHeartbeat() {
        let probe = HangProbeRecorder()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_000_000))
        let watchdog = makeWatchdog(threshold: 2.0, clock: clock, recorder: probe)

        // Heartbeat counter is still zero — the CFRunLoopObserver has
        // not fired yet. The watchdog must NOT interpret this as a
        // hang; it should wait for the first non-zero observation.
        for _ in 0..<30 {
            clock.advance(by: 0.25)
            _ = watchdog.tick(currentHeartbeat: 0)
        }
        XCTAssertTrue(probe.calls.isEmpty,
                      "pre-baseline ticks must never fire a hang event")
    }
}
