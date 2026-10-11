// Tests/EdgeRumContractTests/Contract4EnvelopeTests.swift
//
// #250 — contract 4.0.0 batch envelope, asserted on the encoded JSON a
// real `Recorder` hands its `TransportSink`.
//
// Refs: #250 R1–R4, R7, R8, R13–R15, S1.

import XCTest
import EdgeRumCore

final class Contract4EnvelopeTests: XCTestCase {

    private let flushTime = Date(timeIntervalSince1970: 1_717_234_876.512)

    private func makeRecorder(
        appVersion: String? = "2.1.0",
        appBuild: String? = "412"
    ) -> (Recorder, RecordingTransportSink, FixedClock) {
        let clock = FixedClock(flushTime)
        let sink = RecordingTransportSink()
        let recorder = Recorder(
            clock: clock,
            sampler: Sampler(sampleRate: 1.0, entropy: { 0.0 }),
            transport: sink,
            health: SdkHealth()
        )
        recorder.setEnabled(true)
        recorder.configure(RecorderConfig(
            apiKey: "edge_test_abc",
            endpoint: URL(string: "https://collect.example.com")!,
            appName: "Shop",
            appVersion: appVersion,
            appPackage: "com.example.shop",
            appBuild: appBuild,
            sdkVersion: "9.9.9"
        ))
        return (recorder, sink, clock)
    }

    private func json(_ envelope: EventEnvelope) throws -> [String: Any] {
        let data = try JSONEncoder().encode(envelope)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func flushOne(
        _ recorder: Recorder,
        _ sink: RecordingTransportSink,
        attributes: [String: AttributeValue] = ["event.name": "checkout"]
    ) throws -> [String: Any] {
        recorder.recordEvent(name: "custom_event", attributes: attributes)
        recorder.flush(reason: .manual)
        return try json(XCTUnwrap(sink.envelopes.last))
    }

    // MARK: Root

    func testRootHasExactlyTheEightContractKeys() throws {
        let (recorder, sink, _) = makeRecorder()
        let root = try flushOne(recorder, sink)
        XCTAssertEqual(
            Set(root.keys),
            ["type", "contract_version", "timestamp", "batch_size", "device_id", "sdk", "app", "events"]
        )
    }

    func testContractVersionSdkAndAppPlatform() throws {
        let (recorder, sink, _) = makeRecorder()
        let root = try flushOne(recorder, sink)
        XCTAssertEqual(root["type"] as? String, "telemetry_batch")
        XCTAssertEqual(root["contract_version"] as? String, "4.0.0")
        let sdk = try XCTUnwrap(root["sdk"] as? [String: String])
        XCTAssertEqual(sdk, ["name": "ios", "version": "9.9.9"])
        let app = try XCTUnwrap(root["app"] as? [String: String])
        XCTAssertEqual(app, [
            "name": "Shop",
            "package_name": "com.example.shop",
            "platform": "ios",
            "version": "2.1.0",
            "build_number": "412"
        ])
    }

    func testDeviceIdAtRootEqualsTheRecordersDeviceId() throws {
        let (recorder, sink, _) = makeRecorder()
        let root = try flushOne(recorder, sink)
        let deviceId = try XCTUnwrap(root["device_id"] as? String)
        XCTAssertEqual(deviceId, recorder.currentDeviceId)
        XCTAssertTrue(IdentityFormat.isValid(deviceId, kind: .device))
    }

    /// R15 — nil version / build is omitted, never `""`.
    func testNilVersionAndBuildAreOmitted() throws {
        let (recorder, sink, _) = makeRecorder(appVersion: nil, appBuild: nil)
        // The test bundle's Info.plist may carry its own keys; pin nil.
        recorder.currentContextProvider.refreshApp(AppContext(name: "Shop", packageName: "com.example.shop"))
        let root = try flushOne(recorder, sink)
        let app = try XCTUnwrap(root["app"] as? [String: Any])
        XCTAssertNil(app["version"])
        XCTAssertNil(app["build_number"])
        XCTAssertEqual(app["platform"] as? String, "ios")
    }

    // MARK: Events carry no identity (R1)

    func testNoEventCarriesAppSdkOrDeviceIdIdentity() throws {
        let (recorder, sink, _) = makeRecorder()
        // Caller-supplied copies are ignored too: the envelope wins.
        let root = try flushOne(recorder, sink, attributes: [
            "event.name": "checkout",
            "app.version": "evil",
            "app.name": "evil",
            "sdk.version": "evil",
            "sdk.platform": "evil",
            "device.id": "evil"
        ])
        XCTAssertEqual((root["app"] as? [String: Any])?["version"] as? String, "2.1.0")
        XCTAssertEqual((root["sdk"] as? [String: Any])?["version"] as? String, "9.9.9")
        let events = try XCTUnwrap(root["events"] as? [[String: Any]])
        for event in events {
            let attrs = try XCTUnwrap(event["attributes"] as? [String: Any])
            for key in attrs.keys {
                XCTAssertFalse(Self.isIdentityKey(key), "event \(event["eventName"] ?? "?") carries \(key)")
            }
        }
        let custom = try XCTUnwrap(events.first { $0["eventName"] as? String == "custom_event" })
        let attrs = try XCTUnwrap(custom["attributes"] as? [String: Any])
        XCTAssertEqual(attrs["event.name"] as? String, "checkout")
        XCTAssertNotNil(attrs["session.id"], "non-identity context still rides each event")
        XCTAssertNotNil(attrs["device.platform"], "only device.id leaves the event, not device.*")
    }

    /// Non-identity `app.*` keys (rider, storage context) stay on events.
    func testNonIdentityAppKeysStayOnEvents() throws {
        let (recorder, sink, _) = makeRecorder()
        let root = try flushOne(recorder, sink, attributes: [
            "event.name": "checkout",
            "app.state": "active",
            "app.background_refresh": "available"
        ])
        let events = try XCTUnwrap(root["events"] as? [[String: Any]])
        let custom = try XCTUnwrap(events.first { $0["eventName"] as? String == "custom_event" })
        let attrs = try XCTUnwrap(custom["attributes"] as? [String: Any])
        XCTAssertEqual(attrs["app.state"] as? String, "active")
        XCTAssertEqual(attrs["app.background_refresh"] as? String, "available")
    }

    // MARK: Location + environment (R7, R8)

    func testNoLocationOrEnvironmentAnywhere() throws {
        let (recorder, sink, _) = makeRecorder()
        let root = try flushOne(recorder, sink)
        let raw = try XCTUnwrap(String(data: JSONEncoder().encode(XCTUnwrap(sink.envelopes.last)), encoding: .utf8))
        XCTAssertNil(root["location"])
        XCTAssertFalse(raw.contains("app.environment"))
        XCTAssertFalse(raw.contains("ios-native"))
        XCTAssertFalse(raw.contains("sdk.platform"))
    }

    // MARK: sdk.health (R4)

    func testHealthIsOneLastEventCountedInBatchSizeAndStampedAtFlush() throws {
        let (recorder, sink, clock) = makeRecorder()
        recorder.recordEvent(name: "custom_event", attributes: ["event.name": "a"])
        clock.advance(by: 2.0)
        recorder.recordEvent(name: "custom_event", attributes: ["event.name": "b"])
        clock.advance(by: 3.0)
        recorder.flush(reason: .manual)
        let root = try json(XCTUnwrap(sink.envelopes.last))
        let events = try XCTUnwrap(root["events"] as? [[String: Any]])
        XCTAssertEqual(root["batch_size"] as? Int, events.count)
        XCTAssertEqual(events.filter { $0["eventName"] as? String == "sdk.health" }.count, 1)
        let health = try XCTUnwrap(events.last)
        XCTAssertEqual(health["eventName"] as? String, "sdk.health")
        XCTAssertEqual(health["type"] as? String, "event")
        XCTAssertEqual(health["timestamp"] as? String, root["timestamp"] as? String)
        XCTAssertEqual(health["timestamp"] as? String, WireDateFormatter.string(from: clock.now))
    }

    func testHealthAttributesDropTheSdkPrefixAndCarryEveryCounter() throws {
        let (recorder, sink, _) = makeRecorder()
        recorder.recordEvent(name: "not_allowed", attributes: [:])
        recorder.setStartStats(durationMs: 12, replayedCrash: true)
        let root = try flushOne(recorder, sink)
        let events = try XCTUnwrap(root["events"] as? [[String: Any]])
        let attrs = try XCTUnwrap(events.last?["attributes"] as? [String: Any])
        XCTAssertFalse(attrs.keys.contains { $0.hasPrefix("sdk.") }, "\(attrs.keys.sorted())")
        for key in [
            "events_uploaded", "batches_uploaded", "queue_depth_max", "storage_bytes_max",
            "thread_time_ms", "events_generated", "events_dropped.unknown_name",
            "start_duration_ms", "start_replayed_crash"
        ] {
            XCTAssertNotNil(attrs[key], key)
        }
        XCTAssertEqual(attrs["events_dropped.unknown_name"] as? Int, 1)
        XCTAssertEqual(attrs["start_duration_ms"] as? Int, 12)
        XCTAssertNotNil(attrs["session.id"], "session-scoped counters stay attributable")
    }

    // MARK: Helpers

    static let identityAppKeys: Set<String> = [
        "app.name", "app.package_name", "app.version", "app.build_number", "app.environment", "app.platform"
    ]

    static func isIdentityKey(_ key: String) -> Bool {
        key == "device.id" || key.hasPrefix("sdk.") || identityAppKeys.contains(key)
    }
}
