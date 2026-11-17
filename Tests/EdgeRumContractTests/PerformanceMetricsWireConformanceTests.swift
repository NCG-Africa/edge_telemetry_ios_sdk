// Tests/EdgeRumContractTests/PerformanceMetricsWireConformanceTests.swift
//
// F10 — End-to-end wire conformance for `perf.long_task`. `frame.summary`
// and `memory.usage` are events now (#264); CatalogueGoldenTests pipes the
// real emitters through the wire.
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
        recorder.setEnabled(true)  // #212: enqueue is consent-gated; start() is the usual enable boundary
        recorder.configure(RecorderConfig(
            apiKey: "edge_test_abc",
            endpoint: URL(string: "https://collect.example.com")!
        ))
        return (recorder, sink)
    }

    // MARK: long_task

    func testLongTaskMetricPassesWireAssertions() throws {
        let (recorder, sink) = makeRecorder()

        recorder.recordPerformance(name: "perf.long_task", attributes: [
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
        XCTAssertEqual(events.first?["metricName"] as? String, "perf.long_task")
        XCTAssertEqual(events.first?["value"] as? Double, 214.7)

        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        try WireAssertions.assertIdentityAttributes(attrs)
        XCTAssertEqual(attrs["long_task.threshold_ms"] as? Double, 50.0)
        XCTAssertEqual(
            attrs["long_task.stack"] as? String,
            "0  frame_a\n1  frame_b"
        )
    }
}
