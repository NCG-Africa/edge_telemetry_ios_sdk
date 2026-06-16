// Tests/EdgeRumContractTests/SwiftUIWireConformanceTests.swift
//
// F7 — End-to-end wire conformance for the SwiftUI emit shapes.
//
// The unit-level `SwiftUIModifierTests` in `Tests/EdgeRumTests/`
// drives the emitter against a `ProbeRecorder` to lock argument
// shape. This contract test pipes those same emits through a real
// `Recorder` + `RecordingTransportSink` and validates the assembled
// envelope against `WireAssertions` — the same gate every other
// wire-touching path crosses.
//
// Without this test, a future change in `SwiftUIEmitter` could emit
// an attribute the backend silently drops; the probe-level tests
// would still pass.
//
// Refs: PLAN-iOS.md §6.2, §7, §F7; CLAUDE.md "Testing conventions".
//

#if canImport(SwiftUI)
import XCTest
import EdgeRumCore
@testable import EdgeRum

final class SwiftUIWireConformanceTests: XCTestCase {

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

    /// `.edgeRumScreen` on-appear → a wire-valid `navigation` event
    /// with `navigation.kind = "swiftui"`.
    func testSwiftUIScreenAppearProducesWireValidNavigation() throws {
        let (recorder, sink) = makeRecorder()
        let store = SwiftUIScreenStartStore()

        SwiftUIEmitter.emitScreenAppear(
            name: "Checkout",
            attributes: ["funnel.step": 3],
            recorder: recorder,
            clock: recorder.clock,
            startStore: store
        )
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["type"] as? String, "event")
        XCTAssertEqual(events.first?["eventName"] as? String, "navigation")
        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        try WireAssertions.assertIdentityAttributes(attrs)
        XCTAssertEqual(attrs["navigation.kind"] as? String, "swiftui")
        XCTAssertEqual(attrs["navigation.screen"] as? String, "Checkout")
        XCTAssertEqual(attrs["navigation.type"] as? String, "viewDidAppear")
        XCTAssertEqual(attrs["funnel.step"] as? Int, 3)
    }

    /// `.edgeRumScreen` on-disappear → a wire-valid `screen.duration`
    /// METRIC carrying both `screen.duration_ms` (Int) and the
    /// top-level scalar `value` (Double seconds). Mirrors the F6
    /// UIKit shape; pins the F7 parity fix.
    func testSwiftUIScreenDisappearProducesWireValidScreenDurationMetric() throws {
        let (recorder, sink) = makeRecorder()
        let store = SwiftUIScreenStartStore()

        // Manual appear/disappear stamps so the dwell is deterministic
        // against the FixedClock — the emitter pulls `clock.now` once
        // per call which would give us a zero dwell otherwise.
        let appearAt = Date(timeIntervalSince1970: 1_717_234_870.000)
        store.recordStart(name: "Checkout", at: appearAt)

        SwiftUIEmitter.emitScreenDisappear(
            name: "Checkout",
            attributes: nil,
            recorder: recorder,
            clock: recorder.clock,
            startStore: store
        )
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["type"] as? String, "metric")
        XCTAssertEqual(events.first?["metricName"] as? String, "screen.duration")
        let topValue = try XCTUnwrap(events.first?["value"] as? Double)
        XCTAssertEqual(topValue, 6.512, accuracy: 0.002)
        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        try WireAssertions.assertIdentityAttributes(attrs)
        XCTAssertEqual(attrs["screen.name"] as? String, "Checkout")
        XCTAssertEqual(attrs["screen.kind"] as? String, "swiftui")
        let durationMs = try XCTUnwrap(attrs["screen.duration_ms"] as? Int)
        XCTAssertEqual(durationMs, 6512)
    }

    /// `.edgeRumTrackTap` → a wire-valid `user.interaction` event
    /// with `interaction.kind = "tap"`.
    func testSwiftUITapProducesWireValidUserInteraction() throws {
        let (recorder, sink) = makeRecorder()

        SwiftUIEmitter.emitTap(
            name: "buy_button",
            attributes: ["product.id": "SKU-123"],
            recorder: recorder
        )
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["type"] as? String, "event")
        XCTAssertEqual(events.first?["eventName"] as? String, "user.interaction")
        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        try WireAssertions.assertIdentityAttributes(attrs)
        XCTAssertEqual(attrs["interaction.kind"] as? String, "tap")
        XCTAssertEqual(attrs["interaction.name"] as? String, "buy_button")
        XCTAssertEqual(attrs["product.id"] as? String, "SKU-123")
    }
}
#endif
