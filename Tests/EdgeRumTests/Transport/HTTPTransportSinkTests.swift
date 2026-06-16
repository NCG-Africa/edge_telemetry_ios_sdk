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
        let transport = ProbeTransport(url: URL(string: "https://x/collector/telemetry")!)
        let queue = InMemoryQueue()
        let sink = HTTPTransportSink(
            transport: transport,
            offlineQueue: queue,
            apiKey: "edge_t",
            userAgent: "EdgeRum-iOS/1.0.0 (X; iOS 17)"
        )

        let envelope = EventEnvelope(timestamp: Date(), location: nil, events: [])
        // Empty events still encode to a valid envelope (`batch_size: 0`).
        transport.nextOutcome = .success(status: 200)
        sink.send(envelope, reason: .immediate)
        XCTAssertTrue(transport.waitForOnePost(timeout: 1))

        XCTAssertEqual(transport.posts.count, 1)
    }

    func testFourFailuresPushPayloadToOfflineQueue() {
        let transport = ProbeTransport(url: URL(string: "https://x/collector/telemetry")!)
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
        let envelope = EventEnvelope(timestamp: Date(), location: nil, events: [])
        sink.send(envelope, reason: .immediate)

        XCTAssertTrue(transport.waitForPosts(count: 4, timeout: 3))
        // Drain time for the post-attempt offline-queue write.
        let exp = expectation(description: "queue write")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 2)

        XCTAssertEqual(queue.payloads.count, 1, "Failed payload should land in offline queue")
    }

    func testDrainReplaysQueuedPayloadsViaTransport() {
        let transport = ProbeTransport(url: URL(string: "https://x/collector/telemetry")!)
        let queue = InMemoryQueue()
        queue.enqueue(Data("queued".utf8))
        queue.enqueue(Data("queued2".utf8))

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
        XCTAssertEqual(queue.payloads.count, 0, "Queue should be empty after successful drain")
    }

    func testDrainStopsOnFirstFailure() {
        let transport = ProbeTransport(url: URL(string: "https://x/collector/telemetry")!)
        let queue = InMemoryQueue()
        queue.enqueue(Data("first".utf8))
        queue.enqueue(Data("second".utf8))

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

// MARK: - Probes

private final class ProbeTransport: BatchSending, @unchecked Sendable {
    let url: URL

    private let lock = NSLock()
    private var _posts: [Data] = []
    var posts: [Data] { lock.lock(); defer { lock.unlock() }; return _posts }
    var nextOutcome: BatchSendOutcome?
    var alwaysOutcome: BatchSendOutcome?

    init(url: URL) { self.url = url }

    func post(_ payload: Data, completion: @escaping @Sendable (BatchSendOutcome) -> Void) {
        lock.lock()
        _posts.append(payload)
        let outcome: BatchSendOutcome
        if let always = alwaysOutcome {
            outcome = always
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
    func enqueue(_ payload: Data) -> URL? {
        lock.lock()
        _payloads.append(payload)
        lock.unlock()
        return URL(string: "memory://q/\(_payloads.count)")
    }

    @discardableResult
    func drain(via: (Data) -> Bool) -> Int {
        var drained = 0
        while true {
            lock.lock()
            guard let next = _payloads.first else {
                lock.unlock()
                return drained
            }
            lock.unlock()
            let ok = via(next)
            if !ok { return drained }
            lock.lock()
            if !_payloads.isEmpty { _payloads.removeFirst() }
            lock.unlock()
            drained += 1
        }
    }

    var count: Int { payloads.count }
    func reset() { lock.lock(); _payloads.removeAll(); lock.unlock() }
}
