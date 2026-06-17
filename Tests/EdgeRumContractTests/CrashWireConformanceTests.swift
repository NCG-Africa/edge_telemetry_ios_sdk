// Tests/EdgeRumContractTests/CrashWireConformanceTests.swift
//
// Wire-conformance coverage for the `app.crash` event produced by
// PLCrashIntegration replay. Constructs the same attribute bag the
// replay path would emit, builds an envelope via `PayloadBuilder`,
// and runs it through `WireAssertions.assertValidEnvelope` so we
// fail loud if the envelope ever drifts from the EdgeTelemetryProcessor
// contract.
//
// Refs: PLAN-iOS.md §F14/T14.3, §13.4; CLAUDE.md "Testing conventions".
//

import XCTest
import EdgeRumCore

final class CrashWireConformanceTests: XCTestCase {

    func testReplayedCrashEnvelopeHonoursWireContract() throws {
        let now = Date(timeIntervalSince1970: 1_717_234_876.512)

        // Hand-built attributes match what `PLCrashIntegration` would
        // produce after merging the encoder output with the sidecar
        // identity. The `crash.report_json` string is small here so
        // the envelope stays compact; size truncation is exercised in
        // `CrashReportEncoderTests`.
        let attrs: [String: AttributeValue] = [
            "cause": .string("NativeCrash"),
            "runtime": .string("native"),
            "crash.fatal": .bool(true),
            "crash.report_format_version": .string("edgerum.crash.v1"),
            "crash.signal": .string("SIGSEGV"),
            "crash.signal_code": .string("SEGV_MAPERR"),
            "crash.binary_uuid": .string("00112233-4455-6677-8899-AABBCCDDEEFF"),
            "crash.binary_name": .string("EdgeRumCrashSampleApp"),
            "crash.report_json": .string("{\"format_version\":\"edgerum.crash.v1\",\"threads\":[]}"),
            // Identity overrides from the sidecar.
            "session.id": .string("session_1717234870002_ff009988aabbccdd_ios"),
            "session.start_time": .string("2026-06-14T10:25:00.002Z"),
            "session.sequence": .int(42),
            "device.id": .string("device_1717234876123_a1b2c3d4e5f60718_ios"),
            "user.id": .string("user_1717100000000_deadbeefcafef00d")
        ]

        let event = Event.event(name: "app.crash", timestamp: now,
                                attributes: AttributeBag(attrs))

        // Minimal context so envelope-level identity prefixes resolve.
        var context = AttributeBag()
        context.set("session.id", .string("session_0_0000000000000000_ios"))
        context.set("device.id", .string("device_0_0000000000000000_ios"))
        context.set("sdk.platform", .string("ios-native"))
        context.set("sdk.version", .string("1.0.0"))
        // App / device wire-required keys (some are checked by the
        // WireAssertions helper indirectly via the forbidden-token
        // grep).
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

        let builder = PayloadBuilder()
        let envelope = builder.build(
            events: [event],
            context: context,
            location: "Nairobi/Kenya",
            flushTime: now
        )

        try WireAssertions.assertValidEnvelope(envelope)

        // Now assert the crash-specific fields survive encode/decode.
        let data = try JSONEncoder().encode(envelope)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        let event0 = try XCTUnwrap(events.first)
        XCTAssertEqual(event0["eventName"] as? String, "app.crash")
        let evAttrs = try XCTUnwrap(event0["attributes"] as? [String: Any])
        XCTAssertEqual(evAttrs["cause"] as? String, "NativeCrash")
        XCTAssertEqual(evAttrs["runtime"] as? String, "native")
        XCTAssertEqual(evAttrs["crash.fatal"] as? Bool, true)
        XCTAssertEqual(evAttrs["crash.report_format_version"] as? String, "edgerum.crash.v1")

        // Event-level identity OVERRIDES the context, as required for
        // a replayed crash (per PLAN-iOS §6.7, §8.4).
        XCTAssertEqual(evAttrs["session.id"] as? String,
                       "session_1717234870002_ff009988aabbccdd_ios")
        XCTAssertEqual(evAttrs["device.id"] as? String,
                       "device_1717234876123_a1b2c3d4e5f60718_ios")
    }
}
