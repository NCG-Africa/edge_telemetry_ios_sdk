// Tests/EdgeRumContractTests/PageLoadWireConformanceTests.swift
//
// F12 — End-to-end wire conformance for the page-load (`page_load`)
// capture emit shape.
//
// The unit-level `PageLoadCaptureTests` in `Tests/EdgeRumCaptureTests/`
// drives the capture against a probe Recorder to lock the attribute
// keys + types. This contract test pipes a synthesized `page_load`
// event with the exact F12 attribute schema through a real `Recorder`
// + `RecordingTransportSink` and validates the assembled envelope
// against `WireAssertions`.
//
// Without this test a future change in F12's attribute keys could
// pass the unit tests yet break the backend dispatcher. This file is
// the pinning gate.
//
// Refs: PLAN-iOS.md §6.4, §7, §F12; CLAUDE.md "Testing conventions".
//

import XCTest
import Foundation
import EdgeRumCore
@testable import EdgeRum

final class PageLoadWireConformanceTests: XCTestCase {

    private func makeRecorder() -> (Recorder, RecordingTransportSink) {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.512))
        let sink = RecordingTransportSink()
        let recorder = Recorder(
            clock: clock,
            sampler: Sampler(sampleRate: 1.0, entropy: { 0.0 }),
            transport: sink,
            sdkVersion: "1.0.0"
        )
        recorder.configure(RecorderConfig(
            apiKey: "edge_test_abc",
            endpoint: URL(string: "https://collect.example.com")!,
            location: "Nairobi/Kenya"
        ))
        return (recorder, sink)
    }

    // MARK: - page_load (cold start)

    /// A captured `page_load` event from a cold launch (T12.1 acceptance —
    /// one event per process with `duration_ms > 0`) survives the
    /// Recorder → PayloadBuilder → envelope path and the assembled JSON
    /// satisfies the wire contract.
    func testPageLoadColdStart_isWireValid() throws {
        let (recorder, sink) = makeRecorder()

        recorder.recordEvent(name: "page_load", attributes: [
            "page_load.duration_ms": .int(842),
            "page_load.cold_start": .bool(true),
            "page_load.prewarmed": .bool(false),
            "page_load.source": .string("displaylink")
        ])
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["type"] as? String, "event")
        XCTAssertEqual(events.first?["eventName"] as? String, "page_load")

        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        try WireAssertions.assertIdentityAttributes(attrs)

        XCTAssertEqual(attrs["page_load.duration_ms"] as? Int, 842)
        XCTAssertEqual(attrs["page_load.cold_start"] as? Bool, true)
        XCTAssertEqual(attrs["page_load.prewarmed"] as? Bool, false)
        XCTAssertEqual(attrs["page_load.source"] as? String, "displaylink")
    }

    // MARK: - page_load (prewarmed)

    /// Prewarmed-launch variant (T12.2 acceptance — `prewarmed = true`
    /// when `ActivePrewarm=1`). `cold_start` must flip to `false`; the
    /// envelope and attribute primitives still satisfy the wire
    /// contract.
    func testPageLoadPrewarmed_isWireValid() throws {
        let (recorder, sink) = makeRecorder()

        recorder.recordEvent(name: "page_load", attributes: [
            "page_load.duration_ms": .int(41),
            "page_load.cold_start": .bool(false),
            "page_load.prewarmed": .bool(true),
            "page_load.source": .string("displaylink")
        ])
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        try WireAssertions.assertIdentityAttributes(attrs)

        XCTAssertEqual(attrs["page_load.duration_ms"] as? Int, 41)
        XCTAssertEqual(attrs["page_load.cold_start"] as? Bool, false)
        XCTAssertEqual(attrs["page_load.prewarmed"] as? Bool, true)
        XCTAssertEqual(attrs["page_load.source"] as? String, "displaylink")
    }

    // MARK: - Attribute primitives

    /// Every attribute on the captured `page_load` event lands as a
    /// JSON primitive (the `WireAssertions.assertValidEnvelope` shared
    /// gate already enforces this across every event, but we make it
    /// explicit here too so a regression on the page_load bag fails
    /// loudly with a clearly-named test).
    func testPageLoadAttributesArePrimitives() throws {
        let (recorder, sink) = makeRecorder()

        recorder.recordEvent(name: "page_load", attributes: [
            "page_load.duration_ms": .int(1234),
            "page_load.cold_start": .bool(true),
            "page_load.prewarmed": .bool(false),
            "page_load.source": .string("displaylink")
        ])
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (data, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])

        // Spot-check each F12-owned key — must be String|Int|Bool.
        XCTAssertNotNil(attrs["page_load.duration_ms"] as? Int)
        XCTAssertNotNil(attrs["page_load.cold_start"] as? Bool)
        XCTAssertNotNil(attrs["page_load.prewarmed"] as? Bool)
        XCTAssertNotNil(attrs["page_load.source"] as? String)

        // No nested values in the F12 keys (defense-in-depth on top of
        // the shared primitive assertion).
        XCTAssertNil(attrs["page_load.duration_ms"] as? [Any])
        XCTAssertNil(attrs["page_load.cold_start"] as? [String: Any])

        // Raw bytes still free of the SDK-banned tokens; the shared
        // assertion checks the whole envelope but we anchor it again
        // here so a future schema drift that smuggles "span" or
        // "trace" into the page_load attribute set fails this file.
        let raw = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(raw.contains("\"traceId\""))
        XCTAssertFalse(raw.contains("\"spanId\""))
        XCTAssertFalse(raw.lowercased().contains("opentelemetry"))
    }

    // MARK: - Co-existence with other event types

    /// `page_load` co-exists with other F11/F10 events in the same batch
    /// — they don't collide on shared attribute namespaces and the
    /// outer envelope is wire-valid.
    func testPageLoad_inSameBatch_withOtherEvents() throws {
        let (recorder, sink) = makeRecorder()

        recorder.recordEvent(name: "page_load", attributes: [
            "page_load.duration_ms": .int(900),
            "page_load.cold_start": .bool(true),
            "page_load.prewarmed": .bool(false),
            "page_load.source": .string("displaylink")
        ])
        recorder.recordEvent(name: "app_lifecycle", attributes: [
            "lifecycle.state": .string("active"),
            "lifecycle.previous_state": .string("foregrounded")
        ])
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 2)
        let names = events.compactMap { $0["eventName"] as? String }
        XCTAssertEqual(Set(names), Set(["page_load", "app_lifecycle"]))
    }
}
