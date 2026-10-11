// Tests/EdgeRumContractTests/FailedSendPolicyTests.swift
//
// #252 R10 / R12 / R13 / R14 through the production send path:
//
//   Recorder.recordEvent / flush / recordReplayed
//     → HTTPTransportSink → BatchTransport (real URLSession)
//     → LocalHTTPStub on 127.0.0.1 answering scripted statuses
//     ↳ OfflineQueue in a temp directory
//
// Only the retry schedule is shortened (milliseconds, same shape).

import XCTest
@testable import EdgeRumCore

final class FailedSendPolicyTests: XCTestCase {

    private var stub: LocalHTTPStub!
    private var queueDir: URL!

    override func setUpWithError() throws {
        stub = try LocalHTTPStub()
        queueDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edge-rum-252-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: queueDir)
        stub = nil
    }

    // MARK: Rig

    private struct Rig {
        let recorder: Recorder
        let sink: HTTPTransportSink
        let queue: OfflineQueue
        let health: SdkHealth
    }

    private func makeRig(
        endpoint: URL,
        schedule: [TimeInterval] = [0, 0.01, 0.01, 0.01],
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws -> Rig {
        let health = SdkHealth()
        let transport = BatchTransport(
            endpoint: endpoint, apiKey: "edge_252", sdkVersion: "4.0.0",
            deviceModel: "iPhone15,3", osVersion: "17.4.1"
        )
        let queue = try XCTUnwrap(OfflineQueue(directory: queueDir, health: health))
        let sink = HTTPTransportSink(
            transport: transport, retryPolicy: RetryPolicy(schedule: schedule),
            offlineQueue: queue, apiKey: "edge_252", userAgent: "EdgeRum-iOS/4.0.0",
            pathObserver: nil, health: health, now: now
        )
        let recorder = Recorder(transport: sink, sdkVersion: "4.0.0", health: health)
        recorder.setEnabled(true)
        sink.attach(recorder: recorder)
        recorder.configure(RecorderConfig(
            apiKey: "edge_252", endpoint: endpoint, sampleRate: 1.0, batchSize: 30,
            appName: "Shop", appVersion: "4.0.0", appPackage: "com.example.shop", appBuild: "400",
            sdkVersion: "4.0.0"
        ))
        return Rig(recorder: recorder, sink: sink, queue: queue, health: health)
    }

    private func sendOne(_ rig: Rig, _ name: String = "e") {
        rig.recorder.recordEvent(name: "custom_event", attributes: ["event.name": .string(name)])
        rig.recorder.flush(reason: .manual)
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        return condition()
    }

    // MARK: R10 — endpoint used as given

    func testLiveSendAndReplayPostToTheConfiguredURLExactly() throws {
        for path in ["/collector-go/telemetry", "/collector-go/telemetry/"] {
            let endpoint = URL(string: stub.baseURL.absoluteString + path)!
            let rig = try makeRig(endpoint: endpoint)
            let before = stub.requests.count
            sendOne(rig)
            XCTAssertTrue(stub.waitForRequests(before + 1))
            rig.queue.enqueue(Data(#"{"type":"telemetry_batch"}"#.utf8), eventCount: 1)
            rig.sink.drainOfflineQueue()
            XCTAssertTrue(stub.waitForRequests(before + 2))
            XCTAssertEqual(stub.requests[before...].map(\.path), [path, path], "nothing appended to \(path)")
        }
    }
}
