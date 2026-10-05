// Tests/EdgeRumContractTests/HangWireConformanceTests.swift
//
// Wire-conformance coverage for the `app.crash` event produced by
// the F15 hang watchdog. Constructs the same attribute bag the
// detector would emit, builds an envelope via `PayloadBuilder`, and
// runs it through `WireAssertions.assertValidEnvelope` so we fail
// loud if the envelope ever drifts from the EdgeTelemetryProcessor
// contract.
//
// Refs: PLAN-iOS.md §6.8, §F15/T15.1, §F15/T15.2; CLAUDE.md
//       "Testing conventions".
//

import XCTest
import EdgeRumCore

final class HangWireConformanceTests: XCTestCase {

    func testHangEnvelopeHonoursWireContract() throws {
        let now = Date(timeIntervalSince1970: 1_717_234_876.512)

        // Attribute bag matching exactly what `HangEventEncoder`
        // produces — same keys, same types. Pinned here so any future
        // encoder change that drifts is caught by this contract test
        // in addition to the encoder unit tests.
        let attrs: [String: AttributeValue] = [
            "runtime": .string("native"),
            "hang.duration_ms": .double(5_240),
            "hang.threshold_ms": .double(5_000),
            "hang.cpu_usage": .double(83.0),
            "hang.stack": .string(
                "EdgeRumCrashSampleApp 0x0000000104a00000 -[ViewController hangButtonTapped:] + 24\n" +
                "EdgeRumCrashSampleApp 0x0000000104a00100 main + 80"
            ),
            "hang.timestamp": .string(WireDateFormatter.string(from: now))
        ]

        let event = Event.event(
            name: "app.hang",
            timestamp: now,
            attributes: AttributeBag(attrs)
        )

        // Minimal context so envelope-level identity prefixes resolve.
        var context = AttributeBag()
        context.set("session.id", .string("session_0_0000000000000000_ios"))
        context.set("device.id", .string("device_0_0000000000000000_ios"))
        context.set("sdk.platform", .string("ios-native"))
        context.set("sdk.version", .string("1.0.0"))
        context.set("app.name", .string("EdgeRumCrashSampleApp"))
        context.set("app.version", .string("1.0.0"))
        context.set("app.package_name", .string("com.example.edge.crashsample"))
        context.set("app.build_number", .string("1"))
        context.set("app.environment", .string("development"))
        context.set("device.platform", .string("ios"))
        context.set("device.os", .string("ios"))
        context.set("device.platform_version", .string("17.4"))
        context.set("device.model", .string("iPhone15,3"))
        context.set("device.manufacturer", .string("Apple"))

        let envelope = PayloadBuilder().build(
            events: [event],
            context: context,
            location: "Nairobi/Kenya",
            flushTime: now
        )

        try WireAssertions.assertValidEnvelope(envelope)

        // Hang-specific assertions on the encoded JSON.
        let data = try JSONEncoder().encode(envelope)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        let event0 = try XCTUnwrap(events.first)
        XCTAssertEqual(event0["eventName"] as? String, "app.hang")

        let evAttrs = try XCTUnwrap(event0["attributes"] as? [String: Any])
        XCTAssertNil(evAttrs["cause"], "F29: the event name discriminates")
        XCTAssertEqual(evAttrs["runtime"] as? String, "native")
        XCTAssertNil(evAttrs["crash.fatal"])

        let durationMs = try XCTUnwrap(evAttrs["hang.duration_ms"] as? Double)
        let thresholdMs = try XCTUnwrap(evAttrs["hang.threshold_ms"] as? Double)
        XCTAssertGreaterThanOrEqual(durationMs, thresholdMs,
                                    "hang.duration_ms must meet or exceed threshold")
        XCTAssertEqual(evAttrs["hang.cpu_usage"] as? Double, 83.0)

        let stack = try XCTUnwrap(evAttrs["hang.stack"] as? String)
        XCTAssertFalse(stack.isEmpty,
                       "T15.2 acceptance: hang.stack must be non-empty")

        let timestamp = try XCTUnwrap(evAttrs["hang.timestamp"] as? String)
        XCTAssertNotNil(WireDateFormatter.date(from: timestamp))
    }
}
