import XCTest
@testable import EdgeRum
import EdgeRumCore

/// Unit tests for `EventEnvelope` — the load-bearing wire shape.
///
/// Refs: PLAN-iOS.md §7.2, §7.3, §7.4, §F3/T3.2.
final class EventEnvelopeTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_717_234_876.512)

    // MARK: Envelope structure

    func testEnvelopeTypeIsTelemetryBatch() throws {
        let env = EventEnvelope(timestamp: t0, deviceId: "device_1717234876123_a1b2c3d4e5f60718_ios", sdkVersion: "1.0.0", app: AppContext(), events: [])
        let json = try jsonObject(env)
        XCTAssertEqual(json["type"] as? String, "telemetry_batch")
    }

    func testEnvelopeBatchSizeMatchesEventsCount() throws {
        let events: [Event] = [
            .event(name: "navigation", timestamp: t0, attributes: AttributeBag()),
            .event(name: "http.request", timestamp: t0, attributes: AttributeBag()),
            .metric(name: "frame_render_time", value: 18.4, timestamp: t0, attributes: AttributeBag())
        ]
        let env = EventEnvelope(timestamp: t0, deviceId: "device_1717234876123_a1b2c3d4e5f60718_ios", sdkVersion: "1.0.0", app: AppContext(), events: events)
        let json = try jsonObject(env)
        XCTAssertEqual(json["batch_size"] as? Int, 3)
        XCTAssertEqual((json["events"] as? [Any])?.count, 3)
    }

    func testEnvelopeTimestampIsIso8601String() throws {
        let env = EventEnvelope(timestamp: t0, deviceId: "device_1717234876123_a1b2c3d4e5f60718_ios", sdkVersion: "1.0.0", app: AppContext(), events: [])
        let json = try jsonObject(env)
        let stamp = try XCTUnwrap(json["timestamp"] as? String)
        XCTAssertTrue(stamp.contains("."), "Timestamp must carry fractional seconds")
        XCTAssertTrue(stamp.hasSuffix("Z"), "Timestamp must terminate at UTC `Z`")
        XCTAssertNotNil(WireDateFormatter.date(from: stamp), "Round-trips through ISO formatter")
    }

    func testRootKeysAreExactlyTheContract4Set() throws {
        let env = EventEnvelope(timestamp: t0, deviceId: "device_1", sdkVersion: "1.0.0", app: AppContext(), events: [])
        let json = try jsonObject(env)
        XCTAssertEqual(
            Set(json.keys),
            ["type", "contract_version", "timestamp", "batch_size", "device_id", "sdk", "app", "events"]
        )
        XCTAssertEqual(json["contract_version"] as? String, "4.0.0")
    }

    /// R15 — no Info.plist key and no override: the key is absent, never "".
    func testNilAppVersionAndBuildNumberAreOmitted() throws {
        let env = EventEnvelope(
            timestamp: t0, deviceId: "device_1", sdkVersion: "1.0.0",
            app: AppContext(name: nil, packageName: "com.example.shop"), events: []
        )
        let app = try XCTUnwrap(jsonObject(env)["app"] as? [String: Any])
        XCTAssertEqual(Set(app.keys), ["package_name", "platform"])
    }

    /// R13 — UTC with `Z` whatever the process time zone.
    func testTimestampEndsInZUnderNonUTCTimeZone() throws {
        let saved = NSTimeZone.default
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Africa/Nairobi"))
        defer { NSTimeZone.default = saved }
        let env = EventEnvelope(timestamp: t0, deviceId: "device_1", sdkVersion: "1.0.0", app: AppContext(), events: [])
        let stamp = try XCTUnwrap(jsonObject(env)["timestamp"] as? String)
        XCTAssertEqual(stamp, "2024-06-01T09:41:16.512Z")
    }

    // MARK: Per-event shape

    func testEventCarriesEventNameAndTypeEvent() throws {
        let env = EventEnvelope(
            timestamp: t0,
            deviceId: "device_1717234876123_a1b2c3d4e5f60718_ios",
            sdkVersion: "1.0.0",
            app: AppContext(),
            events: [.event(name: "navigation", timestamp: t0, attributes: [
                "navigation.kind": "uikit",
                "navigation.screen": "Cart"
            ])]
        )
        let json = try jsonObject(env)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.first?["type"] as? String, "event")
        XCTAssertEqual(events.first?["eventName"] as? String, "navigation")
        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        XCTAssertEqual(attrs["navigation.kind"] as? String, "uikit")
        XCTAssertEqual(attrs["navigation.screen"] as? String, "Cart")
    }

    func testMetricCarriesMetricNameAndTypeMetric() throws {
        let env = EventEnvelope(
            timestamp: t0,
            deviceId: "device_1717234876123_a1b2c3d4e5f60718_ios",
            sdkVersion: "1.0.0",
            app: AppContext(),
            events: [.metric(name: "frame_render_time", value: 18.4, timestamp: t0, attributes: [
                "frame.target_hz": 60
            ])]
        )
        let json = try jsonObject(env)
        let metrics = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(metrics.first?["type"] as? String, "metric")
        XCTAssertEqual(metrics.first?["metricName"] as? String, "frame_render_time")
        XCTAssertEqual(metrics.first?["value"] as? Double, 18.4)
    }

    func testMetricValueOmittedWhenNil() throws {
        let env = EventEnvelope(
            timestamp: t0,
            deviceId: "device_1717234876123_a1b2c3d4e5f60718_ios",
            sdkVersion: "1.0.0",
            app: AppContext(),
            events: [.metric(name: "long_task", value: nil, timestamp: t0, attributes: AttributeBag())]
        )
        let json = try jsonObject(env)
        let metrics = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertNil(metrics.first?["value"], "Metric `value` must be omitted, not null")
    }

    // MARK: Helpers

    private func jsonObject(_ env: EventEnvelope) throws -> [String: Any] {
        let data = try JSONEncoder().encode(env)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
