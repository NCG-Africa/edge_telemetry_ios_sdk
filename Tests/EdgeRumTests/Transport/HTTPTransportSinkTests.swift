// Tests/EdgeRumTests/Transport/HTTPTransportSinkTests.swift
//
// Verifies the sink's wiring:
//   - 2xx invokes the Recorder's didAckBatch() (F4 carry-over #43).
//   - Four 503 responses move the payload into the offline queue.
//   - drainOfflineQueue() replays queued payloads.
//   - The encoded body matches what PayloadBuilder produced.
//

import XCTest
@testable import EdgeRumCore

final class HTTPTransportSinkTests: XCTestCase {

    func testSuccessfulSendCallsBackTransportAndDrainsQueue() {
        let transport = ProbeTransport(url: URL(string: "https://x/collector-go/telemetry")!)
        let queue = InMemoryQueue()
        let sink = HTTPTransportSink(
            transport: transport,
            offlineQueue: queue,
            apiKey: "edge_t",
            userAgent: "EdgeRum-iOS/1.0.0 (X; iOS 17)"
        )

        let envelope = EventEnvelope(timestamp: Date(), deviceId: "device_1717234876123_a1b2c3d4e5f60718_ios", sdkVersion: "1.0.0", app: AppContext(), events: [])
        // Empty events still encode to a valid envelope (`batch_size: 0`).
        transport.nextOutcome = .success(status: 200)
        sink.send(envelope, reason: .immediate)
        XCTAssertTrue(transport.waitForOnePost(timeout: 1))

        XCTAssertEqual(transport.posts.count, 1)
    }

    func testFourFailuresPushPayloadToOfflineQueue() {
        let transport = ProbeTransport(url: URL(string: "https://x/collector-go/telemetry")!)
        let queue = InMemoryQueue()
        // Drive the schedule fast — replace the 2/8/30 schedule with
        // sub-millisecond delays so the test runs in ~ms not 40s.
        let policy = RetryPolicy(schedule: [0, 0.001, 0.001, 0.001])
        let sink = HTTPTransportSink(
            transport: transport,
            retryPolicy: policy,
            offlineQueue: queue,
            apiKey: "edge_t",
            userAgent: "EdgeRum-iOS/1.0.0 (X; iOS 17)"
        )

        transport.alwaysOutcome = .failure(status: 503, retryAfter: nil)
        let envelope = EventEnvelope(timestamp: Date(), deviceId: "device_1717234876123_a1b2c3d4e5f60718_ios", sdkVersion: "1.0.0", app: AppContext(), events: [])
        sink.send(envelope, reason: .immediate)

        XCTAssertTrue(transport.waitForPosts(count: 4, timeout: 3))
        // Drain time for the post-attempt offline-queue write.
        let exp = expectation(description: "queue write")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 2)

        XCTAssertEqual(queue.payloads.count, 1, "Failed payload should land in offline queue")
    }

    func testDrainReplaysQueuedPayloadsViaTransport() {
        let transport = ProbeTransport(url: URL(string: "https://x/collector-go/telemetry")!)
        let queue = InMemoryQueue()
        queue.enqueue(Data("queued".utf8), eventCount: 1)
        queue.enqueue(Data("queued2".utf8), eventCount: 1)

        let sink = HTTPTransportSink(
            transport: transport,
            offlineQueue: queue,
            apiKey: "edge_t",
            userAgent: "EdgeRum-iOS/1.0.0 (X; iOS 17)",
            pathObserver: nil
        )
        transport.alwaysOutcome = .success(status: 200)
        sink.drainOfflineQueue()

        XCTAssertTrue(transport.waitForPosts(count: 2, timeout: 2))
        // The drain removes each file after its POST returns, so the last
        // removal trails the last post — wait for it, don't race it.
        let drained = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in queue.payloads.isEmpty }, object: nil)
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(queue.payloads.count, 0, "Queue should be empty after successful drain")
    }

    func testDrainStopsOnFirstFailure() {
        let transport = ProbeTransport(url: URL(string: "https://x/collector-go/telemetry")!)
        let queue = InMemoryQueue()
        queue.enqueue(Data("first".utf8), eventCount: 1)
        queue.enqueue(Data("second".utf8), eventCount: 1)

        let sink = HTTPTransportSink(
            transport: transport,
            offlineQueue: queue,
            apiKey: "edge_t",
            userAgent: "EdgeRum-iOS/1.0.0 (X; iOS 17)",
            pathObserver: nil
        )
        transport.alwaysOutcome = .failure(status: 503, retryAfter: nil)
        sink.drainOfflineQueue()

        // One post fired, then drain bailed out — second payload stays
        // on disk.
        XCTAssertTrue(transport.waitForOnePost(timeout: 1))
        let exp = expectation(description: "stable")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(transport.posts.count, 1)
        XCTAssertEqual(queue.payloads.count, 2)
    }
}

extension HTTPTransportSinkTests {

    /// #252 R12: a queued 400 is dropped (counted) instead of wedging
    /// the queue; the next file still goes; a 503 keeps its file.
    func testReplayDropsNonRetryableAndStopsOnRetryable() {
        let transport = ProbeTransport(url: URL(string: "https://x/collector-go/telemetry")!)
        let queue = InMemoryQueue()
        for p in ["a", "b", "c"] { queue.enqueue(Data(p.utf8), eventCount: 1) }
        let health = SdkHealth()
        let sink = HTTPTransportSink(
            transport: transport, offlineQueue: queue, apiKey: "edge_t",
            userAgent: "EdgeRum-iOS/4.0.0", pathObserver: nil, health: health
        )
        transport.scriptedOutcomes = [
            .failure(status: 400, retryAfter: nil), .success(status: 200), .failure(status: 503, retryAfter: nil),
        ]
        sink.drainOfflineQueue()

        XCTAssertTrue(transport.waitForPosts(count: 3, timeout: 2))
        waitUntil { queue.payloads.count == 1 }
        XCTAssertEqual(queue.payloads, [Data("c".utf8)])
        XCTAssertEqual(health.snapshot()["events_dropped.non_retryable"], .int(1))
        XCTAssertEqual(health.snapshot()["batches_uploaded"], .int(1))
    }
}

// MARK: - F32 health counters

extension HTTPTransportSinkTests {

    private func threeEvents() -> EventEnvelope {
        let e = Event.event(name: "navigation", timestamp: Date(), attributes: AttributeBag([:]))
        return EventEnvelope(timestamp: Date(), deviceId: "device_1717234876123_a1b2c3d4e5f60718_ios", sdkVersion: "1.0.0", app: AppContext(), events: [e, e, e])
    }

    private func waitUntil(_ condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }

    func testSuccessCountsEventsAndBatchesUploaded() {
        let transport = ProbeTransport(url: URL(string: "https://x/collector-go/telemetry")!)
        let health = SdkHealth()
        let sink = HTTPTransportSink(transport: transport, offlineQueue: InMemoryQueue(),
                                     apiKey: "edge_t", userAgent: "ua", pathObserver: nil, health: health)
        sink.send(threeEvents(), reason: .immediate)
        sink.send(threeEvents(), reason: .immediate)
        waitUntil { health.snapshot()["batches_uploaded"] == .int(2) }

        XCTAssertEqual(health.snapshot()["events_uploaded"], .int(6))
        XCTAssertNil(health.snapshot()["upload_failures"])
    }

    /// #250 R4: `batch_size` counts `sdk.health`; `events_uploaded` does not.
    func testEventsUploadedExcludesTheHealthEvent() {
        let transport = ProbeTransport(url: URL(string: "https://x/collector-go/telemetry")!)
        let health = SdkHealth()
        let sink = HTTPTransportSink(transport: transport, offlineQueue: InMemoryQueue(),
                                     apiKey: "edge_t", userAgent: "ua", pathObserver: nil, health: health)
        let e = Event.event(name: "navigation", timestamp: Date(), attributes: AttributeBag())
        let envelope = PayloadBuilder().build(
            events: [e, e, e],
            context: AttributeBag(["device.id": "device_1717234876123_a1b2c3d4e5f60718_ios"]),
            flushTime: Date(),
            health: ["events_generated": 3]
        )
        XCTAssertEqual(envelope.batchSize, 4)
        sink.send(envelope, reason: .immediate)
        waitUntil { health.snapshot()["batches_uploaded"] == .int(1) }

        XCTAssertEqual(health.snapshot()["events_uploaded"], .int(3))
    }

    func testProcessCountersCorrectWhenNineInTenUploadsFail() {
        let transport = ProbeTransport(url: URL(string: "https://x/collector-go/telemetry")!)
        let health = SdkHealth()
        let sink = HTTPTransportSink(transport: transport, offlineQueue: InMemoryQueue(),
                                     apiKey: "edge_t", userAgent: "ua", pathObserver: nil, health: health)
        transport.alwaysOutcome = .failure(status: 400, retryAfter: nil)
        for _ in 0..<9 { sink.send(threeEvents(), reason: .immediate) }
        waitUntil { health.snapshot()["upload_failures"] == .int(9) }
        transport.alwaysOutcome = nil
        sink.send(threeEvents(), reason: .immediate)
        waitUntil { health.snapshot()["batches_uploaded"] == .int(1) }

        let snap = health.snapshot()
        XCTAssertEqual(snap["events_dropped.non_retryable"], .int(27))
        XCTAssertEqual(snap["events_uploaded"], .int(3))
        XCTAssertEqual(snap["upload_failures"], .int(9))
    }

    func testNonRetryableCountsEventsAndFailure() {
        let transport = ProbeTransport(url: URL(string: "https://x/collector-go/telemetry")!)
        transport.alwaysOutcome = .failure(status: 400, retryAfter: nil)
        let health = SdkHealth()
        let sink = HTTPTransportSink(transport: transport, offlineQueue: InMemoryQueue(),
                                     apiKey: "edge_t", userAgent: "ua", pathObserver: nil, health: health)
        sink.send(threeEvents(), reason: .immediate)
        waitUntil { health.snapshot()["events_dropped.non_retryable"] != nil }

        XCTAssertEqual(health.snapshot()["events_dropped.non_retryable"], .int(3))
        XCTAssertEqual(health.snapshot()["upload_failures"], .int(1))
    }

    func testMissingOfflineQueueCountsEnqueueFailure() {
        let transport = ProbeTransport(url: URL(string: "https://x/collector-go/telemetry")!)
        transport.alwaysOutcome = .failure(status: 503, retryAfter: nil)
        let health = SdkHealth()
        let sink = HTTPTransportSink(transport: transport, retryPolicy: RetryPolicy(schedule: [0, 0.001, 0.001, 0.001]),
                                     offlineQueue: nil, apiKey: "edge_t", userAgent: "ua",
                                     pathObserver: nil, health: health)
        sink.send(threeEvents(), reason: .immediate)
        waitUntil { health.snapshot()["events_dropped.enqueue_failure"] != nil }

        XCTAssertEqual(health.snapshot()["events_dropped.enqueue_failure"], .int(3))
        XCTAssertEqual(health.snapshot()["upload_failures"], .int(4))
    }

    // MARK: R13 — re-stamped at send time (#250)

    private static func rootTimestamp(_ payload: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["timestamp"] as? String
    }

    func testQueuedBatchIsRestampedWhenSentNotReplayedWithItsStoredTime() throws {
        let transport = ProbeTransport(url: URL(string: "https://x/collector-go/telemetry")!)
        transport.alwaysOutcome = .failure(status: 503, retryAfter: nil)
        let queue = InMemoryQueue()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.512))
        let sink = HTTPTransportSink(transport: transport, retryPolicy: RetryPolicy(schedule: [0, 0.001, 0.001, 0.001]),
                                     offlineQueue: queue, apiKey: "edge_t", userAgent: "ua",
                                     pathObserver: nil, health: SdkHealth(), now: { clock.now })
        let event = Event.event(name: "navigation", timestamp: clock.now, attributes: AttributeBag())
        sink.send(PayloadBuilder().build(events: [event], context: AttributeBag(), flushTime: clock.now), reason: .immediate)
        waitUntil { queue.payloads.count == 1 }
        XCTAssertEqual(queue.payloads.first.flatMap(Self.rootTimestamp), "2024-06-01T09:41:16.512Z")

        clock.advance(by: 3_600)
        transport.alwaysOutcome = nil
        let before = transport.posts.count
        sink.drainOfflineQueue()
        XCTAssertTrue(transport.waitForPosts(count: before + 1, timeout: 3))

        let sent = try XCTUnwrap(transport.posts.last)
        XCTAssertEqual(Self.rootTimestamp(sent), "2024-06-01T10:41:16.512Z")
        let events = (try JSONSerialization.jsonObject(with: sent) as? [String: Any])?["events"] as? [[String: Any]]
        XCTAssertEqual(events?.first?["timestamp"] as? String, "2024-06-01T09:41:16.512Z", "event times are kept")
    }

    func testRetryAttemptsAreRestamped() throws {
        let transport = ProbeTransport(url: URL(string: "https://x/collector-go/telemetry")!)
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.512))
        transport.nextOutcome = .failure(status: 503, retryAfter: nil)
        let sink = HTTPTransportSink(transport: transport, retryPolicy: RetryPolicy(schedule: [0, 0.2, 0.2, 0.2]),
                                     offlineQueue: InMemoryQueue(), apiKey: "edge_t", userAgent: "ua",
                                     pathObserver: nil, health: SdkHealth(), now: { clock.now })
        sink.send(PayloadBuilder().build(events: [], context: AttributeBag(), flushTime: clock.now), reason: .immediate)
        XCTAssertTrue(transport.waitForOnePost(timeout: 3))
        clock.advance(by: 2)
        XCTAssertTrue(transport.waitForPosts(count: 2, timeout: 3))
        XCTAssertEqual(transport.posts.map { Self.rootTimestamp($0) }, ["2024-06-01T09:41:16.512Z", "2024-06-01T09:41:18.512Z"])
    }

    /// A `"timestamp":"` inside an attribute string is escaped, so only
    /// the root stamp changes.
    func testRestampIgnoresTimestampTextInsideStringValues() throws {
        let t0 = Date(timeIntervalSince1970: 1_717_234_876.512)
        let trap = #"{"timestamp":"1999-01-01T00:00:00.000Z"}"#
        let event = Event.event(name: "custom_event", timestamp: t0, attributes: AttributeBag(["note": .string(trap)]))
        let envelope = PayloadBuilder().build(events: [event], context: AttributeBag(), flushTime: t0)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let restamped = EventEnvelope.restamp(try enc.encode(envelope), at: t0.addingTimeInterval(60))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: restamped) as? [String: Any])
        XCTAssertEqual(root["timestamp"] as? String, "2024-06-01T09:42:16.512Z")
        let attrs = (root["events"] as? [[String: Any]])?.first?["attributes"] as? [String: Any]
        XCTAssertEqual(attrs?["note"] as? String, trap)
    }

    func testRestampLeavesLegacyPayloadsUntouched() {
        let legacy = Data(#"{"type":"telemetry_batch","timestamp":"2024-06-01T09:41:16.512Z","events":[]}"#.utf8)
        XCTAssertEqual(EventEnvelope.restamp(legacy, at: Date()), legacy)
    }

    func testUnencodableEnvelopeCountsEncodeFailure() {
        let transport = ProbeTransport(url: URL(string: "https://x/collector-go/telemetry")!)
        let health = SdkHealth()
        let sink = HTTPTransportSink(transport: transport, offlineQueue: InMemoryQueue(),
                                     apiKey: "edge_t", userAgent: "ua", pathObserver: nil, health: health)
        let nan = Event.event(name: "navigation", timestamp: Date(), attributes: AttributeBag(["x": .double(.nan)]))
        sink.send(EventEnvelope(timestamp: Date(), deviceId: "device_1717234876123_a1b2c3d4e5f60718_ios", sdkVersion: "1.0.0", app: AppContext(), events: [nan, nan]), reason: .immediate)
        waitUntil { health.snapshot()["events_dropped.encode_failure"] != nil }

        XCTAssertEqual(health.snapshot()["events_dropped.encode_failure"], .int(2))
        XCTAssertTrue(transport.posts.isEmpty)
    }
}

// MARK: - Probes

private final class ProbeTransport: BatchSending, @unchecked Sendable {
    let url: URL

    private let lock = NSLock()
    private var _posts: [Data] = []
    var posts: [Data] { lock.lock(); defer { lock.unlock() }; return _posts }
    var nextOutcome: BatchSendOutcome?
    var alwaysOutcome: BatchSendOutcome?
    var scriptedOutcomes: [BatchSendOutcome] = []

    init(url: URL) { self.url = url }

    func post(_ payload: Data, completion: @escaping @Sendable (BatchSendOutcome) -> Void) {
        lock.lock()
        _posts.append(payload)
        let outcome: BatchSendOutcome
        if let always = alwaysOutcome {
            outcome = always
        } else if !scriptedOutcomes.isEmpty {
            outcome = scriptedOutcomes.removeFirst()
        } else if let next = nextOutcome {
            outcome = next
            nextOutcome = nil
        } else {
            outcome = .success(status: 200)
        }
        lock.unlock()
        DispatchQueue.global().async { completion(outcome) }
    }

    func waitForOnePost(timeout: TimeInterval) -> Bool {
        waitForPosts(count: 1, timeout: timeout)
    }

    func waitForPosts(count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if posts.count >= count { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }
}

private final class InMemoryQueue: OfflineQueueing, @unchecked Sendable {
    private let lock = NSLock()
    private var _payloads: [Data] = []

    var payloads: [Data] {
        lock.lock(); defer { lock.unlock() }
        return _payloads
    }

    @discardableResult
    func enqueue(_ payload: Data, eventCount: Int) -> URL? {
        lock.lock()
        _payloads.append(payload)
        lock.unlock()
        return URL(string: "memory://q/\(_payloads.count)")
    }

    @discardableResult
    func drain(via: (Data, Int) -> DrainStep) -> Int {
        var drained = 0
        while true {
            lock.lock()
            guard let next = _payloads.first else {
                lock.unlock()
                return drained
            }
            lock.unlock()
            if via(next, 1) == .stop { return drained }
            lock.lock()
            if !_payloads.isEmpty { _payloads.removeFirst() }
            lock.unlock()
            drained += 1
        }
    }

    var count: Int { payloads.count }
    func reset() { lock.lock(); _payloads.removeAll(); lock.unlock() }
}
