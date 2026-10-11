// Tests/EdgeRumTests/Transport/BatchTransportTests.swift
//
// PLAN-iOS.md §F5/T5.1 — happy-path POST + header contract:
//
//   POST <endpoint, as given>
//   X-API-Key: <apiKey>           (must start with "edge_")
//   Content-Type: application/json
//   User-Agent: EdgeRum-iOS/<v> (<model>; iOS <os>)
//   X-Edge-Rum-Internal: 1
//   taskDescription = "edge-rum-internal"
//

import XCTest
@testable import EdgeRumCore

final class BatchTransportTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    func testEndpointIsUsedExactlyAsGiven() {
        for raw in ["https://h/collector-go/telemetry", "https://h/collector-go/telemetry/"] {
            let transport = BatchTransport(
                endpoint: URL(string: raw)!, apiKey: "edge_t", sdkVersion: "4.0.0",
                deviceModel: "iPhone15,3", osVersion: "17.4.1"
            )
            XCTAssertEqual(transport.url.absoluteString, raw)
        }
    }

    func testUserAgentShape() {
        let ua = BatchTransport.makeUserAgent(
            sdkVersion: "1.0.0",
            deviceModel: "iPhone15,3",
            osVersion: "17.4.1"
        )
        XCTAssertEqual(ua, "EdgeRum-iOS/1.0.0 (iPhone15,3; iOS 17.4.1)")
    }

    func testHappyPathPostSendsHeadersAndBody() throws {
        let endpoint = URL(string: "https://collect.example.com/collector-go/telemetry")!
        let session = MockURLProtocol.makeSession()
        let transport = BatchTransport(
            endpoint: endpoint,
            apiKey: "edge_test_abc",
            sdkVersion: "1.0.0",
            deviceModel: "iPhone15,3",
            osVersion: "17.4.1",
            session: session
        )

        let body = Data("{\"hello\":\"wire\"}".utf8)
        let exp = expectation(description: "post completes")
        var outcome: BatchSendOutcome?
        MockURLProtocol.responder = { _ in (200, nil, [:]) }
        transport.post(body) { o in
            outcome = o
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)

        if case let .success(status) = outcome {
            XCTAssertEqual(status, 200)
        } else {
            XCTFail("expected .success, got \(String(describing: outcome))")
        }

        let recorded = MockURLProtocol.recorded
        XCTAssertEqual(recorded.count, 1)
        let req = try XCTUnwrap(recorded.first)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "https://collect.example.com/collector-go/telemetry")

        XCTAssertEqual(req.value(forHTTPHeaderField: "X-API-Key"), "edge_test_abc")
        XCTAssertTrue(req.value(forHTTPHeaderField: "X-API-Key")?.hasPrefix("edge_") ?? false)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertTrue(
            req.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("EdgeRum-iOS/") ?? false
        )
        XCTAssertEqual(req.value(forHTTPHeaderField: BatchTransport.internalHeaderName), "1")

        let recordedBody = MockURLProtocol.requestBody(req)
        XCTAssertEqual(recordedBody, body)
    }

    func testFailureBranchExtractsRetryAfter() throws {
        let endpoint = URL(string: "https://collect.example.com")!
        let session = MockURLProtocol.makeSession()
        let transport = BatchTransport(
            endpoint: endpoint,
            apiKey: "edge_t",
            sdkVersion: "1.0.0",
            deviceModel: "iPhone15,3",
            osVersion: "17.4.1",
            session: session
        )

        MockURLProtocol.responder = { _ in (429, nil, ["Retry-After": "12"]) }
        let exp = expectation(description: "post completes")
        var outcome: BatchSendOutcome?
        transport.post(Data("x".utf8)) { o in
            outcome = o
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        if case let .failure(status, retryAfter) = outcome {
            XCTAssertEqual(status, 429)
            XCTAssertEqual(retryAfter, 12)
        } else {
            XCTFail("expected .failure")
        }
    }

    /// T5.1 acceptance: "Posting a 30-event batch produces a 200 and a
    /// single ACK." Verifies exactly one URLRequest is intercepted.
    func test30EventBatchProducesSingleAck() throws {
        let endpoint = URL(string: "https://collect.example.com")!
        let session = MockURLProtocol.makeSession()
        let transport = BatchTransport(
            endpoint: endpoint,
            apiKey: "edge_x",
            sdkVersion: "1.0.0",
            deviceModel: "iPhone15,3",
            osVersion: "17.4.1",
            session: session
        )

        // Build a 30-event envelope.
        var events: [Event] = []
        for i in 0..<30 {
            events.append(.event(
                name: "custom_event",
                timestamp: Date(),
                attributes: AttributeBag(["i": .int(i)])
            ))
        }
        let envelope = EventEnvelope(timestamp: Date(), deviceId: "device_1717234876123_a1b2c3d4e5f60718_ios", sdkVersion: "1.0.0", app: AppContext(), events: events)
        let body = try JSONEncoder().encode(envelope)

        var ackCount = 0
        let exp = expectation(description: "30-batch post")
        MockURLProtocol.responder = { _ in (200, nil, [:]) }
        transport.post(body) { outcome in
            if case .success = outcome { ackCount += 1 }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(ackCount, 1)
        XCTAssertEqual(MockURLProtocol.recorded.count, 1)
    }
}
