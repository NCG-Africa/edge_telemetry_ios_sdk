// Tests/EdgeRumContractTests/AppErrorWireConformanceTests.swift
//
// F13 — End-to-end wire conformance for the application-error
// (`app.crash` with `cause = "AppError"`) emit shape.
//
// The unit-level `AppErrorBuilderTests` lock the attribute keys +
// types. This contract test pipes a synthesized `app.crash` event
// built by `AppErrorBuilder` through a real `Recorder` +
// `RecordingTransportSink` and validates the assembled envelope
// against `WireAssertions`.
//
// Refs: PLAN-iOS.md §6.6, §7, §F13; CLAUDE.md "Testing conventions".
//

import XCTest
import Foundation
import EdgeRumCore
@testable import EdgeRum

final class AppErrorWireConformanceTests: XCTestCase {

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

    // MARK: - NSError → app.crash (T13.2 acceptance)

    func testNSErrorAppCrashEnvelopeIsWireValid() throws {
        let (recorder, sink) = makeRecorder()
        let err = NSError(domain: "PaymentDomain", code: 42, userInfo: [
            NSLocalizedDescriptionKey: "Card declined",
            "merchant.id": "m_abc",
            "retry.count": 3
        ])
        let attrs = AppErrorBuilder.build(
            error: err,
            context: ["payment.method": .string("card")],
            stack: ["0   EdgeRum   0x0001  +[F13 captureError:_:context:]",
                    "1   EdgeRum   0x0002  caller_frame"],
            debug: false
        )
        recorder.recordEvent(name: "app.crash", attributes: attrs)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["type"] as? String, "event")
        XCTAssertEqual(events.first?["eventName"] as? String, "app.crash")

        let wireAttrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        try WireAssertions.assertIdentityAttributes(wireAttrs)

        // Fixed payload contract
        XCTAssertEqual(wireAttrs["cause"] as? String, "AppError")
        XCTAssertEqual(wireAttrs["runtime"] as? String, "swift")
        XCTAssertEqual(wireAttrs["error.kind"] as? String, "nserror")
        XCTAssertEqual(wireAttrs["error.type"] as? String, "NSError")
        XCTAssertEqual(wireAttrs["error.domain"] as? String, "PaymentDomain")
        XCTAssertEqual(wireAttrs["error.code"] as? Int, 42)
        XCTAssertEqual(wireAttrs["error.message"] as? String, "Card declined")

        // T13.2: NSError.userInfo flattens with the `error.userInfo.`
        // prefix. Primitives survive.
        XCTAssertEqual(
            wireAttrs["error.userInfo.\(NSLocalizedDescriptionKey)"] as? String,
            "Card declined"
        )
        XCTAssertEqual(wireAttrs["error.userInfo.merchant.id"] as? String, "m_abc")
        XCTAssertEqual(wireAttrs["error.userInfo.retry.count"] as? Int, 3)

        // T13.1: caller-context keys arrive prefixed `crash.context.`,
        // never bare.
        XCTAssertEqual(wireAttrs["crash.context.payment.method"] as? String, "card")
        XCTAssertNil(wireAttrs["payment.method"])

        // Stack present
        XCTAssertNotNil(wireAttrs["error.stack"] as? String)
    }

    // MARK: - Swift Error → app.crash (T13.1 acceptance)

    func testSwiftErrorAppCrashEnvelopeIsWireValid() throws {
        let (recorder, sink) = makeRecorder()
        enum DecodingFailure: Error { case keyNotFound(String) }
        let attrs = AppErrorBuilder.build(
            error: DecodingFailure.keyNotFound("invoice_id"),
            context: ["screen": .string("Receipt")],
            stack: ["0   EdgeRum   0x0001  test_frame"],
            debug: false
        )
        recorder.recordEvent(name: "app.crash", attributes: attrs)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        let wireAttrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        try WireAssertions.assertIdentityAttributes(wireAttrs)

        XCTAssertEqual(wireAttrs["cause"] as? String, "AppError")
        XCTAssertEqual(wireAttrs["runtime"] as? String, "swift")
        XCTAssertEqual(wireAttrs["error.kind"] as? String, "swift")
        XCTAssertEqual(wireAttrs["error.type"] as? String, "DecodingFailure")
        XCTAssertEqual(wireAttrs["crash.context.screen"] as? String, "Receipt")
        XCTAssertNil(wireAttrs["screen"])

        // Swift errors must NOT carry error.userInfo.* keys.
        let userInfoKeys = wireAttrs.keys.filter { $0.hasPrefix("error.userInfo.") }
        XCTAssertTrue(userInfoKeys.isEmpty,
                      "Swift errors must not surface bridged userInfo")
    }

    // MARK: - Non-primitive drop (T13.2 acceptance)

    func testNonPrimitiveUserInfoIsDroppedSilently() throws {
        let (recorder, sink) = makeRecorder()
        let underlying = NSError(domain: "Underlying", code: 9)
        let outer = NSError(domain: "Outer", code: 1, userInfo: [
            "kept": "v",
            "dropped_dict": ["k": 1] as [String: Int],
            "dropped_obj": underlying
        ])
        let attrs = AppErrorBuilder.build(
            error: outer,
            context: [:],
            stack: ["0   x   y"],
            debug: false
        )
        recorder.recordEvent(name: "app.crash", attributes: attrs)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        let wireAttrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])

        XCTAssertEqual(wireAttrs["error.userInfo.kept"] as? String, "v")
        XCTAssertNil(wireAttrs["error.userInfo.dropped_dict"])
        XCTAssertNil(wireAttrs["error.userInfo.dropped_obj"])
    }

    // MARK: - Primitives-only sanity (defense-in-depth)

    func testAppCrashAttributesArePrimitives() throws {
        let (recorder, sink) = makeRecorder()
        let attrs = AppErrorBuilder.build(
            error: NSError(domain: "x", code: 0, userInfo: [
                "s": "string", "i": 7, "d": 1.5, "b": true
            ]),
            context: ["c": .string("v")],
            stack: ["0   y   z"],
            debug: false
        )
        recorder.recordEvent(name: "app.crash", attributes: attrs)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (data, _) = try WireAssertions.assertValidEnvelope(envelope)

        // Belt and braces — wire bytes don't carry forbidden tokens.
        let raw = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(raw.contains("\"traceId\""))
        XCTAssertFalse(raw.contains("\"spanId\""))
        XCTAssertFalse(raw.contains("\"resourceSpans\""))
        XCTAssertFalse(raw.lowercased().contains("opentelemetry"))
    }

    // MARK: - Co-existence with other event types

    func testAppCrashInSameBatchWithOtherEvents() throws {
        let (recorder, sink) = makeRecorder()
        // `app.crash` triggers an immediate flush, so emit it last and
        // assert both events ride the same envelope.
        recorder.recordEvent(name: "navigation", attributes: [
            "navigation.kind": .string("uikit"),
            "navigation.name": .string("Cart")
        ])
        let crashAttrs = AppErrorBuilder.build(
            error: NSError(domain: "x", code: 1),
            context: [:],
            stack: ["0   x   y"],
            debug: false
        )
        recorder.recordEvent(name: "app.crash", attributes: crashAttrs)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 2)
        let names = events.compactMap { $0["eventName"] as? String }
        XCTAssertEqual(Set(names), Set(["navigation", "app.crash"]))
    }
}
