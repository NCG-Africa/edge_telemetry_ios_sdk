// Tests/EdgeRumContractTests/TransportConformanceTests.swift
//
// End-to-end wire conformance over the F5 transport layer:
//
//   Recorder.recordEvent
//     → Recorder.flush (envelope built via PayloadBuilder)
//     → HTTPTransportSink.send
//     → BatchTransport.post (intercepted by mock URLProtocol)
//     → 2xx → Recorder.didAckBatch → session.sequence++
//
// Closes F4 carry-over #43: three consecutive ACKed batches result in
// `session.sequence == 3` on the next emitted event.
//

import XCTest
@testable import EdgeRumCore

final class TransportConformanceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ContractMockURLProtocol.reset()
    }

    func testRecorderToHttpSinkProducesWireValidEnvelope() throws {
        let endpoint = URL(string: "https://collect.example.com")!
        let session = ContractMockURLProtocol.makeSession()
        let transport = BatchTransport(
            endpoint: endpoint,
            apiKey: "edge_contract_test",
            sdkVersion: "1.0.0",
            deviceModel: "iPhone15,3",
            osVersion: "17.4.1",
            session: session
        )
        let sink = HTTPTransportSink(
            transport: transport,
            offlineQueue: nil,
            apiKey: "edge_contract_test",
            userAgent: "EdgeRum-iOS/1.0.0 (iPhone15,3; iOS 17.4.1)",
            pathObserver: nil
        )

        let recorder = Recorder(
            transport: sink,
            sdkVersion: "1.0.0"
        )
        sink.attach(recorder: recorder)
        recorder.configure(RecorderConfig(
            apiKey: "edge_contract_test",
            endpoint: endpoint,
            sampleRate: 1.0,
            batchSize: 30
        ))
        recorder.start(apiKey: "edge_contract_test", endpoint: endpoint, debug: false)

        ContractMockURLProtocol.responder = { _ in (200, nil, [:]) }

        for i in 0..<30 {
            recorder.recordEvent(name: "custom_event", attributes: [
                "event.name": .string("contract_\(i)")
            ])
        }
        // batchSize=30 should have triggered a flush. Wait for the
        // POST to land in the mock protocol.
        XCTAssertTrue(ContractMockURLProtocol.waitForRequests(count: 1, timeout: 3))

        let request = try XCTUnwrap(ContractMockURLProtocol.recorded.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let apiKey = try XCTUnwrap(request.value(forHTTPHeaderField: "X-API-Key"))
        XCTAssertTrue(apiKey.hasPrefix("edge_"),
                      "X-API-Key must start with \"edge_\", got \(apiKey)")

        let body = try XCTUnwrap(ContractMockURLProtocol.requestBody(request))
        // Round-trip through `WireAssertions` by reconstructing the
        // envelope shape.
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["type"] as? String, "telemetry_batch")
        XCTAssertEqual(json["batch_size"] as? Int, 30)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 30)
        let firstAttrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        XCTAssertEqual(firstAttrs["sdk.platform"] as? String, "ios-native")
    }

    /// F4 carry-over #43 acceptance: every successful 2xx response
    /// advances `session.sequence` exactly once. We verify the
    /// invariant by sending a stream of events and asserting the
    /// `SessionManager` ends at the expected counter rather than
    /// reading a specific event's wire value (which is unavoidably
    /// racy in a fully-async transport).
    func testEverySuccessfulAckAdvancesSessionSequence() throws {
        let endpoint = URL(string: "https://collect.example.com")!
        let session = ContractMockURLProtocol.makeSession()
        let transport = BatchTransport(
            endpoint: endpoint,
            apiKey: "edge_x",
            sdkVersion: "1.0.0",
            deviceModel: "iPhone15,3",
            osVersion: "17.4.1",
            session: session
        )
        let sink = HTTPTransportSink(
            transport: transport,
            offlineQueue: nil,
            apiKey: "edge_x",
            userAgent: "EdgeRum-iOS/1.0.0 (iPhone15,3; iOS 17.4.1)",
            pathObserver: nil
        )
        let sharedSessionStore = InMemorySessionStore()
        let recorder = Recorder(
            sessionManager: SessionManager(store: sharedSessionStore),
            transport: sink,
            sdkVersion: "1.0.0"
        )
        sink.attach(recorder: recorder)
        recorder.configure(RecorderConfig(
            apiKey: "edge_x",
            endpoint: endpoint,
            sampleRate: 1.0,
            batchSize: 1
        ))
        recorder.start(apiKey: "edge_x", endpoint: endpoint, debug: false)

        ContractMockURLProtocol.responder = { _ in (200, nil, [:]) }

        // `start()` emits a session.started event which is the first
        // batch — track every subsequent custom event.
        for _ in 0..<3 {
            recorder.recordEvent(name: "custom_event", attributes: [:])
        }
        // 4 total POSTs: session.started + 3 customs.
        XCTAssertTrue(ContractMockURLProtocol.waitForRequests(count: 4, timeout: 3))

        // Allow the ACK chain to propagate.
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settle.fulfill() }
        wait(for: [settle], timeout: 2)

        let state = try XCTUnwrap(sharedSessionStore.load())
        XCTAssertEqual(state.sequence, 4,
                       "Four 2xx responses must increment session.sequence to 4")
    }
}

// MARK: - Mock URLProtocol shared with the contract suite.

final class ContractMockURLProtocol: URLProtocol {

    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> (Int, Data?, [String: String])) = { _ in
        (200, nil, [:])
    }

    private static let recordedLock = NSLock()
    nonisolated(unsafe) private static var _recorded: [URLRequest] = []

    static var recorded: [URLRequest] {
        recordedLock.lock(); defer { recordedLock.unlock() }
        return _recorded
    }

    static func reset() {
        recordedLock.lock()
        _recorded.removeAll()
        recordedLock.unlock()
        responder = { _ in (200, nil, [:]) }
    }

    static func waitForRequests(count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if recorded.count >= count { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recordedLock.lock()
        Self._recorded.append(self.request)
        Self.recordedLock.unlock()
        let (status, body, headers) = Self.responder(self.request)
        let url = request.url ?? URL(string: "https://invalid.test/")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ContractMockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    static func requestBody(_ req: URLRequest) -> Data? {
        if let body = req.httpBody { return body }
        guard let stream = req.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
