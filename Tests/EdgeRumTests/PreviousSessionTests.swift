// Tests/EdgeRumTests/PreviousSessionTests.swift
//
// F33 / #220 — previous-session evidence on the launch `session.started`.

import XCTest
@testable import EdgeRum
import EdgeRumCore

final class PreviousSessionTests: XCTestCase {

    private let prior: [String: AttributeValue] = [
        "session.id": .string("session_1717234870002_ff009988aabbccdd_ios"),
        "app.state": .string("active"),
        "app.version": .string("2.0.0"),
        "device.platform_version": .string("17.4.1")
    ]

    /// #254: no `device.boot_time` (35F9.1 forbids sending it off-device).
    func testFirstLaunchCarriesNothing() {
        XCTAssertTrue(PreviousSession.attributes(prior: nil, crashed: false).isEmpty)
    }

    func testUnmarkedEndIsUnknownNeverOOM() {
        let attrs = PreviousSession.attributes(prior: prior, crashed: false)
        XCTAssertEqual(attrs["previous_session.id"], prior["session.id"])
        XCTAssertEqual(attrs["previous_session.end"], .string("unknown"))
        XCTAssertEqual(attrs["previous_session.app_state"], .string("foreground"))
        XCTAssertEqual(attrs["previous_session.app_version"], .string("2.0.0"))
        XCTAssertEqual(attrs["previous_session.os_version"], .string("17.4.1"))
    }

    /// Tranche 8 acceptance: after a clean exit, `end = clean`.
    func testCleanExitMarkerReadsClean() {
        var marked = prior
        marked[SessionSidecar.cleanExitKey] = .bool(true)
        let attrs = PreviousSession.attributes(prior: marked, crashed: false)
        XCTAssertEqual(attrs["previous_session.end"], .string("clean"))
    }

    func testCrashWinsOverCleanMarker() {
        var marked = prior
        marked[SessionSidecar.cleanExitKey] = .bool(true)
        let attrs = PreviousSession.attributes(prior: marked, crashed: true)
        XCTAssertEqual(attrs["previous_session.end"], .string("crash"))
    }

    func testAppStateMapsToForegroundOrBackground() {
        for (state, expected) in [("background", "background"), ("inactive", "foreground"), ("active", "foreground")] {
            var p = prior
            p["app.state"] = .string(state)
            XCTAssertEqual(PreviousSession.attributes(prior: p, crashed: false)["previous_session.app_state"],
                           .string(expected), state)
        }
        var p = prior
        p["app.state"] = nil
        XCTAssertNil(PreviousSession.attributes(prior: p, crashed: false)["previous_session.app_state"])
    }

    func testSidecarWithoutSessionIdCarriesNoPreviousSessionKeys() {
        let attrs = PreviousSession.attributes(prior: ["app.state": .string("active")], crashed: true)
        XCTAssertTrue(attrs.isEmpty)
    }


    /// The staged evidence lands on the launch `session.started` only.
    func testRecorderStampsEvidenceOnLaunchSessionStartedOnce() throws {
        let sink = RecordingTransportSink()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876))
        let recorder = Recorder(
            clock: clock,
            sessionManager: SessionManager(store: InMemorySessionStore(), clock: clock),
            sampler: Sampler(sampleRate: 1.0, entropy: { 0.0 }),
            transport: sink,
            sdkVersion: "1.0.0",
            riders: Riders()
        )
        recorder.configure(RecorderConfig(
            apiKey: "edge_test_abc",
            endpoint: URL(string: "https://collect.example.com")!,
            batchSize: 1_000
        ))
        recorder.setLaunchEvidence(["previous_session.end": .string("clean")])
        recorder.start(apiKey: "edge_test_abc", endpoint: URL(string: "https://collect.example.com")!, debug: false)
        recorder.start(apiKey: "edge_test_abc", endpoint: URL(string: "https://collect.example.com")!, debug: false)
        recorder.flush(reason: .manual)

        let started = sink.envelopes.flatMap(\.events).compactMap { event -> AttributeBag? in
            if case let .event("session.started", _, attrs) = event { return attrs }
            return nil
        }
        XCTAssertEqual(started.count, 2)
        XCTAssertEqual(started[0]["previous_session.end"], .string("clean"))
        XCTAssertNil(started[1]["previous_session.end"], "consumed once")
    }
}
