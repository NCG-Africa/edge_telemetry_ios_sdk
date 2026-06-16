import XCTest
@testable import EdgeRum
import EdgeRumCore

/// Behaviour of `RumTimer`: idempotent `end()` and `cancel()`,
/// duration computed against an injectable clock, and consumer
/// attributes merged with the SDK-supplied `duration_ms` key.
///
/// Refs: PLAN-iOS.md §3.2, §F2/T2.5.
final class RumTimerTests: XCTestCase {

    private func makeTimer(
        name: String = "checkout.submit",
        start: Date,
        end: Date
    ) -> (RumTimer, AdvancingClock, Recorder) {
        let clock = AdvancingClock(times: [start, end])
        let recorder = Recorder(clock: clock)
        let timer = RumTimer(name: name, recorder: recorder, clock: clock)
        return (timer, clock, recorder)
    }

    func testEndRecordsSinglePerformanceCall() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let (timer, _, recorder) = makeTimer(start: t0, end: t0.addingTimeInterval(0.250))

        timer.end()

        let calls = recorder.recordedCalls
        XCTAssertEqual(calls.count, 1)
        guard case let .performance(name, attributes) = calls[0] else {
            return XCTFail("Expected a .performance call, got \(calls[0])")
        }
        XCTAssertEqual(name, "checkout.submit")
        XCTAssertEqual(attributes["duration_ms"], .int(250))
    }

    func testSecondEndIsNoOp() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let (timer, _, recorder) = makeTimer(start: t0, end: t0.addingTimeInterval(1.0))

        timer.end()
        timer.end(attributes: ["extra": "should_not_be_recorded"])

        XCTAssertEqual(recorder.recordedCalls.count, 1,
                       "Second .end() must be a no-op")
    }

    func testCancelPreventsEndFromRecording() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let (timer, _, recorder) = makeTimer(start: t0, end: t0.addingTimeInterval(1.0))

        timer.cancel()
        timer.end()

        XCTAssertEqual(recorder.recordedCalls.count, 0,
                       ".cancel() then .end() must record nothing")
    }

    func testEndThenCancelDoesNotDoubleEmit() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let (timer, _, recorder) = makeTimer(start: t0, end: t0.addingTimeInterval(0.5))

        timer.end()
        timer.cancel()

        XCTAssertEqual(recorder.recordedCalls.count, 1,
                       ".cancel() after .end() must not change recorded count")
    }

    func testCancelIsIdempotent() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let (timer, _, recorder) = makeTimer(start: t0, end: t0.addingTimeInterval(0.5))

        timer.cancel()
        timer.cancel()
        timer.cancel()

        XCTAssertEqual(recorder.recordedCalls.count, 0)
    }

    func testConsumerAttributesAreMergedWithDuration() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let (timer, _, recorder) = makeTimer(start: t0, end: t0.addingTimeInterval(2.5))

        timer.end(attributes: [
            "payment.method": "card",
            "items.count": 4
        ])

        guard case let .performance(_, attributes) = recorder.recordedCalls[0] else {
            return XCTFail("Expected a .performance call")
        }
        XCTAssertEqual(attributes["payment.method"], .string("card"))
        XCTAssertEqual(attributes["items.count"], .int(4))
        XCTAssertEqual(attributes["duration_ms"], .int(2500))
    }

    func testDurationRoundsToNearestMillisecond() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let (timer, _, recorder) = makeTimer(start: t0, end: t0.addingTimeInterval(0.0006))
        timer.end()
        guard case let .performance(_, attributes) = recorder.recordedCalls[0] else {
            return XCTFail("Expected a .performance call")
        }
        XCTAssertEqual(attributes["duration_ms"], .int(1),
                       "0.0006s should round to 1ms")
    }
}

// MARK: - Test Clock

/// Yields a fixed sequence of timestamps so the timer's start and
/// end reads are deterministic.
internal final class AdvancingClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Date]

    internal init(times: [Date]) {
        self.queue = times
    }

    internal var now: Date {
        lock.lock(); defer { lock.unlock() }
        guard !queue.isEmpty else { return Date() }
        return queue.removeFirst()
    }
}
