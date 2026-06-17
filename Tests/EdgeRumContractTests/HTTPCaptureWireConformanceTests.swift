// Tests/EdgeRumContractTests/HTTPCaptureWireConformanceTests.swift
//
// F8 — End-to-end wire conformance for the HTTP capture emit shapes.
//
// The unit-level `HTTPCaptureTests` in `Tests/EdgeRumCaptureTests/`
// drives `HTTPCapture.recordOutcome` against a probe Recorder to lock
// the attribute keys and types. This contract test pipes a synthesized
// `http.request` event and a `resource_timing` metric — with the
// exact attribute schema F8 emits — through a real `Recorder` +
// `RecordingTransportSink` and validates the assembled envelope
// against `WireAssertions`.
//
// Without this test, a future change in HTTPCapture's attribute keys
// could pass the unit tests yet break the backend dispatcher.
//
// Refs: PLAN-iOS.md §6.3, §7, §F8; CLAUDE.md "Testing conventions".
//

import XCTest
import Foundation
import EdgeRumCore
@testable import EdgeRum

final class HTTPCaptureWireConformanceTests: XCTestCase {

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

    /// A captured `http.request` event passes through the Recorder →
    /// PayloadBuilder → envelope and the resulting JSON satisfies the
    /// wire contract (outer envelope shape, identity attrs, primitives-
    /// only attribute values, no firewall-banned tokens).
    ///
    /// As of F17 the event carries TLS / connection enrichment in
    /// addition to the F8 base attributes — this test exercises a
    /// fully-enriched event so the contract assertion covers the v1.0
    /// shape end-to-end.
    func testHTTPRequestProducesWireValidEvent() throws {
        let (recorder, sink) = makeRecorder()

        recorder.recordEvent(name: "http.request", attributes: [
            "http.method": .string("GET"),
            "http.url": .string("https://api.example.com/v1/users?page=2"),
            "http.host": .string("api.example.com"),
            "http.path": .string("/v1/users"),
            "http.status_code": .int(200),
            "http.duration_ms": .int(143),
            "http.request_size": .int(0),
            "http.response_size": .int(1234),
            "http.from_cache": .bool(false),
            // F17 enrichment (T17.1)
            "http.redirect_count": .int(0),
            "http.tls_protocol": .string("1.3"),
            "http.tls_cipher": .string("TLS_AES_128_GCM_SHA256"),
            "http.reused_connection": .bool(true),
            "http.proxy_connection": .bool(false),
            "http.network_protocol": .string("h2"),
            "http.request_body_bytes_before_encoding": .int(0),
            // F17 enrichment (T17.2)
            "http.cellular_fallback": .bool(false)
        ])
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["type"] as? String, "event")
        XCTAssertEqual(events.first?["eventName"] as? String, "http.request")

        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        try WireAssertions.assertIdentityAttributes(attrs)

        XCTAssertEqual(attrs["http.method"] as? String, "GET")
        XCTAssertEqual(attrs["http.url"] as? String, "https://api.example.com/v1/users?page=2")
        XCTAssertEqual(attrs["http.host"] as? String, "api.example.com")
        XCTAssertEqual(attrs["http.path"] as? String, "/v1/users")
        XCTAssertEqual(attrs["http.status_code"] as? Int, 200)
        XCTAssertEqual(attrs["http.duration_ms"] as? Int, 143)
        XCTAssertEqual(attrs["http.from_cache"] as? Bool, false)

        // F17: types survive the JSON roundtrip.
        XCTAssertEqual(attrs["http.redirect_count"] as? Int, 0)
        XCTAssertEqual(attrs["http.tls_protocol"] as? String, "1.3")
        XCTAssertEqual(attrs["http.tls_cipher"] as? String, "TLS_AES_128_GCM_SHA256")
        XCTAssertEqual(attrs["http.reused_connection"] as? Bool, true)
        XCTAssertEqual(attrs["http.proxy_connection"] as? Bool, false)
        XCTAssertEqual(attrs["http.network_protocol"] as? String, "h2")
        XCTAssertEqual(attrs["http.request_body_bytes_before_encoding"] as? Int, 0)
        XCTAssertEqual(attrs["http.cellular_fallback"] as? Bool, false)
    }

    /// `http.error` only appears on failure — the success-path event
    /// must NOT carry it. Pins the §6.3 wording "if any".
    func testHTTPRequestSuccessOmitsErrorAttribute() throws {
        let (recorder, sink) = makeRecorder()

        recorder.recordEvent(name: "http.request", attributes: [
            "http.method": .string("GET"),
            "http.url": .string("https://api.example.com/u"),
            "http.host": .string("api.example.com"),
            "http.path": .string("/u"),
            "http.status_code": .int(200),
            "http.duration_ms": .int(50),
            "http.request_size": .int(0),
            "http.response_size": .int(10),
            "http.from_cache": .bool(false)
        ])
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        XCTAssertNil(attrs["http.error"])
    }

    /// A captured `resource_timing` metric produces a wire-valid
    /// metric envelope with timing attributes typed as Int — the only
    /// shape the backend dispatcher reads.
    ///
    /// F17 schema alignment: `resource.response_ms` was renamed to
    /// `resource.download_ms` to match `docs/data-flow.md` § 10.2 and
    /// the Android SDK wire shape. `resource.protocol` is added,
    /// derived from `URLSessionTaskTransactionMetrics.networkProtocolName`.
    /// Multi-transaction enrichment (T17.3) adds `redirect_count`,
    /// `transaction_count`, and `fetch_start_to_response_end_ms`.
    func testResourceTimingProducesWireValidMetric() throws {
        let (recorder, sink) = makeRecorder()

        recorder.recordPerformance(name: "resource_timing", attributes: [
            "resource.url": .string("https://api.example.com/v1/users"),
            "resource.host": .string("api.example.com"),
            "resource.dns_ms": .int(12),
            "resource.connect_ms": .int(31),
            "resource.tls_ms": .int(45),
            "resource.ttfb_ms": .int(54),
            "resource.download_ms": .int(1),
            "resource.protocol": .string("h2"),
            "resource.redirect_count": .int(0),
            "resource.transaction_count": .int(1),
            "resource.fetch_start_to_response_end_ms": .int(143),
            "value": .double(143.0)
        ])
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["type"] as? String, "metric")
        XCTAssertEqual(events.first?["metricName"] as? String, "resource_timing")

        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        try WireAssertions.assertIdentityAttributes(attrs)
        XCTAssertEqual(attrs["resource.dns_ms"] as? Int, 12)
        XCTAssertEqual(attrs["resource.connect_ms"] as? Int, 31)
        XCTAssertEqual(attrs["resource.tls_ms"] as? Int, 45)
        XCTAssertEqual(attrs["resource.ttfb_ms"] as? Int, 54)
        XCTAssertEqual(attrs["resource.download_ms"] as? Int, 1)
        XCTAssertEqual(attrs["resource.url"] as? String, "https://api.example.com/v1/users")
        XCTAssertEqual(attrs["resource.protocol"] as? String, "h2")
        XCTAssertEqual(attrs["resource.redirect_count"] as? Int, 0)
        XCTAssertEqual(attrs["resource.transaction_count"] as? Int, 1)
        XCTAssertEqual(attrs["resource.fetch_start_to_response_end_ms"] as? Int, 143)

        XCTAssertNil(attrs["resource.response_ms"], "F17 renamed response_ms → download_ms")
    }

    /// Both signals in a single batch — the common-case shape downstream
    /// dashboards expect (one http.request event paired with one
    /// resource_timing metric).
    func testHTTPRequestAndResourceTimingInSameBatch() throws {
        let (recorder, sink) = makeRecorder()

        recorder.recordEvent(name: "http.request", attributes: [
            "http.method": .string("POST"),
            "http.url": .string("https://api.example.com/orders"),
            "http.host": .string("api.example.com"),
            "http.path": .string("/orders"),
            "http.status_code": .int(201),
            "http.duration_ms": .int(208),
            "http.request_size": .int(512),
            "http.response_size": .int(64),
            "http.from_cache": .bool(false)
        ])
        recorder.recordPerformance(name: "resource_timing", attributes: [
            "resource.url": .string("https://api.example.com/orders"),
            "resource.host": .string("api.example.com"),
            "resource.dns_ms": .int(5),
            "resource.connect_ms": .int(12),
            "resource.tls_ms": .int(28),
            "resource.ttfb_ms": .int(150),
            "resource.download_ms": .int(13),
            "resource.protocol": .string("h2"),
            "resource.redirect_count": .int(0),
            "resource.transaction_count": .int(1)
        ])
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0]["eventName"] as? String, "http.request")
        XCTAssertEqual(events[1]["metricName"] as? String, "resource_timing")
    }

    /// T17.3 — a request that followed one redirect emits
    /// `resource.transaction_count = 2` and a non-zero
    /// `resource.redirect_count`. Pins the multi-transaction shape
    /// the dashboards key on.
    func testHTTPRequestRedirectChainEmitsTransactionCount() throws {
        let (recorder, sink) = makeRecorder()

        recorder.recordEvent(name: "http.request", attributes: [
            "http.method": .string("GET"),
            "http.url": .string("https://api.example.com/v1/users"),
            "http.host": .string("api.example.com"),
            "http.path": .string("/v1/users"),
            "http.status_code": .int(200),
            "http.duration_ms": .int(412),
            "http.request_size": .int(0),
            "http.response_size": .int(2048),
            "http.from_cache": .bool(false),
            "http.redirect_count": .int(1),
            "http.tls_protocol": .string("1.3"),
            "http.network_protocol": .string("h2"),
            "http.reused_connection": .bool(false),
            "http.proxy_connection": .bool(false),
            "http.request_body_bytes_before_encoding": .int(0)
        ])
        recorder.recordPerformance(name: "resource_timing", attributes: [
            "resource.url": .string("https://api.example.com/v1/users"),
            "resource.host": .string("api.example.com"),
            "resource.dns_ms": .int(8),
            "resource.connect_ms": .int(22),
            "resource.tls_ms": .int(38),
            "resource.ttfb_ms": .int(280),
            "resource.download_ms": .int(64),
            "resource.protocol": .string("h2"),
            "resource.redirect_count": .int(1),
            "resource.transaction_count": .int(2),
            "resource.fetch_start_to_response_end_ms": .int(412)
        ])
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 2)

        let evAttrs = try XCTUnwrap(events[0]["attributes"] as? [String: Any])
        XCTAssertEqual(evAttrs["http.redirect_count"] as? Int, 1)

        let metricAttrs = try XCTUnwrap(events[1]["attributes"] as? [String: Any])
        XCTAssertEqual(metricAttrs["resource.redirect_count"] as? Int, 1)
        XCTAssertEqual(metricAttrs["resource.transaction_count"] as? Int, 2)
        XCTAssertEqual(metricAttrs["resource.fetch_start_to_response_end_ms"] as? Int, 412)
    }
}
