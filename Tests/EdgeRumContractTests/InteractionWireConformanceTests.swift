// Tests/EdgeRumContractTests/InteractionWireConformanceTests.swift
//
// F9 — End-to-end wire conformance for the UIKit interaction-capture
// emit shapes.
//
// The unit-level `InteractionCaptureTests` in
// `Tests/EdgeRumCaptureTests/` drives `InteractionCapture` against a
// probe Recorder to lock the attribute keys and types. This contract
// test pipes a synthesized `user.interaction` event — with the exact
// attribute schema F9 emits — through a real `Recorder` +
// `RecordingTransportSink` and validates the assembled envelope
// against `WireAssertions`.
//
// Without this test a future change in F9's attribute keys could pass
// the unit tests yet break the backend dispatcher. This file is the
// pinning gate.
//
// Refs: PLAN-iOS.md §6.5, §7, §F9; CLAUDE.md "Testing conventions".
//

import XCTest
import Foundation
import EdgeRumCore
@testable import EdgeRum

final class InteractionWireConformanceTests: XCTestCase {

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

    /// A captured `user.interaction` event (T9.1 acceptance — a tap on
    /// a `UIButton` with `accessibilityIdentifier = "checkout"`)
    /// passes through the Recorder → PayloadBuilder → envelope path
    /// and the resulting JSON satisfies the wire contract.
    func testTapInteractionProducesWireValidEvent() throws {
        let (recorder, sink) = makeRecorder()

        recorder.recordEvent(name: "ui.interaction", attributes: [
            "ui.type": .string("tap"),
            "ui.view_class": .string("UIKit.UIButton"),
            "ui.target": .string("checkout"),
        ])
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["type"] as? String, "event")
        XCTAssertEqual(events.first?["eventName"] as? String, "ui.interaction")

        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        try WireAssertions.assertIdentityAttributes(attrs)

        XCTAssertEqual(attrs["ui.type"] as? String, "tap")
        XCTAssertEqual(attrs["ui.view_class"] as? String, "UIKit.UIButton")
        XCTAssertEqual(attrs["ui.target"] as? String, "checkout")
        XCTAssertNil(attrs["interaction.screen"])
    }

    /// `ui.target` is optional in the schema — the wire
    /// envelope must remain valid when the SDK omits it (e.g. a tap on
    /// a plain `UIView` with no identifier and no button title).
    func testTapInteractionWithoutTargetIdIsWireValid() throws {
        let (recorder, sink) = makeRecorder()

        recorder.recordEvent(name: "ui.interaction", attributes: [
            "ui.type": .string("tap"),
            "ui.view_class": .string("UIKit.UIView"),
        ])
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        try WireAssertions.assertIdentityAttributes(attrs)
        XCTAssertNil(attrs["ui.target"])
    }

    /// `interaction.screen` is optional — a tap that lands before any
    /// `viewDidAppear` has fired must still produce a wire-valid
    /// event with the `screen` key absent.
    func testTapInteractionWithoutScreenIsWireValid() throws {
        let (recorder, sink) = makeRecorder()

        recorder.recordEvent(name: "ui.interaction", attributes: [
            "ui.type": .string("tap"),
            "ui.view_class": .string("UIKit.UIButton"),
            "ui.target": .string("checkout")
        ])
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        try WireAssertions.assertIdentityAttributes(attrs)
        XCTAssertNil(attrs["interaction.screen"])
    }

    /// Multiple captured taps in a single batch all reach the wire
    /// with their distinct identifiers preserved — confirms F9's
    /// multi-touch path (one event per `.ended` touch) round-trips
    /// cleanly.
    func testMultipleTapsInOneBatchPreserveOrder() throws {
        let (recorder, sink) = makeRecorder()

        recorder.recordEvent(name: "ui.interaction", attributes: [
            "ui.type": .string("tap"),
            "ui.view_class": .string("UIKit.UIButton"),
            "ui.target": .string("left")
        ])
        recorder.recordEvent(name: "ui.interaction", attributes: [
            "ui.type": .string("tap"),
            "ui.view_class": .string("UIKit.UIButton"),
            "ui.target": .string("right")
        ])
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 2)
        let ids = events.compactMap {
            ($0["attributes"] as? [String: Any])?["ui.target"] as? String
        }
        XCTAssertEqual(Set(ids), ["left", "right"])
    }
}
