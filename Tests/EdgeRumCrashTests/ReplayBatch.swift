// Tests/EdgeRumCrashTests/ReplayBatch.swift
//
// #250 R14 fixtures: a live Recorder running build 2.0 (20), and a
// sidecar written by build 1.0 (10).

import XCTest
import EdgeRumCore

enum ReplayBatch {

    static let liveDeviceId = "device_1717234876123_a1b2c3d4e5f60718_ios"

    /// Build 2.0 (20), with one live event already buffered.
    static func liveRecorder() -> (Recorder, RecordingTransportSink) {
        let sink = RecordingTransportSink()
        let recorder = Recorder(
            clock: FixedClock(Date(timeIntervalSince1970: 1_717_234_876.512)),
            sampler: Sampler(sampleRate: 1.0, entropy: { 0.0 }),
            transport: sink,
            health: SdkHealth()
        )
        recorder.setEnabled(true)
        recorder.configure(RecorderConfig(
            apiKey: "edge_test_abc",
            endpoint: URL(string: "https://collect.example.com")!,
            appName: "Shop",
            appVersion: "2.0",
            appPackage: "com.example.shop",
            appBuild: "20",
            sdkVersion: "4.0.0"
        ))
        recorder.recordEvent(name: "navigation", attributes: ["navigation.kind": "uikit"])
        return (recorder, sink)
    }

    /// The identity build 1.0 (10) mirrored before it died.
    static func priorSidecar(build: Bool = true, name: Bool = true) -> [String: AttributeValue] {
        var prior: [String: AttributeValue] = [
            "session.id": .string("session_1717234870002_ff009988aabbccdd_ios"),
            "device.id": .string(liveDeviceId),
            "user.id": .string("user_1717100000000_deadbeefcafef00d"),
            "sdk.version": .string("2.0.0"),
            "app.version": .string("1.0")
        ]
        if build { prior["app.build_number"] = .string("10") }
        if name { prior["app.name"] = .string("Shop Classic") }
        return prior
    }

    static func json(_ envelope: EventEnvelope) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
    }

    /// The replay went out alone, on the saved build, with no
    /// `sdk.health`; the live event follows in its own batch on the
    /// current build.
    static func assertReplayBatch(
        _ sink: RecordingTransportSink,
        _ recorder: Recorder,
        eventName: String,
        app expectedApp: [String: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(sink.envelopes.count, 1, "the replay is sent at once, alone", file: file, line: line)
        let replay = try json(XCTUnwrap(sink.envelopes.first, file: file, line: line))
        let events = try XCTUnwrap(replay["events"] as? [[String: Any]], file: file, line: line)
        XCTAssertEqual(events.compactMap { $0["eventName"] as? String }, [eventName], file: file, line: line)
        XCTAssertEqual(replay["batch_size"] as? Int, 1, file: file, line: line)
        XCTAssertEqual(replay["app"] as? [String: String], expectedApp, file: file, line: line)
        XCTAssertEqual(replay["sdk"] as? [String: String], ["name": "ios", "version": "4.0.0"], file: file, line: line)
        XCTAssertEqual(replay["contract_version"] as? String, "4.0.0", file: file, line: line)
        XCTAssertEqual(replay["device_id"] as? String, recorder.currentDeviceId, file: file, line: line)
        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any], file: file, line: line)
        XCTAssertFalse(attrs.keys.contains { PayloadBuilder.isIdentityKey($0) }, "\(attrs.keys.sorted())", file: file, line: line)
        XCTAssertEqual(attrs["session.id"] as? String, "session_1717234870002_ff009988aabbccdd_ios", file: file, line: line)

        recorder.flush(reason: .manual)
        let live = try json(XCTUnwrap(sink.envelopes.last, file: file, line: line))
        let liveEvents = try XCTUnwrap(live["events"] as? [[String: Any]], file: file, line: line)
        XCTAssertEqual(liveEvents.compactMap { $0["eventName"] as? String }, ["navigation", "sdk.health"],
                       "the health counters ride the next live batch", file: file, line: line)
        XCTAssertEqual((live["app"] as? [String: String])?["version"], "2.0", file: file, line: line)
        XCTAssertEqual((live["app"] as? [String: String])?["build_number"], "20", file: file, line: line)
    }

    static let savedApp = [
        "name": "Shop Classic", "package_name": "com.example.shop", "platform": "ios",
        "version": "1.0", "build_number": "10"
    ]
}
