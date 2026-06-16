// Tests/EdgeRumContractTests/IdentityPersistenceConformanceTests.swift
//
// F4 contract test: when persistence is wired in via
// `Recorder.installPersistedStores(...)`, every event emitted by the
// Recorder carries `device.id` / `session.id` / `user.id` values
// that:
//
//   1. match the `IdentityFormat` regex for their kind,
//   2. match the values currently persisted in the Keychain /
//      UserDefaults pair the IdentityProvider was constructed with,
//      and
//   3. round-trip through the on-disk `last-session.json` sidecar
//      unchanged.
//
// This is the wire-conformance bar for F4: a host app that swaps
// in real persistence must NOT see drift between the persisted
// identifiers and the ones the backend receives.

import XCTest
import EdgeRumCore

final class IdentityPersistenceConformanceTests: XCTestCase {

    func testPersistedIdentityFlowsThroughEveryEvent() throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.512))

        // Pre-seed Keychain + UserDefaults with valid identifiers so
        // we can assert the emitted attributes equal the persisted
        // values exactly.
        let keychain = InMemoryKeychainStore()
        try keychain.write(
            "device_1717100000000_aabbccddeeff0011_ios",
            service: EdgeRumStorage.keychainService,
            account: EdgeRumStorage.keychainAccountDeviceId
        )
        let defaults = InMemoryUserDefaultsStore()
        defaults.set(
            "user_1717100000000_2233445566778899",
            forKey: EdgeRumStorage.keyUserId
        )

        let sidecarURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("edge-rum-contract-\(UUID().uuidString)")
            .appendingPathComponent("last-session.json")
        defer { try? FileManager.default.removeItem(at: sidecarURL.deletingLastPathComponent()) }
        let sidecar = SessionSidecar(url: sidecarURL)

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
        recorder.installPersistedStores(
            identityProvider: IdentityProvider(
                keychain: keychain,
                defaults: defaults,
                clock: clock
            ),
            sessionStore: UserDefaultsSessionStore(defaults: defaults),
            sidecar: sidecar
        )

        // Emit a mix of events.
        recorder.recordEvent(name: "navigation", attributes: ["navigation.kind": "uikit"])
        recorder.recordPerformance(name: "memory_usage", attributes: ["value": 42.0])
        recorder.recordEvent(name: "custom_event", attributes: [
            "event.name": "checkout_started"
        ])
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])

        for (idx, event) in events.enumerated() {
            let attrs = try XCTUnwrap(
                event["attributes"] as? [String: Any],
                "event \(idx) missing attributes"
            )

            try WireAssertions.assertIdentityAttributes(attrs)

            // Persisted-value pinning.
            XCTAssertEqual(
                attrs["device.id"] as? String,
                "device_1717100000000_aabbccddeeff0011_ios",
                "event \(idx) device.id must equal the persisted Keychain value"
            )
            XCTAssertEqual(
                attrs["user.id"] as? String,
                "user_1717100000000_2233445566778899",
                "event \(idx) user.id must equal the persisted UserDefaults value"
            )

            // Format regex pinning.
            let deviceId = attrs["device.id"] as? String ?? ""
            let sessionId = attrs["session.id"] as? String ?? ""
            let userId = attrs["user.id"] as? String ?? ""
            XCTAssertTrue(IdentityFormat.isValid(deviceId, kind: .device),
                          "event \(idx) device.id format invalid: \(deviceId)")
            XCTAssertTrue(IdentityFormat.isValid(sessionId, kind: .session),
                          "event \(idx) session.id format invalid: \(sessionId)")
            XCTAssertTrue(IdentityFormat.isValid(userId, kind: .user),
                          "event \(idx) user.id format invalid: \(userId)")
        }

        // Sidecar round-trip — the file on disk holds the same identity.
        let mirrored = try XCTUnwrap(sidecar.read())
        let firstAttrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        XCTAssertEqual(
            mirrored["device.id"],
            .string(firstAttrs["device.id"] as? String ?? "")
        )
        XCTAssertEqual(
            mirrored["session.id"],
            .string(firstAttrs["session.id"] as? String ?? "")
        )
        XCTAssertEqual(
            mirrored["user.id"],
            .string(firstAttrs["user.id"] as? String ?? "")
        )
    }
}
