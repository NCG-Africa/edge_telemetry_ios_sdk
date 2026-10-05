// Tests/EdgeRumTests/PrivacyTests.swift
//
// F27 / #214 — RUM coverage tranche 2 ("Privacy").
//
//   (a) `clearUser()` drops host identity from every later event.
//   (b) `resetIdentity()` mints a fresh `device.id` + `user.id`.
//   (c) `user.name` / `user.email` / `user.phone` never reach the sidecar.
//
// Refs: docs/specs/rum-coverage-roadmap.md § Tranche 2.

import XCTest
@testable import EdgeRum
import EdgeRumCore

final class PrivacyTests: XCTestCase {

    private static let identityKeys = ["user.name", "user.email", "user.phone", "user.external_id"]

    private var sidecarURL: URL!

    override func setUp() {
        super.setUp()
        sidecarURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("edge-rum-privacy-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("last-session.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: sidecarURL.deletingLastPathComponent())
        super.tearDown()
    }

    private var identityProvider: IdentityProvider!

    private func makeRecorder() -> (Recorder, RecordingTransportSink, SessionSidecar) {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.000))
        let sink = RecordingTransportSink()
        let sidecar = SessionSidecar(url: sidecarURL)
        let recorder = Recorder(
            clock: clock,
            sessionManager: SessionManager(store: InMemorySessionStore(), clock: clock),
            sampler: Sampler(sampleRate: 1.0, entropy: { 0.0 }),
            transport: sink,
            sdkVersion: "1.0.0"
        )
        recorder.configure(RecorderConfig(
            apiKey: "edge_test_abc",
            endpoint: URL(string: "https://collect.example.com")!,
            batchSize: 1_000
        ))
        identityProvider = IdentityProvider(
            keychain: InMemoryKeychainStore(),
            defaults: InMemoryUserDefaultsStore(),
            clock: clock
        )
        recorder.installPersistedStores(
            identityProvider: identityProvider,
            sessionStore: InMemorySessionStore(),
            sidecar: sidecar
        )
        recorder.setEnabled(true)
        return (recorder, sink, sidecar)
    }

    private func lastEvent(_ recorder: Recorder, _ sink: RecordingTransportSink) -> Event? {
        recorder.recordEvent(name: "navigation", attributes: [:])
        recorder.flush(reason: .manual)
        return sink.envelopes.last?.events.last
    }

    // MARK: (a) clearUser

    func testClearUserDropsHostIdentityFromLaterEvents() throws {
        let (recorder, sink, _) = makeRecorder()
        recorder.setUser(RecorderUser(id: "ext-1", name: "Ann", email: "a@x.io", phone: "+254"))
        let userId = recorder.currentContextProvider.currentUser().id
        XCTAssertEqual(lastEvent(recorder, sink)?.attributes["user.email"], .string("a@x.io"))

        recorder.clearUser()

        let event = try XCTUnwrap(lastEvent(recorder, sink))
        for key in Self.identityKeys {
            XCTAssertNil(event.attributes[key], "\(key) survived clearUser()")
        }
        XCTAssertEqual(event.attributes["user.id"], .string(userId), "clearUser() keeps the SDK-owned user.id")
    }

    // MARK: (b) resetIdentity

    func testResetIdentityMintsFreshWellFormedIds() throws {
        let (recorder, sink, sidecar) = makeRecorder()
        recorder.setUser(RecorderUser(id: "ext-1", name: "Ann", email: "a@x.io", phone: "+254"))
        let before = try XCTUnwrap(lastEvent(recorder, sink))

        recorder.resetIdentity()

        let after = try XCTUnwrap(lastEvent(recorder, sink))
        guard case let .string(deviceId)? = after.attributes["device.id"],
              case let .string(userId)? = after.attributes["user.id"] else {
            return XCTFail("missing ids after resetIdentity()")
        }
        XCTAssertNotEqual(after.attributes["device.id"], before.attributes["device.id"])
        XCTAssertNotEqual(after.attributes["user.id"], before.attributes["user.id"])
        XCTAssertTrue(IdentityFormat.isValid(deviceId, kind: .device), deviceId)
        XCTAssertTrue(IdentityFormat.isValid(userId, kind: .user), userId)
        XCTAssertEqual(recorder.currentDeviceId, deviceId)
        for key in Self.identityKeys {
            XCTAssertNil(after.attributes[key], "\(key) survived resetIdentity()")
        }
        XCTAssertEqual(sidecar.read()?["device.id"], .string(deviceId))
        XCTAssertEqual(sidecar.read()?["user.id"], .string(userId))

        // Persisted, so a relaunch resolves the new ids.
        let persisted = identityProvider.resolve()
        XCTAssertEqual(persisted.deviceId, deviceId)
        XCTAssertEqual(persisted.userId, userId)

        // Documented: the session is not rotated (ADR-019).
        XCTAssertEqual(after.attributes["session.id"], before.attributes["session.id"])
    }

    // MARK: (c) sidecar

    func testSidecarNeverContainsHostIdentity() throws {
        let (recorder, _, sidecar) = makeRecorder()
        recorder.setUser(RecorderUser(id: "ext-1", name: "Ann", email: "a@x.io", phone: "+254"))

        let raw = try String(contentsOf: sidecarURL, encoding: .utf8)
        for key in ["user.name", "user.email", "user.phone"] {
            XCTAssertFalse(raw.contains(key), "sidecar file carries \(key)")
        }
        XCTAssertFalse(raw.contains("a@x.io"))
        XCTAssertNotNil(sidecar.read()?["user.id"], "user.id stays mirrored")
    }
}
