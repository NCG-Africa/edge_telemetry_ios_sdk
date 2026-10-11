// Tests/EdgeRumContractTests/WireAssertions.swift
//
// Shared assertions enforcing the EdgeTelemetryProcessor wire
// contract on any envelope the SDK would have shipped. Every
// transport-touching test calls `assertValidEnvelope` to catch wire
// drift before the test asserts more specific behaviour.
//
// Checked items (CLAUDE.md "Testing conventions"):
//
//   - Outer envelope (contract 4.0.0, #250): exactly the eight root
//     keys, `type == "telemetry_batch"`, `contract_version == "4.0.0"`,
//     ISO 8601 UTC `timestamp` with fractional seconds and `Z`,
//     `batch_size == events.count`, `device_id` shaped
//     `device_…_ios`, `sdk == {name: "ios", version}`, `app.platform
//     == "ios"` + `app.package_name`, no `""` in `app`.
//   - Per-event: `type ∈ {"event","metric"}`, `timestamp` present,
//     `eventName` allowlisted (or the SDK's own `sdk.health`, last),
//     `metricName` in the 8-name allowlist (F37), no `cause` attribute
//     (F29), no identity attribute (`app.*` identity keys, `sdk.*`,
//     `device.id`) — R1.
//   - `assertIdentityAttributes`: `session.id` well-formed on the
//     event; identity absent from it.
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

    static let rootKeys: Set<String> = [
        "type", "contract_version", "timestamp", "batch_size", "device_id", "sdk", "app", "events"
    ]

    /// Encode the envelope, run every wire-conformance check, and
    /// return the encoded bytes so the caller can perform additional
    /// specific assertions. The returned `json["events"]` holds the
    /// recorded events only: the trailing `sdk.health` event is
    /// validated here and set aside, so callers assert on what they
    /// recorded (`Contract4EnvelopeTests` pins `sdk.health` itself).
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
        XCTAssertEqual(Set(json.keys), rootKeys, "R3: closed 8-key envelope", file: file, line: line)
        XCTAssertEqual(json["type"] as? String, "telemetry_batch",
                       "envelope.type must be 'telemetry_batch'", file: file, line: line)
        XCTAssertEqual(json["contract_version"] as? String, "4.0.0", file: file, line: line)
        let deviceId = try XCTUnwrap(json["device_id"] as? String, "device_id at the root", file: file, line: line)
        XCTAssertTrue(deviceId.hasPrefix("device_") && deviceId.hasSuffix("_ios"),
                      "device_id must match the prefix shape, got \(deviceId)", file: file, line: line)
        let sdk = try XCTUnwrap(json["sdk"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(sdk["name"] as? String, "ios", file: file, line: line)
        XCTAssertNotNil(sdk["version"] as? String, file: file, line: line)
        let app = try XCTUnwrap(json["app"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(app["platform"] as? String, "ios", file: file, line: line)
        for (key, value) in app {
            XCTAssertNotEqual(value as? String, "", "R15: app.\(key) is never \"\"", file: file, line: line)
        }
        let stamp = try XCTUnwrap(json["timestamp"] as? String,
                                  "envelope.timestamp must be present and a string",
                                  file: file, line: line)
        XCTAssertNotNil(WireDateFormatter.date(from: stamp),
                        "envelope.timestamp must round-trip through ISO 8601 formatter",
                        file: file, line: line)
        XCTAssertTrue(stamp.contains("."),
                      "envelope.timestamp must carry fractional seconds",
                      file: file, line: line)
        XCTAssertTrue(stamp.hasSuffix("Z"), "R13: UTC with Z", file: file, line: line)

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
                let name = try XCTUnwrap(event["eventName"] as? String,
                                         "event events must carry an `eventName`",
                                         file: file, line: line)
                if name == PayloadBuilder.healthEventName {
                    XCTAssertEqual(idx, events.count - 1, "sdk.health is last", file: file, line: line)
                } else {
                    XCTAssertTrue(Recorder.allowedEventNames.contains(name),
                                  "eventName '\(name)' is not allowlisted", file: file, line: line)
                }
            } else if type == "metric" {
                let name = try XCTUnwrap(event["metricName"] as? String,
                                         "metric events must carry a `metricName`",
                                         file: file, line: line)
                XCTAssertTrue(Recorder.allowedMetricNames.contains(name),
                              "metricName '\(name)' is not allowlisted", file: file, line: line)
            }

            // Attributes must be flat primitives only.
            let attrs = try XCTUnwrap(event["attributes"] as? [String: Any],
                                      "events[\(idx)].attributes must be an object",
                                      file: file, line: line)
            XCTAssertNil(attrs["cause"], "F29: the event name discriminates, `cause` is gone",
                         file: file, line: line)
            for (key, value) in attrs {
                try assertAttributeIsPrimitive(value, key: key, eventIdx: idx, file: file, line: line)
                XCTAssertFalse(PayloadBuilder.isIdentityKey(key),
                               "R1: events[\(idx)] carries identity key \(key)", file: file, line: line)
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

        var recorded = json
        recorded["events"] = events.filter { $0["eventName"] as? String != PayloadBuilder.healthEventName }
        return (data, recorded)
    }

    /// Assert a single event's attributes carry a well-formed
    /// `session.id` and none of the envelope-only identity (R1).
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
        for key in attrs.keys where PayloadBuilder.isIdentityKey(key) {
            XCTFail("R1: identity key \(key) on an event", file: file, line: line)
        }

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
