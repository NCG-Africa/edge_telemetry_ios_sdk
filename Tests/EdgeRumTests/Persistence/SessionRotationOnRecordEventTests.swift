// Tests/EdgeRumTests/Persistence/SessionRotationOnRecordEventTests.swift
//
// Covers the F4 addition to `Recorder.recordEvent` /
// `Recorder.recordPerformance`: each ingress bumps the SessionManager's
// last-active timestamp. When the bump crosses the 30-min idle
// threshold, the Recorder emits a `session.finalized` (with the prior
// session id) + `session.started` (with the new one) pair before
// processing the originating event.
//
// Also covers `didAckBatch()` — issue #43 acceptance:
// three consecutive ACKed batches → an event emitted after the third
// ACK reads `session.sequence == 3`.

import XCTest
@testable import EdgeRum
import EdgeRumCore

final class SessionRotationOnRecordEventTests: XCTestCase {

    // MARK: Helpers

    private func makeRecorder(
        clock: FixedClock,
        sessionStore: SessionStore = InMemorySessionStore(),
        randomBytes: @escaping () -> Data = { Data([0xa1, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6, 0x07, 0x18]) }
    ) -> (Recorder, RecordingTransportSink, SessionManager) {
        let sink = RecordingTransportSink()
        let manager = SessionManager(
            store: sessionStore,
            clock: clock,
            randomBytes: randomBytes
        )
        let recorder = Recorder(
            clock: clock,
            sessionManager: manager,
            sampler: Sampler(sampleRate: 1.0, entropy: { 0.0 }),
            transport: sink,
            sdkVersion: "1.0.0"
        )
        recorder.configure(RecorderConfig(
            apiKey: "edge_test_abc",
            endpoint: URL(string: "https://collect.example.com")!,
            debug: false,
            sampleRate: 1.0,
            batchSize: 100,
            flushInterval: 5.0,
            location: nil
        ))
        return (recorder, sink, manager)
    }

    // MARK: last-active bump

    func testRecordEventBumpsLastActiveOnSessionManager() {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.000))
        let (recorder, _, manager) = makeRecorder(clock: clock)
        let beforeId = manager.currentState()?.id

        clock.advance(by: 60)
        recorder.recordEvent(name: "navigation", attributes: [:])

        let after = manager.currentState()
        XCTAssertEqual(after?.id, beforeId, "60s bump must not rotate")
        XCTAssertEqual(after?.lastActiveAt, clock.now)
    }

    func testRecordPerformanceBumpsLastActiveOnSessionManager() {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.000))
        let (recorder, _, manager) = makeRecorder(clock: clock)

        clock.advance(by: 60)
        recorder.recordPerformance(name: "memory_usage", attributes: [:])

        XCTAssertEqual(manager.currentState()?.lastActiveAt, clock.now)
    }

    // MARK: Mid-event rotation

    func testRecordEventAcrossIdleThresholdEmitsFinalizedThenStarted() {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.000))
        // Counter random bytes so the rotated session id differs from
        // the original.
        let counter = SeqRandom()
        let (recorder, sink, _) = makeRecorder(
            clock: clock,
            randomBytes: counter.next
        )
        // Capture the original session id from the first emitted event.
        recorder.recordEvent(name: "navigation", attributes: [:])
        recorder.flush(reason: .manual)
        let originalSession = sink.envelopes.last?.events.first?.attributes["session.id"]
        XCTAssertNotNil(originalSession)

        sink.reset()

        // Cross the 30-min threshold.
        clock.advance(by: SessionManager.idleRotationInterval + 1)

        recorder.recordEvent(name: "navigation", attributes: [:])
        recorder.flush(reason: .manual)

        // Order: finalized (immediate-flush) → started → navigation.
        // The first envelope (finalized) is flushed immediately on
        // emit; the started + navigation pair flushes on the manual
        // flush below.
        let allEvents = sink.envelopes.flatMap { $0.events }
        let names = allEvents.map(\.name)
        XCTAssertEqual(
            names.firstIndex(of: "session.finalized") ?? .max,
            0,
            "session.finalized must come first"
        )
        XCTAssertNotNil(names.firstIndex(of: "session.started"))
        XCTAssertNotNil(names.firstIndex(of: "navigation"))

        // The finalized event carries the prior session id (not the
        // rotated one) per the F4 mid-event rotation contract.
        if let finalized = allEvents.first(where: { $0.name == "session.finalized" }) {
            XCTAssertEqual(finalized.attributes["session.id"], originalSession)
            XCTAssertEqual(finalized.attributes["session.rotation"], .string("idle"))
        }
    }

    // MARK: didAckBatch — issue #43 acceptance

    func testThreeAcksYieldSequenceThree() {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.000))
        let (recorder, sink, _) = makeRecorder(clock: clock)

        recorder.didAckBatch()
        recorder.didAckBatch()
        recorder.didAckBatch()

        recorder.recordEvent(name: "navigation", attributes: [:])
        recorder.flush(reason: .manual)

        let event = sink.envelopes.last?.events.first
        XCTAssertEqual(event?.attributes["session.sequence"], .int(3))
    }

    func testDidAckBatchUpdatesSidecarSnapshot() throws {
        let url = makeTempSidecarURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.000))
        let sidecar = SessionSidecar(url: url)
        let sink = RecordingTransportSink()
        let recorder = Recorder(
            clock: clock,
            sessionManager: SessionManager(clock: clock),
            sampler: Sampler(sampleRate: 1.0, entropy: { 0.0 }),
            transport: sink,
            sdkVersion: "1.0.0",
            sidecar: sidecar
        )
        recorder.configure(RecorderConfig(
            apiKey: "edge_test_abc",
            endpoint: URL(string: "https://collect.example.com")!
        ))

        // Force an enqueue so the sidecar has something to mirror.
        recorder.recordEvent(name: "navigation", attributes: [:])
        recorder.didAckBatch()

        let mirrored = sidecar.read()
        XCTAssertEqual(mirrored?["session.sequence"], .int(1))
    }

    // MARK: installPersistedStores

    func testInstallPersistedStoresPullsDeviceAndUserFromIdentityProvider() {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.000))
        let (recorder, sink, _) = makeRecorder(clock: clock)

        let kc = InMemoryKeychainStore()
        try? kc.write(
            "device_1717100000000_aaaaaaaaaaaaaaaa_ios",
            service: EdgeRumStorage.keychainService,
            account: EdgeRumStorage.keychainAccountDeviceId
        )
        let defaults = InMemoryUserDefaultsStore()
        defaults.set("user_1717100000000_bbbbbbbbbbbbbbbb", forKey: EdgeRumStorage.keyUserId)
        let identityProvider = IdentityProvider(
            keychain: kc,
            defaults: defaults,
            clock: clock
        )
        let sessionStore = UserDefaultsSessionStore(defaults: defaults)

        recorder.installPersistedStores(
            identityProvider: identityProvider,
            sessionStore: sessionStore,
            sidecar: nil
        )

        recorder.recordEvent(name: "navigation", attributes: [:])
        recorder.flush(reason: .manual)

        let event = sink.envelopes.last?.events.first
        XCTAssertEqual(event?.attributes["device.id"], .string("device_1717100000000_aaaaaaaaaaaaaaaa_ios"))
        XCTAssertEqual(event?.attributes["user.id"], .string("user_1717100000000_bbbbbbbbbbbbbbbb"))
    }

    func testInstallPersistedStoresPreservesPersistedSessionWithinIdleWindow() {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.000))
        let defaults = InMemoryUserDefaultsStore()
        let priorState = SessionState(
            id: "session_1717234870000_cccccccccccccccc_ios",
            startTime: Date(timeIntervalSince1970: 1_717_234_870.0),
            sequence: 5,
            lastActiveAt: Date(timeIntervalSince1970: 1_717_234_870.0)
        )
        UserDefaultsSessionStore(defaults: defaults).save(priorState)

        let (recorder, sink, _) = makeRecorder(clock: clock)

        recorder.installPersistedStores(
            identityProvider: IdentityProvider(
                keychain: InMemoryKeychainStore(),
                defaults: defaults,
                clock: clock
            ),
            sessionStore: UserDefaultsSessionStore(defaults: defaults),
            sidecar: nil
        )

        recorder.recordEvent(name: "navigation", attributes: [:])
        recorder.flush(reason: .manual)

        let event = sink.envelopes.last?.events.first
        XCTAssertEqual(
            event?.attributes["session.id"],
            .string("session_1717234870000_cccccccccccccccc_ios"),
            "Persisted session within idle window must be reused"
        )
        XCTAssertEqual(event?.attributes["session.sequence"], .int(5))
    }

    // MARK: Helpers

    private func makeTempSidecarURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edge-rum-tests-\(UUID().uuidString)", isDirectory: true)
        return dir.appendingPathComponent("last-session.json")
    }
}

private final class SeqRandom: @unchecked Sendable {
    private let lock = NSLock()
    private var counter: UInt64 = 0
    func next() -> Data {
        lock.lock(); defer { lock.unlock() }
        counter &+= 1
        var v = counter.bigEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }
}
