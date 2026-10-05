// Tests/EdgeRumCrashTests/HangDetectorDetectionTests.swift
//
// State-machine coverage for the `HangWatchdog.tick(currentHeartbeat:)`
// decision logic. The watchdog tick is the single point at which the
// detector decides whether to emit an `app.hang`, so the tests drive
// it directly with a `FixedClock` rather than relying on a real
// 5-second main-thread block. This keeps the suite fast (sub-millisecond
// per test) and deterministic on noisy CI runners.
//
// Refs: PLAN-iOS.md §6.8, §F15/T15.1 acceptance ("synthetic 6 s main-
// thread block emits one `app.hang`").
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
        stack: [StackFrame] = [StackFrame(text: "hang-test-frame")],
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

    /// Tranche 8 acceptance: a 6 s stall emits exactly one `app.hang`,
    /// at stall end, with the real duration.
    func testSixSecondStallEmitsOneHangWithRealDurationAtStallEnd() throws {
        let probe = HangProbeRecorder()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_000_000))
        let watchdog = makeWatchdog(threshold: 5.0, clock: clock, recorder: probe,
                                    stack: [StackFrame(text: "mainThreadFrame"), StackFrame(text: "innerFrame")])

        XCTAssertFalse(watchdog.tick(currentHeartbeat: 1))  // baseline
        XCTAssertFalse(watchdog.tick(currentHeartbeat: 1))  // stall begins at t0
        for _ in 0..<24 {                                   // 24 × 250 ms = 6 s
            clock.advance(by: 0.25)
            XCTAssertFalse(watchdog.tick(currentHeartbeat: 1), "nothing emitted mid-stall")
        }
        XCTAssertTrue(probe.calls.isEmpty, "threshold crossing emits nothing")
        XCTAssertTrue(watchdog.tick(currentHeartbeat: 2), "stall end emits")

        XCTAssertEqual(probe.calls.count, 1)
        let call = try XCTUnwrap(probe.calls.first)
        XCTAssertEqual(call.name, "app.hang")
        XCTAssertEqual(call.attributes["runtime"], .string("native"))
        XCTAssertEqual(call.attributes["hang.duration_ms"], .double(6_000))
        XCTAssertEqual(call.attributes["hang.threshold_ms"], .double(5_000))
        XCTAssertNil(call.attributes["hang.terminated"])
        XCTAssertEqual(call.attributes["hang.timestamp"],
                       .string(WireDateFormatter.string(from: Date(timeIntervalSince1970: 1_717_000_005))),
                       "hang.timestamp is the threshold crossing")
        guard case let .string(stack) = call.attributes["hang.stack"] else {
            return XCTFail("hang.stack missing")
        }
        XCTAssertTrue(stack.contains("mainThreadFrame"))
    }

    func testContinuedStallEmitsOnceAtEnd() {
        let probe = HangProbeRecorder()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_000_000))
        let watchdog = makeWatchdog(threshold: 5.0, clock: clock, recorder: probe)

        _ = watchdog.tick(currentHeartbeat: 1)
        clock.advance(by: 0.25)
        _ = watchdog.tick(currentHeartbeat: 1)
        for _ in 0..<5 {
            clock.advance(by: 2.0)
            _ = watchdog.tick(currentHeartbeat: 1)
        }
        XCTAssertTrue(probe.calls.isEmpty)
        clock.advance(by: 0.25)
        _ = watchdog.tick(currentHeartbeat: 2)
        _ = watchdog.tick(currentHeartbeat: 3)
        XCTAssertEqual(probe.calls.count, 1, "one event per stall")
        XCTAssertEqual(probe.calls.first?.attributes["hang.duration_ms"], .double(10_250))
    }

    func testStallShorterThanThresholdEmitsNothing() {
        let probe = HangProbeRecorder()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_000_000))
        let watchdog = makeWatchdog(threshold: 5.0, clock: clock, recorder: probe)
        _ = watchdog.tick(currentHeartbeat: 1)
        _ = watchdog.tick(currentHeartbeat: 1)
        clock.advance(by: 4.75)
        _ = watchdog.tick(currentHeartbeat: 1)
        clock.advance(by: 0.25)
        XCTAssertFalse(watchdog.tick(currentHeartbeat: 2))
        XCTAssertTrue(probe.calls.isEmpty)
    }

    // MARK: - Pending-hang record

    /// The record round-trips through JSON, where `2000.0` reads back
    /// as an int (same bytes on the wire).
    private func ms(_ value: AttributeValue?) -> Double? {
        switch value {
        case .double(let d)?: return d
        case .int(let i)?: return Double(i)
        default: return nil
        }
    }

    private func tempPending() -> PendingHangFile {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edgerum-hang-\(UUID().uuidString)/pending-hang.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return PendingHangFile(url: url)
    }

    func testRecordPersistedAtThresholdUpdatedMidStallDeletedAtEnd() throws {
        let pending = tempPending()
        let probe = HangProbeRecorder()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_000_000))
        let watchdog = HangWatchdog(threshold: 2, clock: clock, recorder: probe,
                                    stackProvider: { [] }, cpuProvider: { nil },
                                    pending: pending, debug: false, log: .default)
        _ = watchdog.tick(currentHeartbeat: 1)
        _ = watchdog.tick(currentHeartbeat: 1)
        clock.advance(by: 1.75)
        _ = watchdog.tick(currentHeartbeat: 1)
        XCTAssertNil(pending.read(), "no record before threshold")
        clock.advance(by: 0.25)
        _ = watchdog.tick(currentHeartbeat: 1)
        XCTAssertEqual(ms(pending.read()?["hang.duration_ms"]), 2_000, "written at threshold")
        clock.advance(by: 0.25)
        _ = watchdog.tick(currentHeartbeat: 1)
        XCTAssertEqual(ms(pending.read()?["hang.duration_ms"]), 2_250, "time-to-death kept current")
        _ = watchdog.tick(currentHeartbeat: 2)
        XCTAssertNil(pending.read(), "deleted at stall end")
        XCTAssertEqual(probe.calls.count, 1)
    }

    func testDiscardPendingDropsOpenHangWithoutEmitting() {
        let pending = tempPending()
        let probe = HangProbeRecorder()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_000_000))
        let watchdog = HangWatchdog(threshold: 2, clock: clock, recorder: probe,
                                    stackProvider: { [] }, cpuProvider: { nil },
                                    pending: pending, debug: false, log: .default)
        _ = watchdog.tick(currentHeartbeat: 1)
        _ = watchdog.tick(currentHeartbeat: 1)
        clock.advance(by: 3)
        _ = watchdog.tick(currentHeartbeat: 1)
        XCTAssertNotNil(pending.read())
        watchdog.discardPending()
        XCTAssertNil(pending.read())
        XCTAssertFalse(watchdog.tick(currentHeartbeat: 2))
        XCTAssertTrue(probe.calls.isEmpty)
    }

    /// Tranche 8 acceptance: killed mid-stall ⇒ next launch replays one
    /// `app.hang` with `hang.terminated = true` on the previous session.
    func testReplayEmitsTerminatedHangOnPreviousSessionIdentity() throws {
        let pending = tempPending()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_000_000))
        let dying = HangWatchdog(threshold: 2, clock: clock, recorder: HangProbeRecorder(),
                                 stackProvider: { [StackFrame(text: "stuck")] }, cpuProvider: { nil },
                                 pending: pending, debug: false, log: .default)
        _ = dying.tick(currentHeartbeat: 1)
        _ = dying.tick(currentHeartbeat: 1)
        clock.advance(by: 2)
        _ = dying.tick(currentHeartbeat: 1)
        clock.advance(by: 0.5)
        _ = dying.tick(currentHeartbeat: 1)
        // …process killed here.

        let prior: [String: AttributeValue] = [
            "session.id": .string("session_1717234870002_ff009988aabbccdd_ios"),
            "device.id": .string("device_1717234876123_a1b2c3d4e5f60718_ios"),
            "user.id": .string("user_1717100000000_deadbeefcafef00d"),
            "screen.name": .string("Checkout")
        ]
        let probe = HangProbeRecorder()
        HangDetector._replayPending(recorder: probe, sidecarContents: prior, pending: pending)

        XCTAssertEqual(probe.calls.count, 1)
        let call = try XCTUnwrap(probe.calls.first)
        XCTAssertEqual(call.name, "app.hang")
        XCTAssertEqual(call.attributes["hang.terminated"], .bool(true))
        XCTAssertEqual(ms(call.attributes["hang.duration_ms"]), 2_500)
        XCTAssertEqual(call.attributes["session.id"], prior["session.id"])
        XCTAssertEqual(call.attributes["device.id"], prior["device.id"])
        XCTAssertEqual(call.attributes["screen.name"], .string("Checkout"))
        XCTAssertNil(pending.read(), "replayed once")

        HangDetector._replayPending(recorder: probe, sidecarContents: prior, pending: pending)
        XCTAssertEqual(probe.calls.count, 1)
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
        // Stall #1 — emits once it ends.
        clock.advance(by: 0.25)
        _ = watchdog.tick(currentHeartbeat: 1)
        clock.advance(by: 2.0)
        _ = watchdog.tick(currentHeartbeat: 1)
        clock.advance(by: 0.25)
        _ = watchdog.tick(currentHeartbeat: 2)
        XCTAssertEqual(probe.calls.count, 1)

        // Stall #2 — a second, distinct event.
        clock.advance(by: 0.25)
        _ = watchdog.tick(currentHeartbeat: 2)
        clock.advance(by: 2.0)
        _ = watchdog.tick(currentHeartbeat: 2)
        _ = watchdog.tick(currentHeartbeat: 3)

        XCTAssertEqual(probe.calls.count, 2,
                       "two distinct stalls must emit two events")
        let first = try XCTUnwrap(probe.calls.first?.attributes["hang.timestamp"])
        let second = try XCTUnwrap(probe.calls.last?.attributes["hang.timestamp"])
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

final class HangCPUWiringTests: XCTestCase {

    override func setUp() { super.setUp(); HangDetector._resetForTests() }
    override func tearDown() { HangDetector._resetForTests(); super.tearDown() }

    /// C4 (#213): production install (nil `cpuProvider`) carries `hang.cpu_usage`.
    func testDefaultInstallWiresProcessCPUReader() throws {
        let probe = HangProbeRecorder()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_000_000))
        HangDetector._install(threshold: 2, debug: false, recorder: probe, clock: clock,
                              stackProvider: { [] }, cpuProvider: nil)
        let watchdog = try XCTUnwrap(HangDetector._activeWatchdog())
        HangDetector.uninstall()  // stop the live thread; drive `tick` alone
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertFalse(watchdog.tick(currentHeartbeat: 1))  // baseline
        clock.advance(by: 0.25)
        XCTAssertFalse(watchdog.tick(currentHeartbeat: 1))  // stall begins
        clock.advance(by: 3)
        XCTAssertFalse(watchdog.tick(currentHeartbeat: 1))  // threshold
        XCTAssertTrue(watchdog.tick(currentHeartbeat: 2))   // stall end
        guard case .double = probe.calls.first?.attributes["hang.cpu_usage"] else {
            return XCTFail("hang.cpu_usage missing")
        }
    }
}

final class HangCPUWindowTests: XCTestCase {

    /// C4 (#213): the CPU reader is re-primed at stall start, so the
    /// detection value covers the stall window only.
    func testCPUProviderPrimedAtStallStartAndReadAtDetection() throws {
        var reads: [Double] = [111, 42]
        var calls = 0
        let probe = HangProbeRecorder()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_000_000))
        let watchdog = HangWatchdog(threshold: 2, clock: clock, recorder: probe,
                                    stackProvider: { [] },
                                    cpuProvider: { calls += 1; return reads.removeFirst() },
                                    debug: false, log: .default)
        XCTAssertFalse(watchdog.tick(currentHeartbeat: 1))
        clock.advance(by: 0.25)
        XCTAssertFalse(watchdog.tick(currentHeartbeat: 1))
        XCTAssertEqual(calls, 1, "primed at stall start")
        clock.advance(by: 3)
        XCTAssertFalse(watchdog.tick(currentHeartbeat: 1))
        XCTAssertEqual(calls, 2, "read at threshold crossing")
        XCTAssertTrue(watchdog.tick(currentHeartbeat: 2))
        XCTAssertEqual(probe.calls.first?.attributes["hang.cpu_usage"], .double(42))
    }
}
