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
        let env = EventEnvelope(timestamp: t0, location: nil, events: [])
        let json = try jsonObject(env)
        XCTAssertEqual(json["type"] as? String, "telemetry_batch")
    }

    func testEnvelopeBatchSizeMatchesEventsCount() throws {
        let events: [Event] = [
            .event(name: "navigation", timestamp: t0, attributes: AttributeBag()),
            .event(name: "http.request", timestamp: t0, attributes: AttributeBag()),
            .metric(name: "frame_render_time", value: 18.4, timestamp: t0, attributes: AttributeBag())
        ]
        let env = EventEnvelope(timestamp: t0, location: nil, events: events)
        let json = try jsonObject(env)
        XCTAssertEqual(json["batch_size"] as? Int, 3)
        XCTAssertEqual((json["events"] as? [Any])?.count, 3)
    }

    func testEnvelopeTimestampIsIso8601String() throws {
        let env = EventEnvelope(timestamp: t0, location: nil, events: [])
        let json = try jsonObject(env)
        let stamp = try XCTUnwrap(json["timestamp"] as? String)
        XCTAssertTrue(stamp.contains("."), "Timestamp must carry fractional seconds")
        XCTAssertTrue(stamp.hasSuffix("Z"), "Timestamp must terminate at UTC `Z`")
        XCTAssertNotNil(WireDateFormatter.date(from: stamp), "Round-trips through ISO formatter")
    }

    func testLocationOmittedWhenNil() throws {
        let env = EventEnvelope(timestamp: t0, location: nil, events: [])
        let json = try jsonObject(env)
        XCTAssertNil(json["location"], "Optional location must be omitted, not null")
    }

    func testLocationEncodedWhenPresent() throws {
        let env = EventEnvelope(timestamp: t0, location: "Nairobi/Kenya", events: [])
        let json = try jsonObject(env)
        XCTAssertEqual(json["location"] as? String, "Nairobi/Kenya")
    }

    // MARK: Per-event shape

    func testEventCarriesEventNameAndTypeEvent() throws {
        let env = EventEnvelope(
            timestamp: t0,
            location: nil,
            events: [.event(name: "navigation", timestamp: t0, attributes: [
                "navigation.kind": "uikit",
                "navigation.name": "Cart"
            ])]
        )
        let json = try jsonObject(env)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.first?["type"] as? String, "event")
        XCTAssertEqual(events.first?["eventName"] as? String, "navigation")
        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        XCTAssertEqual(attrs["navigation.kind"] as? String, "uikit")
        XCTAssertEqual(attrs["navigation.name"] as? String, "Cart")
    }

    func testMetricCarriesMetricNameAndTypeMetric() throws {
        let env = EventEnvelope(
            timestamp: t0,
            location: nil,
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
            location: nil,
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
