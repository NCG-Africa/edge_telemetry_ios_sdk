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

    /// The batch's `sdk.health` event attributes (#250 R4: the counters
    /// moved off the envelope).
    private func json(_ envelope: EventEnvelope) throws -> [String: Any] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
        let health = try XCTUnwrap((root["events"] as? [[String: Any]])?.last)
        XCTAssertEqual(health["eventName"] as? String, "sdk.health")
        return try XCTUnwrap(health["attributes"] as? [String: Any])
    }

    // MARK: Acceptance — nine in ten envelopes dropped

    func testCountersMonotonicAndCorrectWhenNineInTenEnvelopesAreDropped() throws {
        let (recorder, sink) = makeRecorder(batchSize: 3)
        for i in 0..<30 {
            recorder.recordEvent(name: "navigation", attributes: [:])
            if i % 10 == 0 { recorder.recordEvent(name: "not.allowlisted", attributes: [:]) }
        }
        XCTAssertEqual(sink.envelopes.count, 10)

        let generated = try sink.envelopes.map { try XCTUnwrap(json($0)["events_generated"] as? Int) }
        XCTAssertEqual(generated, generated.sorted(), "cumulative totals never go down")

        // Only the tenth envelope lands: it alone tells the whole story.
        let landed = try json(sink.envelopes[9])
        XCTAssertEqual(landed["events_generated"] as? Int, 33)
        XCTAssertEqual(landed["events_dropped.unknown_name"] as? Int, 3)
    }

    // MARK: F34 — start cost

    func testStartStatsAbsentUntilSetThenOnEveryEnvelope() throws {
        let (recorder, sink) = makeRecorder(batchSize: 1)
        recorder.recordEvent(name: "navigation", attributes: [:])
        let before = try json(XCTUnwrap(sink.envelopes.last))
        XCTAssertNil(before["start_duration_ms"], "crash-replay envelope sent mid-start omits it")
        XCTAssertNil(before["start_replayed_crash"])

        recorder.setStartStats(durationMs: 42, replayedCrash: true)
        recorder.recordEvent(name: "navigation", attributes: [:])
        recorder.recordEvent(name: "navigation", attributes: [:])
        for envelope in sink.envelopes.suffix(2) {
            let env = try json(envelope)
            XCTAssertEqual(env["start_duration_ms"] as? Int, 42)
            XCTAssertEqual(env["start_replayed_crash"] as? Bool, true)
        }
    }

    func testUnreadableStartDurationOmittedNeverZero() throws {
        let (recorder, sink) = makeRecorder(batchSize: 1)
        recorder.setStartStats(durationMs: nil, replayedCrash: false)
        recorder.recordEvent(name: "navigation", attributes: [:])
        let env = try json(XCTUnwrap(sink.envelopes.last))
        XCTAssertNil(env["start_duration_ms"])
        XCTAssertEqual(env["start_replayed_crash"] as? Bool, false)
    }

    func testSampledOutSessionCountsDropsAndReportsOnForcedEmit() throws {
        let (recorder, sink) = makeRecorder(sampleRate: 0.0)
        for _ in 0..<5 { recorder.recordEvent(name: "navigation", attributes: [:]) }
        recorder.recordPerformance(name: "memory_usage", attributes: [:])
        XCTAssertTrue(sink.envelopes.isEmpty, "unsampled session uploads nothing on its own")

        recorder.recordEvent(name: "app.crash", attributes: [:])  // forced, flushes
        let env = try json(XCTUnwrap(sink.envelopes.last))
        XCTAssertEqual(env["events_dropped.sampled"] as? Int, 6)
        XCTAssertEqual(env["events_generated"] as? Int, 7)
    }

    func testMarkersOmittedWhenZeroRequiredCountersAlwaysPresent() throws {
        let (recorder, sink) = makeRecorder()
        recorder.recordEvent(name: "navigation", attributes: [:])
        recorder.flush(reason: .manual)
        let env = try json(XCTUnwrap(sink.envelopes.last))

        for key in ["events_generated", "events_uploaded", "batches_uploaded",
                    "queue_depth_max", "storage_bytes_max"] {
            XCTAssertNotNil(env[key] as? Int, "\(key) is required")
        }
        for key in ["events_dropped.sampled", "events_dropped.unknown_name",
                    "upload_failures", "events_dropped.queue_overflow",
                    "events_dropped.encode_failure", "events_dropped.non_retryable",
                    "events_dropped.enqueue_failure", "capabilities_failed"] {
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

        XCTAssertEqual(env["events_uploaded"] as? Int, 42)
        XCTAssertEqual(env["queue_depth_max"] as? Int, 7, "high-water mark, never lowered")
        XCTAssertEqual(env["capabilities_failed"] as? String, "crash_reporter,hang_observer")
    }

    func testQueueMarksOmittedWhenOfflineQueueFailed() {
        let health = SdkHealth()
        health.fail(.offlineQueue)
        let snap = health.snapshot()
        XCTAssertNil(snap["queue_depth_max"])
        XCTAssertNil(snap["storage_bytes_max"])
        XCTAssertEqual(snap["events_uploaded"], .int(0))
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
        XCTAssertEqual(finalized["events_generated"] as? Int, 11, "prior session keeps its own total")
        let next = try json(XCTUnwrap(sink.envelopes.last))
        XCTAssertEqual(next["events_generated"] as? Int, 2, "session.started + navigation")
        XCTAssertEqual(next["batches_uploaded"] as? Int, 5)
    }

    func testStartRotationFinalizedCarriesEndingSessionTotals() throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.000))
        let (recorder, sink) = makeRecorder(clock: clock)
        for _ in 0..<4 { recorder.recordEvent(name: "navigation", attributes: [:]) }

        clock.advance(by: SessionManager.idleRotationInterval + 1)
        recorder.start(apiKey: "edge_test_abc", endpoint: URL(string: "https://collect.example.com")!, debug: false)
        recorder.flush(reason: .manual)

        let finalized = try json(XCTUnwrap(sink.envelopes.first))
        XCTAssertEqual(finalized["events_generated"] as? Int, 5, "4 navigation + session.finalized")
        XCTAssertEqual(try json(XCTUnwrap(sink.envelopes.last))["events_generated"] as? Int, 1)
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
        XCTAssertEqual(env["events_generated"] as? Int, 1)
        XCTAssertNil(env["events_dropped.unknown_name"])
    }

    // MARK: _buffer cap

    func testBufferBoundedByDesignConstant() {
        let (recorder, sink) = makeRecorder(batchSize: 10_000_000)
        for _ in 0..<(Recorder.maxBufferedEvents + 1) {
            recorder.recordEvent(name: "navigation", attributes: [:])
        }
        XCTAssertEqual(sink.envelopes.first?.recordedEvents.count, Recorder.maxBufferedEvents)
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
        XCTAssertEqual(try json(XCTUnwrap(sink.envelopes.last))["capabilities_failed"] as? String, "keychain")
    }
}
