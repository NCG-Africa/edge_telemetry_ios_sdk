// Tests/EdgeRumContractTests/LiveCollectorTests.swift
//
// #250 end-to-end: one real batch through the production transport to
// a running collector. Skipped unless EDGE_RUM_E2E_ENDPOINT and
// EDGE_RUM_E2E_API_KEY are set; prints the device_id and app version to
// look up on the backend.
//
// #252 R12 against the same collector:
//   EDGE_RUM_E2E_REVOKED_API_KEY  a revoked key → 401 → dropped, not queued.
//   EDGE_RUM_E2E_NOT_READY=1      restart the collector as the test starts;
//                                 it waits for the not-ready 503, sends,
//                                 sees it queued, then replays until 2xx.

import XCTest
import EdgeRum
import EdgeRumCore

final class LiveCollectorTests: XCTestCase {

    func testOneBatchIsAcceptedByALiveCollector() throws {
        let env = ProcessInfo.processInfo.environment
        guard let endpoint = env["EDGE_RUM_E2E_ENDPOINT"].flatMap(URL.init(string:)),
              let apiKey = env["EDGE_RUM_E2E_API_KEY"] else {
            throw XCTSkip("set EDGE_RUM_E2E_ENDPOINT and EDGE_RUM_E2E_API_KEY")
        }
        let appVersion = env["EDGE_RUM_E2E_APP_VERSION"] ?? "4.0.0-e2e"
        let health = SdkHealth()
        let transport = BatchTransport(
            endpoint: endpoint, apiKey: apiKey, sdkVersion: EdgeRum.sdkVersion,
            deviceModel: "iPhone15,3", osVersion: "17.4.1", debug: true
        )
        let sink = HTTPTransportSink(
            transport: transport, offlineQueue: nil, apiKey: apiKey, userAgent: "EdgeRum-iOS/e2e",
            debug: true, pathObserver: nil, health: health
        )
        let recorder = Recorder(transport: sink, health: health)
        recorder.setEnabled(true)
        recorder.configure(RecorderConfig(
            apiKey: apiKey, endpoint: endpoint,
            appName: "Shop E2E", appVersion: appVersion,
            appPackage: env["EDGE_RUM_E2E_PACKAGE"] ?? "com.example.shop", appBuild: "250",
            sdkVersion: EdgeRum.sdkVersion
        ))
        recorder.recordEvent(name: "custom_event", attributes: ["event.name": "e2e_250"])
        recorder.flush(reason: .manual)

        let deadline = Date().addingTimeInterval(15)
        while health.snapshot()["batches_uploaded"] != .int(1), health.snapshot()["upload_failures"] == nil,
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        print("[e2e] device_id=\(recorder.currentDeviceId) app.version=\(appVersion) health=\(health.snapshot())")
        XCTAssertEqual(health.snapshot()["batches_uploaded"], .int(1), "collector must answer 2xx")
        XCTAssertNil(health.snapshot()["upload_failures"])
    }

    // MARK: #252 R12

    private struct Rig {
        let recorder: Recorder
        let sink: HTTPTransportSink
        let sender: RecordingSender
        let queue: OfflineQueue
        let health: SdkHealth
    }

    private func makeRig(endpoint: URL, apiKey: String) throws -> Rig {
        let health = SdkHealth()
        let sender = RecordingSender(BatchTransport(
            endpoint: endpoint, apiKey: apiKey, sdkVersion: EdgeRum.sdkVersion,
            deviceModel: "iPhone15,3", osVersion: "17.4.1", debug: true
        ))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("edge-rum-e2e-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let queue = try XCTUnwrap(OfflineQueue(directory: dir, debug: true, health: health))
        // One attempt, then the offline queue: the queue is what's under test.
        let sink = HTTPTransportSink(
            transport: sender, retryPolicy: RetryPolicy(schedule: [0]), offlineQueue: queue,
            apiKey: apiKey, userAgent: "EdgeRum-iOS/e2e", debug: true, pathObserver: nil, health: health
        )
        let recorder = Recorder(transport: sink, health: health)
        recorder.setEnabled(true)
        sink.attach(recorder: recorder)
        recorder.configure(RecorderConfig(
            apiKey: apiKey, endpoint: endpoint, appName: "Shop E2E", appVersion: "4.0.0-e2e",
            appPackage: ProcessInfo.processInfo.environment["EDGE_RUM_E2E_PACKAGE"] ?? "com.example.shop",
            appBuild: "252", sdkVersion: EdgeRum.sdkVersion
        ))
        return Rig(recorder: recorder, sink: sink, sender: sender, queue: queue, health: health)
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        return condition()
    }

    func testRevokedKeyIsDroppedNotQueued() throws {
        let env = ProcessInfo.processInfo.environment
        guard let endpoint = env["EDGE_RUM_E2E_ENDPOINT"].flatMap(URL.init(string:)),
              let revoked = env["EDGE_RUM_E2E_REVOKED_API_KEY"] else {
            throw XCTSkip("set EDGE_RUM_E2E_ENDPOINT and EDGE_RUM_E2E_REVOKED_API_KEY")
        }
        let rig = try makeRig(endpoint: endpoint, apiKey: revoked)
        rig.recorder.recordEvent(name: "custom_event", attributes: ["event.name": "e2e_252_revoked"])
        rig.recorder.flush(reason: .manual)

        XCTAssertTrue(waitUntil(15) { rig.health.snapshot()["events_dropped.non_retryable"] != nil })
        Thread.sleep(forTimeInterval: 0.5)
        print("[e2e] revoked: outcomes=\(rig.sender.outcomes) health=\(rig.health.snapshot())")
        XCTAssertEqual(rig.sender.outcomes, [.failure(status: 401, retryAfter: nil)])
        XCTAssertEqual(rig.queue.count, 0, "a 401 is never queued")
    }

    func testNotReadyCollectorBatchIsQueuedThenDelivered() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["EDGE_RUM_E2E_NOT_READY"] == "1",
              let endpoint = env["EDGE_RUM_E2E_ENDPOINT"].flatMap(URL.init(string:)),
              let apiKey = env["EDGE_RUM_E2E_API_KEY"] else {
            throw XCTSkip("set EDGE_RUM_E2E_NOT_READY=1, EDGE_RUM_E2E_ENDPOINT and EDGE_RUM_E2E_API_KEY")
        }
        // Wait for the restarting collector's not-ready window. The probe
        // body is not JSON, so a ready collector answers 400 and writes nothing.
        XCTAssertTrue(waitUntil(90) { Self.probe(endpoint, apiKey) == 503 }, "collector never answered 503 not-ready")

        let rig = try makeRig(endpoint: endpoint, apiKey: apiKey)
        rig.recorder.recordEvent(name: "custom_event", attributes: ["event.name": "e2e_252_not_ready"])
        rig.recorder.flush(reason: .manual)
        XCTAssertTrue(waitUntil(15) { rig.queue.count == 1 }, "503 → queued")
        guard case .failure(503, _)? = rig.sender.outcomes.first else {
            return XCTFail("first send must hit the 503 window, got \(rig.sender.outcomes)")
        }

        let delivered = waitUntil(90) {
            rig.sink.drainOfflineQueue()
            Thread.sleep(forTimeInterval: 1)
            return rig.queue.count == 0
        }
        print("[e2e] not-ready: device_id=\(rig.recorder.currentDeviceId) outcomes=\(rig.sender.outcomes) health=\(rig.health.snapshot())")
        XCTAssertTrue(delivered, "queued batch delivered once the collector is ready")
        XCTAssertEqual(rig.health.snapshot()["batches_uploaded"], .int(1))
        if case .success? = rig.sender.outcomes.last {} else { XCTFail("last outcome must be 2xx") }
    }

    private static func probe(_ endpoint: URL, _ apiKey: String) -> Int {
        var request = URLRequest(url: endpoint, timeoutInterval: 2)
        request.httpMethod = "POST"
        request.httpBody = Data("not-json".utf8)
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        let done = DispatchSemaphore(value: 0)
        let status = StatusBox()
        URLSession.shared.dataTask(with: request) { _, response, _ in
            status.value = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.signal()
        }.resume()
        done.wait()
        return status.value
    }
}

private final class StatusBox: @unchecked Sendable { var value = 0 }

/// Production `BatchTransport`, plus a record of every outcome it saw.
private final class RecordingSender: BatchSending, @unchecked Sendable {
    private let inner: BatchTransport
    private let lock = NSLock()
    private var _outcomes: [BatchSendOutcome] = []
    var url: URL { inner.url }
    var outcomes: [BatchSendOutcome] { lock.lock(); defer { lock.unlock() }; return _outcomes }

    init(_ inner: BatchTransport) { self.inner = inner }

    func post(_ payload: Data, completion: @escaping @Sendable (BatchSendOutcome) -> Void) {
        inner.post(payload) { [self] outcome in
            lock.lock(); _outcomes.append(outcome); lock.unlock()
            completion(outcome)
        }
    }
}
