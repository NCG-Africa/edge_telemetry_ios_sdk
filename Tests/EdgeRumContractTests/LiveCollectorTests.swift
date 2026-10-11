// Tests/EdgeRumContractTests/LiveCollectorTests.swift
//
// #250 end-to-end: one real batch through the production transport to
// a running collector. Skipped unless EDGE_RUM_E2E_ENDPOINT and
// EDGE_RUM_E2E_API_KEY are set; prints the device_id and app version to
// look up on the backend.

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
}
