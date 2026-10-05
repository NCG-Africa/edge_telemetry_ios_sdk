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
        recorder.setEnabled(true)  // #212: enqueue is consent-gated; start() is the usual enable boundary
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

        SwiftUIEmitter.emitScreenAppear(
            name: "Checkout",
            attributes: ["funnel.step": 3],
            recorder: recorder,
            riders: Riders()
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
        XCTAssertNil(attrs["navigation.type"])
        XCTAssertEqual(attrs["funnel.step"] as? Int, 3)
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
