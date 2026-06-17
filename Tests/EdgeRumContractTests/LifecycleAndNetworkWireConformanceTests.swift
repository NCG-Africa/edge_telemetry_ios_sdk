// Tests/EdgeRumContractTests/LifecycleAndNetworkWireConformanceTests.swift
//
// F11 — End-to-end wire conformance for the lifecycle (`app_lifecycle`)
// and connectivity (`network_change`) capture emit shapes.
//
// The unit-level `LifecycleCaptureTests` + `NetworkPathCaptureTests` in
// `Tests/EdgeRumCaptureTests/` drive each capture against a probe
// Recorder to lock attribute keys and types. This contract test pipes a
// synthesized event of each kind — with the exact attribute schema F11
// emits — through a real `Recorder` + `RecordingTransportSink` and
// validates the assembled envelope against `WireAssertions`.
//
// Without this test a future change in F11's attribute keys could pass
// the unit tests yet break the backend dispatcher. This file is the
// pinning gate.
//
// Refs: PLAN-iOS.md §6.18, §6.19, §7, §F11; CLAUDE.md "Testing
//       conventions".
//

import XCTest
import Foundation
import EdgeRumCore
@testable import EdgeRum

final class LifecycleAndNetworkWireConformanceTests: XCTestCase {

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

    // MARK: - app_lifecycle

    /// A captured `app_lifecycle` event (T11.1 acceptance — every
    /// transition emits one event carrying `lifecycle.state` and
    /// `lifecycle.previous_state`) survives the Recorder → PayloadBuilder
    /// → envelope path and the assembled JSON satisfies the wire
    /// contract.
    func testAppLifecycleEventProducesWireValidEvent() throws {
        let (recorder, sink) = makeRecorder()

        recorder.recordEvent(name: "app_lifecycle", attributes: [
            "lifecycle.state": .string("backgrounded"),
            "lifecycle.previous_state": .string("inactive")
        ])
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["type"] as? String, "event")
        XCTAssertEqual(events.first?["eventName"] as? String, "app_lifecycle")

        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        try WireAssertions.assertIdentityAttributes(attrs)

        XCTAssertEqual(attrs["lifecycle.state"] as? String, "backgrounded")
        XCTAssertEqual(attrs["lifecycle.previous_state"] as? String, "inactive")
    }

    /// First-emission case — `lifecycle.previous_state == "unknown"`
    /// must still round-trip cleanly.
    func testAppLifecycleFirstEmissionWithUnknownPreviousIsWireValid() throws {
        let (recorder, sink) = makeRecorder()

        recorder.recordEvent(name: "app_lifecycle", attributes: [
            "lifecycle.state": .string("active"),
            "lifecycle.previous_state": .string("unknown")
        ])
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        try WireAssertions.assertIdentityAttributes(attrs)
        XCTAssertEqual(attrs["lifecycle.previous_state"] as? String, "unknown")
    }

    // MARK: - network_change

    /// Wi-Fi → cellular satisfied path — `network_change` carries the
    /// full F11 attribute bag with primitives only, and identity attrs
    /// land alongside.
    func testNetworkChangeCellularPathIsWireValid() throws {
        let (recorder, sink) = makeRecorder()

        recorder.recordEvent(name: "network_change", attributes: [
            "network.type": .string("cellular"),
            "network.effectiveType": .string("cellular"),
            "network.is_expensive": .bool(true),
            "network.is_constrained": .bool(false)
        ])
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["eventName"] as? String, "network_change")

        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        try WireAssertions.assertIdentityAttributes(attrs)
        XCTAssertEqual(attrs["network.type"] as? String, "cellular")
        XCTAssertEqual(attrs["network.effectiveType"] as? String, "cellular")
        XCTAssertEqual(attrs["network.is_expensive"] as? Bool, true)
        XCTAssertEqual(attrs["network.is_constrained"] as? Bool, false)
        XCTAssertNil(attrs["network.unsatisfied_reason"],
                     "Satisfied paths must omit the reason key — never sentinel-string it")
    }

    /// Unsatisfied path on iOS 14.2+ — `network.unsatisfied_reason`
    /// rides as a real string attribute and the envelope stays wire-
    /// valid.
    func testNetworkChangeWithUnsatisfiedReasonIsWireValid() throws {
        let (recorder, sink) = makeRecorder()

        recorder.recordEvent(name: "network_change", attributes: [
            "network.type": .string("none"),
            "network.effectiveType": .string("unknown"),
            "network.is_expensive": .bool(false),
            "network.is_constrained": .bool(false),
            "network.unsatisfied_reason": .string("cellular_denied")
        ])
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        try WireAssertions.assertIdentityAttributes(attrs)
        XCTAssertEqual(attrs["network.type"] as? String, "none")
        XCTAssertEqual(attrs["network.unsatisfied_reason"] as? String, "cellular_denied")
    }

    /// Both event types co-exist in one batch — confirms the F11 events
    /// don't collide on shared attribute namespaces.
    func testLifecycleAndNetworkInSameBatch() throws {
        let (recorder, sink) = makeRecorder()

        recorder.recordEvent(name: "app_lifecycle", attributes: [
            "lifecycle.state": .string("active"),
            "lifecycle.previous_state": .string("foregrounded")
        ])
        recorder.recordEvent(name: "network_change", attributes: [
            "network.type": .string("wifi"),
            "network.effectiveType": .string("wifi"),
            "network.is_expensive": .bool(false),
            "network.is_constrained": .bool(false)
        ])
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 2)
        let names = events.compactMap { $0["eventName"] as? String }
        XCTAssertEqual(Set(names), Set(["app_lifecycle", "network_change"]))
    }
}
