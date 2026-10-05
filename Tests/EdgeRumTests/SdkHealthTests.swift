// Tests/EdgeRumTests/SdkHealthTests.swift
//
// F32 / #219 — RUM coverage tranche 7 ("SDK health").
//
//   Cumulative counters on the batch envelope: session-scoped on the
//   Recorder, process-scoped in `SdkHealth`. Markers omitted when zero.
//   `_buffer` bounded by `Recorder.maxBufferedEvents`. `keychain`
//   capability from `deviceIdFromFallback`.
//
// Transport and offline-queue counters are pinned in
// `Transport/HTTPTransportSinkTests.swift` / `OfflineQueueTests.swift`;
// the forced swizzle failure in `EdgeRumCaptureTests/SwizzleTests.swift`.
//
// Refs: docs/specs/rum-coverage-roadmap.md § Tranche 7.

import XCTest
import EdgeRumCore

final class SdkHealthTests: XCTestCase {

    private func makeRecorder(
        batchSize: Int = 1_000,
        sampleRate: Double = 1.0,
        health: SdkHealth = SdkHealth(),
        clock: FixedClock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.000))
    ) -> (Recorder, RecordingTransportSink) {
        let sink = RecordingTransportSink()
        let recorder = Recorder(
            clock: clock,
            sessionManager: SessionManager(store: InMemorySessionStore(), clock: clock),
            sampler: Sampler(sampleRate: sampleRate),
            transport: sink,
            sdkVersion: "1.0.0",
            health: health
        )
        recorder.configure(RecorderConfig(
            apiKey: "edge_test_abc",
            endpoint: URL(string: "https://collect.example.com")!,
            sampleRate: sampleRate,
            batchSize: batchSize
        ))
        recorder.setEnabled(true)
        return (recorder, sink)
    }

    private func json(_ envelope: EventEnvelope) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
    }

    // MARK: Acceptance — nine in ten envelopes dropped

    func testCountersMonotonicAndCorrectWhenNineInTenEnvelopesAreDropped() throws {
        let (recorder, sink) = makeRecorder(batchSize: 3)
        for i in 0..<30 {
            recorder.recordEvent(name: "navigation", attributes: [:])
            if i % 10 == 0 { recorder.recordEvent(name: "not.allowlisted", attributes: [:]) }
        }
        XCTAssertEqual(sink.envelopes.count, 10)

        let generated = try sink.envelopes.map { try XCTUnwrap(json($0)["sdk.events_generated"] as? Int) }
        XCTAssertEqual(generated, generated.sorted(), "cumulative totals never go down")

        // Only the tenth envelope lands: it alone tells the whole story.
        let landed = try json(sink.envelopes[9])
        XCTAssertEqual(landed["sdk.events_generated"] as? Int, 33)
        XCTAssertEqual(landed["sdk.events_dropped.unknown_name"] as? Int, 3)
    }

    // MARK: F34 — start cost

    func testStartStatsAbsentUntilSetThenOnEveryEnvelope() throws {
        let (recorder, sink) = makeRecorder(batchSize: 1)
        recorder.recordEvent(name: "navigation", attributes: [:])
        let before = try json(XCTUnwrap(sink.envelopes.last))
        XCTAssertNil(before["sdk.start_duration_ms"], "crash-replay envelope sent mid-start omits it")
        XCTAssertNil(before["sdk.start_replayed_crash"])

        recorder.setStartStats(durationMs: 42, replayedCrash: true)
        recorder.recordEvent(name: "navigation", attributes: [:])
        recorder.recordEvent(name: "navigation", attributes: [:])
        for envelope in sink.envelopes.suffix(2) {
            let env = try json(envelope)
            XCTAssertEqual(env["sdk.start_duration_ms"] as? Int, 42)
            XCTAssertEqual(env["sdk.start_replayed_crash"] as? Bool, true)
        }
    }

    func testUnreadableStartDurationOmittedNeverZero() throws {
        let (recorder, sink) = makeRecorder(batchSize: 1)
        recorder.setStartStats(durationMs: nil, replayedCrash: false)
        recorder.recordEvent(name: "navigation", attributes: [:])
        let env = try json(XCTUnwrap(sink.envelopes.last))
        XCTAssertNil(env["sdk.start_duration_ms"])
        XCTAssertEqual(env["sdk.start_replayed_crash"] as? Bool, false)
    }

    func testSampledOutSessionCountsDropsAndReportsOnForcedEmit() throws {
        let (recorder, sink) = makeRecorder(sampleRate: 0.0)
        for _ in 0..<5 { recorder.recordEvent(name: "navigation", attributes: [:]) }
        recorder.recordPerformance(name: "memory_usage", attributes: [:])
        XCTAssertTrue(sink.envelopes.isEmpty, "unsampled session uploads nothing on its own")

        recorder.recordEvent(name: "app.crash", attributes: [:])  // forced, flushes
        let env = try json(XCTUnwrap(sink.envelopes.last))
        XCTAssertEqual(env["sdk.events_dropped.sampled"] as? Int, 6)
        XCTAssertEqual(env["sdk.events_generated"] as? Int, 7)
    }

    func testMarkersOmittedWhenZeroRequiredCountersAlwaysPresent() throws {
        let (recorder, sink) = makeRecorder()
        recorder.recordEvent(name: "navigation", attributes: [:])
        recorder.flush(reason: .manual)
        let env = try json(XCTUnwrap(sink.envelopes.last))

        for key in ["sdk.events_generated", "sdk.events_uploaded", "sdk.batches_uploaded",
                    "sdk.queue_depth_max", "sdk.storage_bytes_max"] {
            XCTAssertNotNil(env[key] as? Int, "\(key) is required")
        }
        for key in ["sdk.events_dropped.sampled", "sdk.events_dropped.unknown_name",
                    "sdk.upload_failures", "sdk.events_dropped.queue_overflow",
                    "sdk.events_dropped.encode_failure", "sdk.events_dropped.non_retryable",
                    "sdk.events_dropped.enqueue_failure", "sdk.capabilities_failed"] {
            XCTAssertNil(env[key], "\(key) is a marker — omitted when zero")
        }
    }

    func testProcessCountersRideTheEnvelope() throws {
        let health = SdkHealth()
        health.add(.eventsUploaded, 42)
        health.raise(.queueDepthMax, to: 7)
        health.raise(.queueDepthMax, to: 3)
        health.fail(.hangObserver)
        health.fail(.crashReporter)
        health.fail(.hangObserver)
        let (recorder, sink) = makeRecorder(health: health)
        recorder.recordEvent(name: "navigation", attributes: [:])
        recorder.flush(reason: .manual)
        let env = try json(XCTUnwrap(sink.envelopes.last))

        XCTAssertEqual(env["sdk.events_uploaded"] as? Int, 42)
        XCTAssertEqual(env["sdk.queue_depth_max"] as? Int, 7, "high-water mark, never lowered")
        XCTAssertEqual(env["sdk.capabilities_failed"] as? String, "crash_reporter,hang_observer")
    }

    func testQueueMarksOmittedWhenOfflineQueueFailed() {
        let health = SdkHealth()
        health.fail(.offlineQueue)
        let snap = health.snapshot()
        XCTAssertNil(snap["sdk.queue_depth_max"])
        XCTAssertNil(snap["sdk.storage_bytes_max"])
        XCTAssertEqual(snap["sdk.events_uploaded"], .int(0))
    }

    func testSessionCountersResetOnRotationProcessCountersDoNot() throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.000))
        let health = SdkHealth()
        health.add(.batchesUploaded, 5)
        let (recorder, sink) = makeRecorder(health: health, clock: clock)
        for _ in 0..<10 { recorder.recordEvent(name: "navigation", attributes: [:]) }

        clock.advance(by: SessionManager.idleRotationInterval + 1)
        recorder.recordEvent(name: "navigation", attributes: [:])
        recorder.flush(reason: .manual)

        let finalized = try json(XCTUnwrap(sink.envelopes.first))
        XCTAssertEqual(finalized["sdk.events_generated"] as? Int, 11, "prior session keeps its own total")
        let next = try json(XCTUnwrap(sink.envelopes.last))
        XCTAssertEqual(next["sdk.events_generated"] as? Int, 2, "session.started + navigation")
        XCTAssertEqual(next["sdk.batches_uploaded"] as? Int, 5)
    }

    func testStartRotationFinalizedCarriesEndingSessionTotals() throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.000))
        let (recorder, sink) = makeRecorder(clock: clock)
        for _ in 0..<4 { recorder.recordEvent(name: "navigation", attributes: [:]) }

        clock.advance(by: SessionManager.idleRotationInterval + 1)
        recorder.start(apiKey: "edge_test_abc", endpoint: URL(string: "https://collect.example.com")!, debug: false)
        recorder.flush(reason: .manual)

        let finalized = try json(XCTUnwrap(sink.envelopes.first))
        XCTAssertEqual(finalized["sdk.events_generated"] as? Int, 5, "4 navigation + session.finalized")
        XCTAssertEqual(try json(XCTUnwrap(sink.envelopes.last))["sdk.events_generated"] as? Int, 1)
    }

    func testNothingCountedWhileDisabled() throws {
        let (recorder, sink) = makeRecorder()
        recorder.setEnabled(false)
        recorder.recordEvent(name: "navigation", attributes: [:])
        recorder.recordEvent(name: "not.allowlisted", attributes: [:])
        recorder.recordPerformance(name: "not_a_metric", attributes: [:])
        recorder.setEnabled(true)
        recorder.recordEvent(name: "navigation", attributes: [:])
        recorder.flush(reason: .manual)

        let env = try json(XCTUnwrap(sink.envelopes.last))
        XCTAssertEqual(env["sdk.events_generated"] as? Int, 1)
        XCTAssertNil(env["sdk.events_dropped.unknown_name"])
    }

    // MARK: _buffer cap

    func testBufferBoundedByDesignConstant() {
        let (recorder, sink) = makeRecorder(batchSize: 10_000_000)
        for _ in 0..<(Recorder.maxBufferedEvents + 1) {
            recorder.recordEvent(name: "navigation", attributes: [:])
        }
        XCTAssertEqual(sink.envelopes.first?.events.count, Recorder.maxBufferedEvents)
    }

    // MARK: keychain capability

    func testDeviceIdFromFallbackMarksKeychainCapability() throws {
        let health = SdkHealth()
        let (recorder, sink) = makeRecorder(health: health)
        recorder.installPersistedStores(
            identityProvider: IdentityProvider(
                keychain: InMemoryKeychainStore(failure: .unexpectedStatus(-25300)),
                defaults: InMemoryUserDefaultsStore()
            ),
            sessionStore: InMemorySessionStore(),
            sidecar: nil
        )
        recorder.recordEvent(name: "navigation", attributes: [:])
        recorder.flush(reason: .manual)
        XCTAssertEqual(try json(XCTUnwrap(sink.envelopes.last))["sdk.capabilities_failed"] as? String, "keychain")
    }
}
