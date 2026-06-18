// Tests/EdgeRumContractTests/GoldenBatchSnapshotTests.swift
//
// F19 / T19.4 — Snapshot test against `Tests/Fixtures/golden-batch-ios.json`.
// The fixture is built from frozen inputs (FixedClock, frozen identity
// attributes, frozen device context) so the encoded bytes are
// deterministic across runs and across the Android/web SDKs' equivalent
// fixtures.
//
// The fixture's purpose is twofold:
//   1. Catches accidental wire drift — any encoder-shape change, key
//      rename, or attribute reordering on the encoded surface flips
//      the snapshot.
//   2. Acts as a reviewable reference batch — humans can diff the
//      JSON against `docs/payload-example.jsonc` and the Android/web
//      SDKs' equivalents during cross-platform alignment.
//
// Self-bootstrapping behaviour: if the fixture does not yet exist, the
// test writes it once and fails with a clear "rebaseline" message. On
// a mismatch, the test writes the produced bytes next to the fixture
// as `golden-batch-ios.actual.json` so the diff is one tool away.
//
// Refs: PLAN-iOS.md §13.4 (Golden batch test), §F19/T19.4,
//       CLAUDE.md "Testing conventions" (Golden batch test).
//

import XCTest
import EdgeRumCore

final class GoldenBatchSnapshotTests: XCTestCase {

    // MARK: - Frozen inputs

    /// Frozen flush instant. Matches `docs/payload-example.jsonc` so
    /// the fixture reads like the documented example.
    private let flushTime = WireDateFormatter.date(from: "2026-06-14T10:30:00.512Z")!
    private let navTime   = WireDateFormatter.date(from: "2026-06-14T10:30:00.123Z")!
    private let exitTime  = WireDateFormatter.date(from: "2026-06-14T10:30:04.456Z")!
    private let httpTime  = WireDateFormatter.date(from: "2026-06-14T10:30:00.456Z")!
    private let frameTime = WireDateFormatter.date(from: "2026-06-14T10:30:05.000Z")!

    /// Frozen identity attributes — `device.id`, `session.id`, and
    /// `user.id` literals match the §"ID formats" worked example in
    /// CLAUDE.md so the fixture is grep-able against the spec.
    private func frozenContext() -> AttributeBag {
        AttributeBag([
            "app.name":                 "Shop",
            "app.version":              "2.1.0",
            "app.package_name":         "com.example.shop",
            "app.build_number":         "412",
            "app.environment":          "production",
            "device.id":                "device_1717234876123_a1b2c3d4e5f60718_ios",
            "device.platform":          "ios",
            "device.model":             "iPhone15,3",
            "device.manufacturer":      "Apple",
            "device.os":                "ios",
            "device.platform_version":  "17.4.1",
            "device.isVirtual":         false,
            "device.screenWidth":       1290,
            "device.screenHeight":      2796,
            "device.pixelRatio":        3.0,
            "device.batteryLevel":      0.82,
            "device.batteryCharging":   false,
            "network.type":             "wifi",
            "network.effectiveType":    "4g",
            "session.id":               "session_1717234870002_ff009988aabbccdd_ios",
            "session.start_time":       "2026-06-14T10:25:00.002Z",
            "session.sequence":         1,
            "user.id":                  "user_1717100000000_deadbeefcafef00d",
            "sdk.version":              "1.0.0",
            "sdk.platform":             "ios-native"
        ])
    }

    /// The four frozen events — one per shape mentioned in §13.4 /
    /// `docs/payload-example.jsonc`.
    private func frozenEvents() -> [Event] {
        [
            .event(
                name: "navigation",
                timestamp: navTime,
                attributes: AttributeBag([
                    "navigation.screen":          "CartViewController",
                    "navigation.previous_screen": "ProductListViewController",
                    "navigation.type":            "viewDidAppear",
                    "navigation.kind":            "uikit"
                ])
            ),
            .event(
                name: "screen.duration",
                timestamp: exitTime,
                attributes: AttributeBag([
                    "screen.name":         "CartViewController",
                    "screen.duration_ms":  4333,
                    "screen.exit_method":  "viewWillDisappear"
                ])
            ),
            .event(
                name: "http.request",
                timestamp: httpTime,
                attributes: AttributeBag([
                    "http.url":           "https://api.example.com/products",
                    "http.method":        "GET",
                    "http.host":          "api.example.com",
                    "http.path":          "/products",
                    "http.status_code":   200,
                    "http.duration_ms":   342,
                    "http.request_size":  0,
                    "http.response_size": 18244,
                    "http.from_cache":    false
                ])
            ),
            .metric(
                name: "frame_render_time",
                value: 18.4,
                timestamp: frameTime,
                attributes: AttributeBag([
                    "frame.max_ms":         33,
                    "frame.p95_ms":         28,
                    "frame.dropped_count":  1,
                    "frame.target_hz":      60,
                    "frame.source":         "displaylink"
                ])
            )
        ]
    }

    // MARK: - Encoding

    /// Encoder pinned to deterministic, reviewer-friendly output. The
    /// production encoder uses no options; the snapshot encoder uses
    /// `.sortedKeys + .prettyPrinted + .withoutEscapingSlashes` so the
    /// on-disk fixture is stable and human-readable. The wire shape is
    /// identical either way — only whitespace and key order differ.
    private static func snapshotEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return enc
    }

    private func buildAndEncodeGoldenBatch() throws -> Data {
        let builder = PayloadBuilder()
        let envelope = builder.build(
            events: frozenEvents(),
            context: frozenContext(),
            location: "Nairobi/Kenya",
            flushTime: flushTime
        )

        // Run the production wire-conformance harness first — if the
        // envelope is malformed, fail with a clear message before
        // running a byte diff that would only obscure the root cause.
        _ = try WireAssertions.assertValidEnvelope(envelope)

        return try Self.snapshotEncoder().encode(envelope)
    }

    // MARK: - Test

    func testGoldenBatchMatchesFixture() throws {
        let produced = try buildAndEncodeGoldenBatch()
        // Always end on a trailing newline so editors do not mark the
        // checked-in fixture dirty on save.
        let producedString = (String(data: produced, encoding: .utf8) ?? "") + "\n"
        let producedBytes  = Data(producedString.utf8)

        let fixtureURL = Self.fixtureURL()

        if !FileManager.default.fileExists(atPath: fixtureURL.path) {
            // First run after introducing the test — write the fixture
            // and fail so the author commits it intentionally.
            try producedBytes.write(to: fixtureURL)
            XCTFail("""
                golden-batch-ios.json did not exist; wrote initial \
                fixture to \(fixtureURL.path). Review and commit it, \
                then re-run.
                """)
            return
        }

        let expected = try Data(contentsOf: fixtureURL)
        if producedBytes != expected {
            // Mismatch — drop the produced bytes alongside the fixture
            // so the author can `diff` them in one step.
            let actualURL = fixtureURL.deletingLastPathComponent()
                .appendingPathComponent("golden-batch-ios.actual.json")
            try? producedBytes.write(to: actualURL)
            XCTFail("""
                Golden batch byte mismatch.
                  expected: \(fixtureURL.path)
                  actual:   \(actualURL.path)
                If the change is intentional, run:
                    diff -u \(fixtureURL.path) \(actualURL.path)
                  cp \(actualURL.path) \(fixtureURL.path)
                """)
        }
    }

    /// All identity attributes the snapshot pins must round-trip
    /// through the contract harness. Catches wire drift independent of
    /// byte ordering — if a key gets renamed without updating the
    /// fixture, this fires before the byte diff.
    func testGoldenBatchPassesIdentityAssertions() throws {
        let builder = PayloadBuilder()
        let envelope = builder.build(
            events: frozenEvents(),
            context: frozenContext(),
            location: "Nairobi/Kenya",
            flushTime: flushTime
        )
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 4, "Fixture must carry exactly 4 events")
        for event in events {
            let attrs = try XCTUnwrap(event["attributes"] as? [String: Any])
            try WireAssertions.assertIdentityAttributes(attrs)
        }
    }

    // MARK: - Fixture path

    /// Derive the repo-relative fixture path from `#filePath`.
    /// `#filePath` resolves to this file's absolute on-disk location
    /// at compile time, so the test does not need the fixture bundled
    /// as a SwiftPM resource (which would require a separate target
    /// because the file lives outside the test target's source path).
    private static func fixtureURL(file: StaticString = #filePath) -> URL {
        // file = .../Tests/EdgeRumContractTests/GoldenBatchSnapshotTests.swift
        // ../..   → Tests/
        let here = URL(fileURLWithPath: "\(file)")
        let testsDir = here
            .deletingLastPathComponent()  // Tests/EdgeRumContractTests
            .deletingLastPathComponent()  // Tests
        return testsDir
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("golden-batch-ios.json")
    }
}
