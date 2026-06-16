import XCTest
import EdgeRumCore

/// End-to-end contract tests for the F3 `Recorder` pipeline.
///
/// Drives a fresh `Recorder` with a `RecordingTransportSink` injected,
/// invokes recording APIs, and asserts the captured envelopes pass
/// every wire-conformance check.
final class RecorderPipelineContractTests: XCTestCase {

    private func makeRecorder() -> (Recorder, RecordingTransportSink, FixedClock) {
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
        return (recorder, sink, clock)
    }

    func testNavigationEventEnvelopePassesWireAssertions() throws {
        let (recorder, sink, _) = makeRecorder()
        recorder.recordEvent(name: "navigation", attributes: [
            "navigation.kind": "uikit",
            "navigation.name": "Cart"
        ])
        recorder.flush(reason: .manual)
        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        XCTAssertEqual(json["location"] as? String, "Nairobi/Kenya")
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        try WireAssertions.assertIdentityAttributes(attrs)
        XCTAssertEqual(attrs["navigation.kind"] as? String, "uikit")
    }

    func testMetricEnvelopePassesWireAssertions() throws {
        let (recorder, sink, _) = makeRecorder()
        recorder.recordPerformance(name: "frame_render_time", attributes: [
            "frame.target_hz": 60,
            "value": 18.4
        ])
        recorder.flush(reason: .manual)
        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.first?["type"] as? String, "metric")
        XCTAssertEqual(events.first?["metricName"] as? String, "frame_render_time")
        XCTAssertEqual(events.first?["value"] as? Double, 18.4)
    }

    /// F6 — `screen.duration` must encode as a `metric` with both the
    /// scalar `value` (seconds, Double) and the duration_ms attribute.
    /// Matches the shape produced by `UIViewControllerCapture.handleViewWillDisappear`.
    func testScreenDurationMetricEnvelopePassesWireAssertions() throws {
        let (recorder, sink, _) = makeRecorder()
        recorder.recordPerformance(name: "screen.duration", attributes: [
            "screen.name": "Cart",
            "screen.kind": "uikit",
            "screen.duration_ms": 4300,
            "value": 4.3
        ])
        recorder.flush(reason: .manual)
        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.first?["type"] as? String, "metric")
        XCTAssertEqual(events.first?["metricName"] as? String, "screen.duration")
        XCTAssertEqual(events.first?["value"] as? Double, 4.3)
        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        XCTAssertEqual(attrs["screen.name"] as? String, "Cart")
        XCTAssertEqual(attrs["screen.kind"] as? String, "uikit")
        XCTAssertEqual(attrs["screen.duration_ms"] as? Int, 4300)
    }

    func testErrorEnvelopeIsAppCrashWithFlattenedFields() throws {
        let (recorder, sink, _) = makeRecorder()
        recorder.recordError(
            domain: "PaymentDomain",
            code: 42,
            message: "Card declined",
            context: ["payment.method": "card"]
        )
        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.first?["eventName"] as? String, "app.crash")
        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        XCTAssertEqual(attrs["cause"] as? String, "AppError")
        XCTAssertEqual(attrs["error.domain"] as? String, "PaymentDomain")
        XCTAssertEqual(attrs["error.code"] as? Int, 42)
        XCTAssertEqual(attrs["error.message"] as? String, "Card declined")
        XCTAssertEqual(attrs["payment.method"] as? String, "card")
    }

    func testEnvelopeBytesContainNoForbiddenTokens() throws {
        let (recorder, sink, _) = makeRecorder()
        for _ in 0..<5 {
            recorder.recordEvent(name: "navigation", attributes: ["navigation.kind": "uikit"])
        }
        recorder.flush(reason: .manual)
        let envelope = try XCTUnwrap(sink.envelopes.first)
        let data = try JSONEncoder().encode(envelope)
        let raw = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(raw.contains("traceId"))
        XCTAssertFalse(raw.contains("spanId"))
        XCTAssertFalse(raw.contains("resourceSpans"))
        XCTAssertFalse(raw.lowercased().contains("opentelemetry"))
    }

    func testAttributesAreAllPrimitives() throws {
        let (recorder, sink, _) = makeRecorder()
        recorder.recordEvent(name: "http.request", attributes: [
            "http.url": "https://api.example.com/products",
            "http.method": "GET",
            "http.status_code": 200,
            "http.duration_ms": 342,
            "http.from_cache": false
        ])
        recorder.flush(reason: .manual)
        let envelope = try XCTUnwrap(sink.envelopes.first)
        try WireAssertions.assertValidEnvelope(envelope)
    }
}
