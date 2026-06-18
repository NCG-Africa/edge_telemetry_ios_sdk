// Tests/EdgeRumTests/SamplePayloadDocTests.swift
//
// Wire-contract regression for the README's "What gets sent" example
// and the source-of-truth `docs/payload-example.jsonc`.
//
// The README ships an excerpt of the example payload, and consumers
// who copy from it form a mental model of what the SDK actually emits.
// If `docs/payload-example.jsonc` drifts away from the wire-contract
// pinned facts in CLAUDE.md (e.g. someone accidentally writes
// `"type": "batch"` instead of `"type": "telemetry_batch"`, or sneaks
// a nested object into `attributes`), this test fails before the doc
// reaches consumers.
//
// Refs: PLAN-iOS.md §12.1 #9 ("what gets sent"),
//       CLAUDE.md "EdgeTelemetryProcessor contract".

import XCTest

final class SamplePayloadDocTests: XCTestCase {

    func testPayloadExampleEnvelopeMatchesContract() throws {
        let payload = try Self.loadPayloadExample()
        guard let envelope = payload as? [String: Any] else {
            return XCTFail("payload-example.jsonc must decode as a JSON object")
        }

        XCTAssertEqual(envelope["type"] as? String, "telemetry_batch",
                       "outer envelope must use the wire-contract `telemetry_batch` discriminator")

        let timestamp = envelope["timestamp"] as? String
        XCTAssertNotNil(timestamp, "envelope.timestamp must be present")
        XCTAssertTrue(timestamp?.contains("T") == true,
                      "envelope.timestamp must be ISO 8601 (contain a T separator)")

        guard let events = envelope["events"] as? [[String: Any]] else {
            return XCTFail("envelope.events must be an array of event objects")
        }
        XCTAssertGreaterThan(events.count, 0, "envelope.events must not be empty")

        if let batchSize = envelope["batch_size"] as? Int {
            XCTAssertEqual(batchSize, events.count,
                           "batch_size must equal events.count")
        } else {
            XCTFail("envelope.batch_size must be present as an integer")
        }

        for (idx, event) in events.enumerated() {
            let kind = event["type"] as? String
            XCTAssertTrue(kind == "event" || kind == "metric",
                          "event[\(idx)].type must be `event` or `metric`, got \(String(describing: kind))")

            XCTAssertNotNil(event["timestamp"] as? String,
                            "event[\(idx)].timestamp must be a string")

            guard let attributes = event["attributes"] as? [String: Any] else {
                XCTFail("event[\(idx)].attributes must be a JSON object")
                continue
            }

            XCTAssertEqual(attributes["sdk.platform"] as? String, "ios-native",
                           "event[\(idx)].attributes['sdk.platform'] must be \"ios-native\"")
            XCTAssertEqual(attributes["device.platform"] as? String, "ios",
                           "event[\(idx)].attributes['device.platform'] must be \"ios\"")
            if let sessionId = attributes["session.id"] as? String {
                XCTAssertTrue(sessionId.hasPrefix("session_"),
                              "session.id must start with \"session_\", got \(sessionId)")
            } else {
                XCTFail("event[\(idx)] missing session.id attribute")
            }
            if let deviceId = attributes["device.id"] as? String {
                XCTAssertTrue(deviceId.hasPrefix("device_"),
                              "device.id must start with \"device_\", got \(deviceId)")
            } else {
                XCTFail("event[\(idx)] missing device.id attribute")
            }

            // Primitives-only — no nested objects or arrays allowed
            // inside the per-event attributes map. CLAUDE.md "Recorder
            // + transport implementation notes" pins this on the wire.
            for (key, value) in attributes {
                XCTAssertTrue(Self.isJSONPrimitive(value),
                              "event[\(idx)].attributes[\"\(key)\"] must be a JSON primitive (String / Int / Double / Bool)")
            }
        }
    }

    func testPayloadExampleContainsNoForbiddenWireTokens() throws {
        let raw = try Self.loadRawJSONCText()
        let forbidden = ["traceId", "spanId", "resourceSpans", "opentelemetry"]
        for token in forbidden {
            XCTAssertFalse(raw.contains(token),
                           "payload-example.jsonc must not contain the forbidden wire token \"\(token)\"")
        }
    }

    // MARK: - Helpers

    /// JSONC → JSON: drop `//` line comments and parse with `JSONSerialization`.
    /// The repository's payload-example.jsonc deliberately carries
    /// section-header comments to make it readable; this strips them
    /// before handing the text to the parser.
    private static func loadPayloadExample() throws -> Any {
        let raw = try loadRawJSONCText()
        let stripped = raw
            .components(separatedBy: "\n")
            .map(Self.stripLineComment)
            .joined(separator: "\n")

        guard let data = stripped.data(using: .utf8) else {
            throw NSError(
                domain: "SamplePayloadDocTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not encode payload-example text as UTF-8"]
            )
        }
        return try JSONSerialization.jsonObject(with: data, options: [])
    }

    /// Trim trailing `// …` line comments while leaving `//` that sits
    /// inside a JSON string literal alone — e.g. `"http.url": "https://…"`.
    /// The previous version was a naïve `range(of: "//")` that truncated
    /// any URL value at the protocol separator and broke parse.
    private static func stripLineComment(_ line: String) -> String {
        var inString = false
        var escape = false
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if escape {
                escape = false
            } else if c == "\\" {
                escape = true
            } else if c == "\"" {
                inString.toggle()
            } else if !inString,
                      c == "/",
                      line.index(after: i) < line.endIndex,
                      line[line.index(after: i)] == "/" {
                return String(line[..<i])
            }
            i = line.index(after: i)
        }
        return line
    }

    private static func loadRawJSONCText() throws -> String {
        let root = try locateRepoRoot()
        let url = root.appendingPathComponent("docs/payload-example.jsonc")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func isJSONPrimitive(_ value: Any) -> Bool {
        if value is String { return true }
        if value is Bool { return true }
        if let n = value as? NSNumber {
            // NSNumber also matches Bool in some Foundation paths;
            // accept it regardless — Int / Double / Bool are all
            // legitimate primitives here.
            _ = n
            return true
        }
        return false
    }

    private static func locateRepoRoot(file: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<10 {
            let payload = dir.appendingPathComponent("docs/payload-example.jsonc")
            let pkg = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: payload.path)
                && FileManager.default.fileExists(atPath: pkg.path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(
            domain: "SamplePayloadDocTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate repo root from \(file)"]
        )
    }
}
