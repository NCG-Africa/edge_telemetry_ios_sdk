// Tests/EdgeRumContractTests/PerformanceMetricsWireConformanceTests.swift
//
// F10 — End-to-end wire conformance for the three performance metrics:
// `frame_render_time`, `memory_usage`, `long_task`.
//
// The unit-level samplers in `Tests/EdgeRumCaptureTests/` lock the
// attribute keys and types against probes. This contract test pipes
// each canonical attribute bag through a real `Recorder` +
// `RecordingTransportSink` and validates the assembled envelope with
// `WireAssertions` — primitives only, identity attributes present,
// no banned tokens.
//
// Without this test a future change to one of the sampler bags could
// pass the unit tests yet break the backend dispatcher.
//
// Refs: PLAN-iOS.md §6.10, §6.11, §6.12, §7, §F10; CLAUDE.md
//       "Testing conventions".
//

import XCTest
import Foundation
import EdgeRumCore
@testable import EdgeRum

final class PerformanceMetricsWireConformanceTests: XCTestCase {

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

    // MARK: frame_render_time

    func testFrameRenderTimeMetricPassesWireAssertions() throws {
        let (recorder, sink) = makeRecorder()

        recorder.recordPerformance(name: "frame_render_time", attributes: [
            "frame.max_ms": .double(33.3),
            "frame.p95_ms": .double(28.1),
            "frame.dropped_count": .int(4),
            "frame.target_hz": .int(60),
            "frame.source": .string("displaylink"),
            "value": .double(33.3)
        ])
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["type"] as? String, "metric")
        XCTAssertEqual(events.first?["metricName"] as? String, "frame_render_time")
        XCTAssertEqual(events.first?["value"] as? Double, 33.3)

        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        try WireAssertions.assertIdentityAttributes(attrs)
        XCTAssertEqual(attrs["frame.max_ms"] as? Double, 33.3)
        XCTAssertEqual(attrs["frame.p95_ms"] as? Double, 28.1)
        XCTAssertEqual(attrs["frame.dropped_count"] as? Int, 4)
        XCTAssertEqual(attrs["frame.target_hz"] as? Int, 60)
        XCTAssertEqual(attrs["frame.source"] as? String, "displaylink")
    }

    // MARK: memory_usage

    func testMemoryUsageMetricPassesWireAssertions() throws {
        let (recorder, sink) = makeRecorder()

        recorder.recordPerformance(name: "memory_usage", attributes: [
            "memory.resident_kb": .int(204_800),
            "memory.virtual_kb": .int(1_048_576),
            "memory.footprint_kb": .int(208_000),
            "memory.pressure": .string("warning"),
            "value": .double(204_800)
        ])
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["type"] as? String, "metric")
        XCTAssertEqual(events.first?["metricName"] as? String, "memory_usage")

        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        try WireAssertions.assertIdentityAttributes(attrs)
        XCTAssertEqual(attrs["memory.resident_kb"] as? Int, 204_800)
        XCTAssertEqual(attrs["memory.virtual_kb"] as? Int, 1_048_576)
        XCTAssertEqual(attrs["memory.footprint_kb"] as? Int, 208_000)
        XCTAssertEqual(attrs["memory.pressure"] as? String, "warning")
    }

    // MARK: long_task

    func testLongTaskMetricPassesWireAssertions() throws {
        let (recorder, sink) = makeRecorder()

        recorder.recordPerformance(name: "long_task", attributes: [
            "value": .double(214.7),
            "long_task.threshold_ms": .double(50.0),
            "long_task.stack": .string("0  frame_a\n1  frame_b")
        ])
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["type"] as? String, "metric")
        XCTAssertEqual(events.first?["metricName"] as? String, "long_task")
        XCTAssertEqual(events.first?["value"] as? Double, 214.7)

        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        try WireAssertions.assertIdentityAttributes(attrs)
        XCTAssertEqual(attrs["long_task.threshold_ms"] as? Double, 50.0)
        XCTAssertEqual(
            attrs["long_task.stack"] as? String,
            "0  frame_a\n1  frame_b"
        )
    }

    // MARK: Multi-metric batch

    /// All three performance metrics in a single flush should reach
    /// the wire in order with each one wire-valid.
    func testAllThreeMetricsInOneBatchPreserveOrder() throws {
        let (recorder, sink) = makeRecorder()

        recorder.recordPerformance(name: "frame_render_time", attributes: [
            "frame.max_ms": .double(20.0),
            "frame.p95_ms": .double(18.0),
            "frame.dropped_count": .int(0),
            "frame.target_hz": .int(60),
            "frame.source": .string("displaylink"),
            "value": .double(20.0)
        ])
        recorder.recordPerformance(name: "memory_usage", attributes: [
            "memory.resident_kb": .int(100_000),
            "memory.virtual_kb": .int(800_000),
            "memory.footprint_kb": .int(120_000),
            "memory.pressure": .string("normal"),
            "value": .double(100_000)
        ])
        recorder.recordPerformance(name: "long_task", attributes: [
            "value": .double(72.5),
            "long_task.threshold_ms": .double(50.0),
            "long_task.stack": .string("frame")
        ])
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 3)
        let names = events.compactMap { $0["metricName"] as? String }
        XCTAssertEqual(names, ["frame_render_time", "memory_usage", "long_task"])
    }
}
