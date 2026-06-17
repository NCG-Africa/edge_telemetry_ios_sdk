import XCTest
@testable import EdgeRum
import EdgeRumCore

/// Unit tests for the F3 production `Recorder` — the real fan-in
/// that buffers events, merges context, and flushes to a
/// `TransportSink`.
///
/// We avoid `Recorder.shared` here so the global isn't polluted; we
/// instantiate a fresh `Recorder` with a `RecordingTransportSink`
/// injected so we can read the envelopes it would have sent.
///
/// Refs: PLAN-iOS.md §F3/T3.1, §4.3.
final class RecorderTests: XCTestCase {

    // MARK: Helpers

    private func makeRecorder(
        batchSize: Int = 30,
        sampleRate: Double = 1.0,
        debug: Bool = false,
        location: String? = nil
    ) -> (recorder: Recorder, sink: RecordingTransportSink, clock: FixedClock) {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.512))
        let sink = RecordingTransportSink()
        let recorder = Recorder(
            clock: clock,
            sampler: Sampler(sampleRate: sampleRate, entropy: { 0.0 }),
            transport: sink,
            sdkVersion: "1.0.0"
        )
        recorder.configure(RecorderConfig(
            apiKey: "edge_test_abc",
            endpoint: URL(string: "https://collect.example.com")!,
            debug: debug,
            sampleRate: sampleRate,
            batchSize: batchSize,
            flushInterval: 5.0,
            location: location
        ))
        return (recorder, sink, clock)
    }

    // MARK: Allowed event names (T3.1 acceptance)

    func testUnknownEventNameIsDropped() {
        let (recorder, sink, _) = makeRecorder()
        recorder.recordEvent(name: "foo", attributes: [:])
        recorder.flush(reason: .manual)
        XCTAssertTrue(sink.envelopes.isEmpty,
                      "Recording eventName = 'foo' must be dropped")
    }

    func testKnownEventNamePassesThrough() {
        let (recorder, sink, _) = makeRecorder()
        recorder.recordEvent(name: "navigation", attributes: ["navigation.kind": "uikit"])
        recorder.flush(reason: .manual)
        XCTAssertEqual(sink.envelopes.count, 1)
        XCTAssertEqual(sink.envelopes.first?.events.count, 1)
        XCTAssertEqual(sink.envelopes.first?.events.first?.name, "navigation")
    }

    func testAllowedEventNamesContainsExpectedSet() {
        let expected: Set<String> = [
            "session.started", "session.finalized", "app_lifecycle",
            "page_load", "navigation", "screen.duration",
            "http.request", "user.interaction", "network_change",
            "user.profile.update", "custom_event", "app.crash"
        ]
        XCTAssertEqual(Recorder.allowedEventNames, expected)
    }

    // MARK: Batching

    func testFlushOnBatchSize() {
        let (recorder, sink, _) = makeRecorder(batchSize: 3)
        recorder.recordEvent(name: "navigation", attributes: [:])
        recorder.recordEvent(name: "navigation", attributes: [:])
        XCTAssertTrue(sink.envelopes.isEmpty, "No flush yet at 2 events")
        recorder.recordEvent(name: "navigation", attributes: [:])
        XCTAssertEqual(sink.envelopes.count, 1)
        XCTAssertEqual(sink.envelopes.first?.events.count, 3)
        XCTAssertEqual(sink.sends.first?.reason, .batchSize)
    }

    func testManualFlushDrainsBuffer() {
        let (recorder, sink, _) = makeRecorder()
        recorder.recordEvent(name: "navigation", attributes: [:])
        recorder.recordEvent(name: "http.request", attributes: [:])
        recorder.flush(reason: .manual)
        XCTAssertEqual(sink.envelopes.first?.events.count, 2)
    }

    func testFlushOnEmptyBufferIsNoOp() {
        let (recorder, sink, _) = makeRecorder()
        recorder.flush(reason: .manual)
        XCTAssertTrue(sink.envelopes.isEmpty)
    }

    // MARK: Immediate-flush triggers

    func testAppCrashEventTriggersImmediateFlush() {
        // F13: `EdgeRum.captureError` routes through
        // `recordEvent(name: "app.crash", ...)`. The Recorder must
        // treat that event name as an immediate-flush trigger so
        // crash payloads never wait behind a `flushInterval` timer.
        let (recorder, sink, _) = makeRecorder()
        recorder.recordEvent(name: "app.crash", attributes: [
            "cause": "AppError",
            "runtime": "swift",
            "error.kind": "swift",
            "error.type": "DemoError",
            "error.message": "boom"
        ])
        XCTAssertEqual(sink.envelopes.count, 1)
        XCTAssertEqual(sink.sends.first?.reason, .immediate)
        let event = sink.envelopes.first?.events.first
        XCTAssertEqual(event?.name, "app.crash")
        XCTAssertEqual(event?.attributes["cause"], .string("AppError"))
        XCTAssertEqual(event?.attributes["error.kind"], .string("swift"))
    }

    func testSessionFinalizedTriggersImmediateFlush() {
        let (recorder, sink, _) = makeRecorder(batchSize: 100)
        recorder.recordEvent(name: "session.finalized", attributes: [:])
        XCTAssertEqual(sink.envelopes.count, 1)
        XCTAssertEqual(sink.sends.first?.reason, .immediate)
    }

    // MARK: setUser

    func testSetUserUpdatesContextAndEmitsProfileUpdate() {
        let (recorder, sink, _) = makeRecorder()
        recorder.setUser(RecorderUser(id: "ext-1", name: "Asha", email: "a@b.c", phone: nil))
        recorder.flush(reason: .manual)
        let event = sink.envelopes.first?.events.first
        XCTAssertEqual(event?.name, "user.profile.update")
        XCTAssertEqual(event?.attributes["user.name"], .string("Asha"))
        XCTAssertEqual(event?.attributes["user.email"], .string("a@b.c"))
        XCTAssertEqual(event?.attributes["user.external_id"], .string("ext-1"))
        XCTAssertNil(event?.attributes["user.phone"])
    }

    // MARK: Performance / metric

    func testRecordPerformanceBuildsMetric() {
        let (recorder, sink, _) = makeRecorder()
        recorder.recordPerformance(name: "checkout.submit", attributes: ["duration_ms": 250])
        recorder.flush(reason: .manual)
        guard case let .metric(name, value, _, attributes) = sink.envelopes.first?.events.first else {
            return XCTFail("Expected a metric Event")
        }
        XCTAssertEqual(name, "checkout.submit")
        XCTAssertEqual(value, 250)
        XCTAssertEqual(attributes["duration_ms"], .int(250))
    }

    // MARK: Sampling

    func testConfigureWiresSampleRateIntoSampler() {
        // Recorder built with default sampleRate=1.0, then configured
        // with sampleRate=0.0 — the sampler must re-roll and start
        // dropping regular events.
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.512))
        let sink = RecordingTransportSink()
        let recorder = Recorder(clock: clock, transport: sink, sdkVersion: "1.0.0")
        recorder.configure(RecorderConfig(
            apiKey: "edge_test",
            endpoint: URL(string: "https://collect.example.com")!,
            sampleRate: 0.0
        ))
        recorder.recordEvent(name: "navigation", attributes: [:])
        recorder.recordEvent(name: "app.crash", attributes: [:])
        // app.crash is forced-emit AND triggers immediate flush; the
        // navigation must NOT survive.
        let names = sink.envelopes.flatMap { $0.events.map { $0.name } }
        XCTAssertEqual(names, ["app.crash"],
                       "configure() must wire sampleRate=0.0 so only forced-emit names land")
    }

    func testSampleRateZeroDropsRegularEventsButKeepsForcedEmit() {
        let (recorder, sink, _) = makeRecorder(sampleRate: 0.0)
        recorder.recordEvent(name: "navigation", attributes: [:])
        recorder.recordEvent(name: "session.finalized", attributes: [:])
        // session.finalized triggers an immediate flush, so the
        // sink should have exactly the forced-emit event.
        XCTAssertEqual(sink.envelopes.count, 1)
        let names = sink.envelopes.flatMap { $0.events.map { $0.name } }
        XCTAssertEqual(names, ["session.finalized"])
    }

    // MARK: Context merging

    func testContextAttributesAreMergedIntoEveryEvent() {
        let (recorder, sink, _) = makeRecorder()
        recorder.recordEvent(name: "navigation", attributes: ["navigation.kind": "uikit"])
        recorder.flush(reason: .manual)
        let event = sink.envelopes.first?.events.first
        // sdk.* identity attrs are part of every emitted event.
        XCTAssertEqual(event?.attributes["sdk.platform"], .string("ios-native"))
        XCTAssertEqual(event?.attributes["sdk.version"], .string("1.0.0"))
        XCTAssertEqual(event?.attributes["navigation.kind"], .string("uikit"),
                       "Event-supplied attrs must survive the merge")
    }

    func testEventAttrsWinOnConflictWithContext() {
        let (recorder, sink, _) = makeRecorder()
        // sdk.version is a context-supplied key; if the event happens
        // to set the same key, the event wins.
        recorder.recordEvent(name: "navigation", attributes: ["sdk.version": "override"])
        recorder.flush(reason: .manual)
        let event = sink.envelopes.first?.events.first
        XCTAssertEqual(event?.attributes["sdk.version"], .string("override"))
    }

    // MARK: Envelope timestamps (T3.5)

    func testEnvelopeTimestampStampedAtFlushTime() {
        let (recorder, sink, clock) = makeRecorder()
        clock.set(Date(timeIntervalSince1970: 100))
        recorder.recordEvent(name: "navigation", attributes: [:])
        clock.set(Date(timeIntervalSince1970: 200))
        recorder.flush(reason: .manual)
        let env = sink.envelopes.first
        XCTAssertEqual(env?.timestamp, Date(timeIntervalSince1970: 200),
                       "Envelope timestamp must be flush time, not enqueue time")
        XCTAssertEqual(env?.events.first?.timestamp, Date(timeIntervalSince1970: 100),
                       "Per-event timestamp must be the moment of recordEvent()")
    }

    // MARK: Concurrency

    func testConcurrentEventsAreAllBuffered() {
        let (recorder, sink, _) = makeRecorder(batchSize: 10_000)
        let exp = expectation(description: "concurrent record")
        let total = 200
        DispatchQueue.concurrentPerform(iterations: total) { _ in
            recorder.recordEvent(name: "navigation", attributes: [:])
        }
        DispatchQueue.global().async { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
        recorder.flush(reason: .manual)
        XCTAssertEqual(sink.envelopes.flatMap { $0.events }.count, total)
    }
}
