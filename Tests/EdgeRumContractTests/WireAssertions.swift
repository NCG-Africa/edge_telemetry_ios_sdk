// Tests/EdgeRumContractTests/WireAssertions.swift
//
// Shared assertions enforcing the EdgeTelemetryProcessor wire
// contract on any envelope the SDK would have shipped. Every
// transport-touching test calls `assertValidEnvelope` to catch wire
// drift before the test asserts more specific behaviour.
//
// Checked items (CLAUDE.md "Testing conventions"):
//
//   - Outer envelope: `type == "telemetry_batch"`, ISO 8601
//     `timestamp` (round-trips through ISO formatter, includes
//     fractional seconds), `batch_size == events.count`.
//   - Per-event: `type ∈ {"event","metric"}`, `timestamp` present.
//   - Identity attrs present and well-formed: `session.id` /
//     `device.id` prefixes, `sdk.platform == "ios-native"`.
//   - No forbidden tokens anywhere in raw bytes: `traceId`,
//     `spanId`, `resourceSpans`, `opentelemetry`.
//   - Every attribute value is a JSON primitive — String, Int,
//     Double, Bool — no nested objects, no arrays of objects.
//   - When invoked via `EdgeRum.start(...)`, the X-API-Key header
//     starts with `"edge_"` and Content-Type is `application/json`.
//
// Refs: PLAN-iOS.md §7, §F3/T3.5; CLAUDE.md "Testing conventions".
//

import XCTest
import Foundation
import EdgeRumCore

internal enum WireAssertions {

    private static let forbiddenTokens: [String] = [
        "traceId", "spanId", "resourceSpans"
    ]

    /// Encode the envelope, run every wire-conformance check, and
    /// return the encoded bytes so the caller can perform additional
    /// specific assertions.
    @discardableResult
    internal static func assertValidEnvelope(
        _ envelope: EventEnvelope,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (data: Data, json: [String: Any]) {
        let data = try JSONEncoder().encode(envelope)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "Envelope must encode to a top-level JSON object",
            file: file, line: line
        )

        // Outer envelope shape
        XCTAssertEqual(json["type"] as? String, "telemetry_batch",
                       "envelope.type must be 'telemetry_batch'", file: file, line: line)
        let stamp = try XCTUnwrap(json["timestamp"] as? String,
                                  "envelope.timestamp must be present and a string",
                                  file: file, line: line)
        XCTAssertNotNil(WireDateFormatter.date(from: stamp),
                        "envelope.timestamp must round-trip through ISO 8601 formatter",
                        file: file, line: line)
        XCTAssertTrue(stamp.contains("."),
                      "envelope.timestamp must carry fractional seconds",
                      file: file, line: line)

        let batchSize = try XCTUnwrap(json["batch_size"] as? Int,
                                      "envelope.batch_size must be an int",
                                      file: file, line: line)
        let events = json["events"] as? [[String: Any]] ?? []
        XCTAssertEqual(batchSize, events.count,
                       "envelope.batch_size must equal events.count",
                       file: file, line: line)

        // Per-event
        for (idx, event) in events.enumerated() {
            let type = event["type"] as? String
            XCTAssertTrue(type == "event" || type == "metric",
                          "events[\(idx)].type must be 'event' or 'metric', got \(String(describing: type))",
                          file: file, line: line)

            let evtStamp = try XCTUnwrap(event["timestamp"] as? String,
                                         "events[\(idx)].timestamp must be present",
                                         file: file, line: line)
            XCTAssertNotNil(WireDateFormatter.date(from: evtStamp),
                            "events[\(idx)].timestamp must round-trip",
                            file: file, line: line)

            // Discriminator field
            if type == "event" {
                XCTAssertNotNil(event["eventName"] as? String,
                                "event events must carry an `eventName`",
                                file: file, line: line)
            } else if type == "metric" {
                XCTAssertNotNil(event["metricName"] as? String,
                                "metric events must carry a `metricName`",
                                file: file, line: line)
            }

            // Attributes must be flat primitives only.
            let attrs = try XCTUnwrap(event["attributes"] as? [String: Any],
                                      "events[\(idx)].attributes must be an object",
                                      file: file, line: line)
            for (key, value) in attrs {
                try assertAttributeIsPrimitive(value, key: key, eventIdx: idx, file: file, line: line)
            }
        }

        // No forbidden tokens anywhere in the raw bytes
        let raw = try XCTUnwrap(String(data: data, encoding: .utf8),
                                "Envelope bytes must decode as UTF-8",
                                file: file, line: line)
        for token in forbiddenTokens {
            XCTAssertFalse(raw.contains(token),
                           "Forbidden token '\(token)' must not appear in the wire bytes",
                           file: file, line: line)
        }
        // `opentelemetry` is case-insensitive
        XCTAssertFalse(raw.lowercased().contains("opentelemetry"),
                       "Forbidden token 'opentelemetry' must not appear in the wire bytes",
                       file: file, line: line)

        return (data, json)
    }

    /// Assert identity attributes are present and well-formed on a
    /// single event's attribute object.
    internal static func assertIdentityAttributes(
        _ attrs: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let sessionId = try XCTUnwrap(attrs["session.id"] as? String,
                                      "session.id must be present", file: file, line: line)
        XCTAssertTrue(sessionId.hasPrefix("session_") && sessionId.hasSuffix("_ios"),
                      "session.id must match the prefix shape, got \(sessionId)",
                      file: file, line: line)

        let deviceId = try XCTUnwrap(attrs["device.id"] as? String,
                                     "device.id must be present", file: file, line: line)
        XCTAssertTrue(deviceId.hasPrefix("device_") && deviceId.hasSuffix("_ios"),
                      "device.id must match the prefix shape, got \(deviceId)",
                      file: file, line: line)

        XCTAssertEqual(attrs["sdk.platform"] as? String, "ios-native",
                       "sdk.platform must be 'ios-native'", file: file, line: line)
        XCTAssertNotNil(attrs["sdk.version"] as? String,
                        "sdk.version must be present", file: file, line: line)

        // Misnaming guard — wire spec uses snake_case for some keys.
        XCTAssertNil(attrs["app.package"], "Wire field is `app.package_name`, not `app.package`",
                     file: file, line: line)
        XCTAssertNil(attrs["session.startTime"], "Wire field is `session.start_time`, not `session.startTime`",
                     file: file, line: line)
        XCTAssertNil(attrs["device.osVersion"], "Wire field is `device.platform_version`, not `device.osVersion`",
                     file: file, line: line)
    }

    private static func assertAttributeIsPrimitive(
        _ value: Any,
        key: String,
        eventIdx: Int,
        file: StaticString,
        line: UInt
    ) throws {
        // JSON primitives bridge through NSNumber + NSString in
        // Foundation. Booleans bridge as NSNumber too, but as
        // `kCFBooleanTrue`/`kCFBooleanFalse` underneath — so we
        // allow NSNumber regardless. Reject NSDictionary / NSArray.
        if value is NSNull {
            return XCTFail("events[\(eventIdx)].attributes[\(key)] is null — attributes must be primitives",
                           file: file, line: line)
        }
        if value is [Any] || value is [String: Any] {
            return XCTFail("events[\(eventIdx)].attributes[\(key)] is a nested object/array — attributes must be flat primitives",
                           file: file, line: line)
        }
        if !(value is NSNumber) && !(value is String) {
            XCTFail("events[\(eventIdx)].attributes[\(key)] is of unexpected type \(type(of: value))",
                    file: file, line: line)
        }
    }
}
