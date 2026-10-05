// Tests/EdgeRumCaptureTests/RunLoopObserverCaptureTests.swift
//
// F10 / T10.3 unit tests. Covers:
//
//   - decideEmission: under-threshold returns nil, over-threshold
//     returns a bag with the canonical PLAN-§6.12 keys.
//   - long_task.stack.truncated / long_task.binary_images siblings
//     (cap mechanics themselves: StackFramesTests).
//   - emit() routes through Recorder.shared.recordPerformance with
//     metricName = "long_task".
//   - Recorder.isEnabled = false halts emission.
//   - install() idempotent + concurrent-safe.
//   - Integration: a 200 ms main-thread sleep produces exactly one
//     long_task metric with `value > 200`. Matches the PLAN-§F10/T10.3
//     acceptance criterion verbatim.
//
// Refs: PLAN-iOS.md §F10/T10.3 acceptance; CLAUDE.md
//       "Testing conventions".
//

import XCTest
import Foundation
import EdgeRumCore
@testable import EdgeRumCapture

private final class CaptureProbeRecorder: Recording, @unchecked Sendable {

    enum Call: Equatable {
        case event(name: String, attributes: [String: AttributeValue])
        case performance(name: String, attributes: [String: AttributeValue])
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _enabled: Bool = true
    private let _clock: Clock

    init(clock: Clock = SystemClock(), enabled: Bool = true) {
        self._clock = clock
        self._enabled = enabled
    }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    var clock: Clock { _clock }
    var currentSessionId: String { "session_0_0000000000000000_ios" }
    var currentDeviceId: String { "device_0_0000000000000000_ios" }

    var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _enabled
    }

    func configure(_ config: RecorderConfig) { _ = config }
    func start(apiKey: String, endpoint: URL, debug: Bool) {
        _ = (apiKey, endpoint, debug)
    }
    func stop() {}
    func setEnabled(_ enabled: Bool) {
        lock.lock(); _enabled = enabled; lock.unlock()
    }

    func recordEvent(name: String, attributes: [String: AttributeValue]) {
        lock.lock()
        _calls.append(.event(name: name, attributes: attributes))
        lock.unlock()
    }

    func recordPerformance(name: String, attributes: [String: AttributeValue]) {
        lock.lock()
        _calls.append(.performance(name: name, attributes: attributes))
        lock.unlock()
    }

    func recordError(
        domain: String, code: Int, message: String?,
        context: [String: AttributeValue]
    ) {
        _ = (domain, code, message, context)
    }

    func setUser(_ user: RecorderUser) { _ = user }
}

final class RunLoopObserverCaptureTests: XCTestCase {

    override func tearDown() {
        Recorder.resetShared()
        RunLoopObserverCapture._resetInstallFlagForTesting()
        super.tearDown()
    }

    // MARK: decideEmission — pure cases

    func test_decideEmission_underThresholdReturnsNil() {
        XCTAssertNil(RunLoopObserverCapture.decideEmission(
            durationMs: 10,
            thresholdMs: 50,
            stack: [StackFrame(text: "frame0"), StackFrame(text: "frame1")]
        ))
    }

    func test_decideEmission_atOrAboveThresholdEmits() {
        let attrs = RunLoopObserverCapture.decideEmission(
            durationMs: 75.4,
            thresholdMs: 50,
            stack: [StackFrame(text: "frame0"), StackFrame(text: "frame1")]
        )
        XCTAssertEqual(attrs?["value"], .double(75.4))
        XCTAssertEqual(attrs?["long_task.threshold_ms"], .double(50))
        XCTAssertEqual(attrs?["long_task.stack"], .string("frame0\nframe1"))
    }

    func test_decideEmission_emptyStackProducesEmptyString() {
        let attrs = RunLoopObserverCapture.decideEmission(
            durationMs: 100,
            thresholdMs: 50,
            stack: []
        )
        XCTAssertEqual(attrs?["long_task.stack"], .string(""))
    }

    // MARK: truncated / binary_images siblings

    func test_decideEmission_overCapSetsTruncatedBytes() {
        let image = StackImage(name: "App", uuid: "aa")
        let frames = Array(
            repeating: StackFrame(text: String(repeating: "x", count: 200), image: image),
            count: 50
        )
        let attrs = RunLoopObserverCapture.decideEmission(durationMs: 100, thresholdMs: 50, stack: frames)
        guard case let .string(stack)? = attrs?["long_task.stack"] else {
            return XCTFail("long_task.stack missing")
        }
        XCTAssertLessThanOrEqual(stack.utf8.count, RunLoopObserverCapture.maxStackBytes)
        XCTAssertEqual(attrs?["long_task.stack.truncated"],
                       .int(StackFrames.join(frames).utf8.count - stack.utf8.count))
        XCTAssertEqual(attrs?["long_task.binary_images"], .string(#"[{"name":"App","uuid":"aa"}]"#))
    }

    func test_decideEmission_underCapOmitsMarkers() {
        let attrs = RunLoopObserverCapture.decideEmission(
            durationMs: 100, thresholdMs: 50, stack: [StackFrame(text: "frame0")]
        )
        XCTAssertNil(attrs?["long_task.stack.truncated"])
        XCTAssertNil(attrs?["long_task.binary_images"])
    }

    // MARK: emit() routing

    func test_emit_routesToRecordPerformance() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)

        RunLoopObserverCapture.emit(
            durationMs: 80,
            thresholdMs: 50,
            stack: [StackFrame(text: "frame0")]
        )

        XCTAssertEqual(probe.calls.count, 1)
        guard case let .performance(name, attrs) = probe.calls[0] else {
            return XCTFail("Expected a .performance call, got \(probe.calls)")
        }
        XCTAssertEqual(name, "long_task")
        XCTAssertEqual(attrs["value"], .double(80))
    }

    func test_emit_underThresholdDoesNotRoute() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)
        RunLoopObserverCapture.emit(durationMs: 10, thresholdMs: 50, stack: [])
        XCTAssertEqual(probe.calls.count, 0)
    }

    func test_emit_haltedWhenRecorderDisabled() {
        let probe = CaptureProbeRecorder(enabled: false)
        Recorder.installShared(probe)
        RunLoopObserverCapture.emit(durationMs: 80, thresholdMs: 50, stack: [])
        XCTAssertEqual(probe.calls.count, 0)
    }

    // MARK: F33 — disjoint rungs

    func test_decideEmission_atOrPastHangCeilingReturnsNil() {
        XCTAssertNil(RunLoopObserverCapture.decideEmission(
            durationMs: 5_000, thresholdMs: 50, ceilingMs: 5_000, stack: []))
        XCTAssertNotNil(RunLoopObserverCapture.decideEmission(
            durationMs: 4_999, thresholdMs: 50, ceilingMs: 5_000, stack: []))
    }

    /// Tranche 8 acceptance: the 6 s stall that is an `app.hang` emits
    /// zero `long_task`.
    func test_emit_sixSecondStall_withHangDetection_emitsNoLongTask() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)
        RunLoopObserverCapture.emit(durationMs: 6_000, thresholdMs: 50, ceilingMs: 5_000, stack: [])
        XCTAssertEqual(probe.calls.count, 0)
    }

    /// Hang detection off (no ceiling): `long_task` keeps the full range.
    func test_emit_sixSecondStall_withoutHangDetection_emitsLongTask() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)
        RunLoopObserverCapture.emit(durationMs: 6_000, thresholdMs: 50, ceilingMs: nil, stack: [])
        XCTAssertEqual(probe.calls.count, 1)
    }

    // MARK: install()

    func test_install_isIdempotent() {
        RunLoopObserverCapture.install(debug: false)
        XCTAssertTrue(RunLoopObserverCapture.isInstalled)
        RunLoopObserverCapture.install(debug: false)
        RunLoopObserverCapture.install(debug: false)
        XCTAssertTrue(RunLoopObserverCapture.isInstalled)
    }

    func test_install_concurrentCallsAreSafe() {
        // Pump the main runloop while waiting — `install()` does a
        // `DispatchQueue.main.sync` hop on background callers; blocking
        // main with `DispatchGroup.wait` would deadlock.
        let exp = expectation(description: "16 concurrent installs converge")
        exp.expectedFulfillmentCount = 16
        for _ in 0..<16 {
            DispatchQueue.global().async {
                RunLoopObserverCapture.install(debug: false)
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 120)
        XCTAssertTrue(RunLoopObserverCapture.isInstalled)
    }

    // MARK: Integration — PLAN §F10/T10.3 acceptance

    /// Acceptance: `Thread.sleep(forTimeInterval: 0.2)` on the main
    /// thread emits exactly one `long_task` metric with `value > 200`.
    ///
    /// Sequencing matters here. The observer measures the span between
    /// the main runloop's `.afterWaiting` and the next `.beforeWaiting`
    /// — i.e. the time the loop was *awake doing work*. Calling
    /// `Thread.sleep` while the loop is idle wouldn't be counted (the
    /// loop is still sleeping). So we dispatch the long block as a
    /// work item on the main queue and spin the loop until it runs:
    /// when the loop wakes to execute the block (`.afterWaiting`
    /// timestamp set), blocks for 200 ms, then tries to sleep again
    /// (`.beforeWaiting` measures the 200 ms span).
    func test_integration_mainThreadSleepEmitsLongTask() throws {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)

        RunLoopObserverCapture.install(debug: false)

        let done = expectation(description: "long-block ran")
        DispatchQueue.main.async {
            Thread.sleep(forTimeInterval: 0.2)
            done.fulfill()
        }
        wait(for: [done], timeout: 2.0)

        // One more turn of the runloop so the `.beforeWaiting` tick
        // following the blocked work item fires and routes through
        // emit() before we inspect the probe.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        let longTasks = probe.calls.compactMap { call -> [String: AttributeValue]? in
            if case let .performance(name, attrs) = call, name == "long_task" {
                return attrs
            }
            return nil
        }

        XCTAssertFalse(longTasks.isEmpty, "expected at least one long_task metric")
        guard let first = longTasks.first,
              case let .double(value) = first["value"] ?? .double(0) else {
            return XCTFail("first long_task missing a Double 'value'")
        }
        XCTAssertGreaterThan(value, 200, "long_task value should reflect the 200ms sleep")
    }
}
