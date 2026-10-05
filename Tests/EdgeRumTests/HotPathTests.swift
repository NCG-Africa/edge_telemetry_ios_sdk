// Tests/EdgeRumTests/HotPathTests.swift
//
// F25 / #212 — RUM coverage tranche 0 ("Hot path").
//
//   (a) O1 inversion: the sidecar is written at the five identity-
//       mutation sites, never from `enqueue`.
//   (b) `sdk.thread_time_ms`: cumulative, session-scoped caller-thread
//       wall-time inside the Recorder ingress, carried on the envelope.
//   (c) Consent guard: after `disable()` nothing is enqueued.
//
// Refs: docs/specs/rum-coverage-roadmap.md § Tranche 0.

import XCTest
@testable import EdgeRum
import EdgeRumCore

final class HotPathTests: XCTestCase {

    // MARK: Helpers

    private func makeRecorder(
        clock: FixedClock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.000)),
        sidecar: SessionSidecarWriting? = nil
    ) -> (Recorder, RecordingTransportSink) {
        let sink = RecordingTransportSink()
        let counter = SeqBytes()
        let recorder = Recorder(
            clock: clock,
            sessionManager: SessionManager(store: InMemorySessionStore(), clock: clock, randomBytes: counter.next),
            sampler: Sampler(sampleRate: 1.0, entropy: { 0.0 }),
            transport: sink,
            sdkVersion: "1.0.0",
            sidecar: sidecar
        )
        recorder.configure(RecorderConfig(
            apiKey: "edge_test_abc",
            endpoint: URL(string: "https://collect.example.com")!,
            batchSize: 1_000
        ))
        recorder.setEnabled(true)
        return (recorder, sink)
    }

    private func mirrored(_ bag: AttributeBag) -> [String: AttributeValue] {
        bag.values.filter { SessionSidecar.mirroredKeys.contains($0.key) }
    }

    // MARK: (a) O1 — negative guard (load-bearing)

    func testRecordEventBurstWithoutIdentityMutationWritesSidecarZeroTimes() {
        let spy = SpySidecar()
        let (recorder, _) = makeRecorder(sidecar: spy)

        for _ in 0..<50 {
            recorder.recordEvent(name: "navigation", attributes: [:])
            recorder.recordPerformance(name: "memory_usage", attributes: [:])
        }
        recorder.flush(reason: .manual)

        XCTAssertEqual(spy.writeCount, 0, "enqueue must never write the sidecar")
    }

    // MARK: (a) O1 — positive, one write per mutation site

    func testEachIdentityMutationSiteWritesCurrentIdentityOnce() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("edge-rum-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("last-session.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = SessionSidecar(url: url)
        let spy = SpySidecar(forwardingTo: file)
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.000))
        let (recorder, _) = makeRecorder(clock: clock)
        let context = recorder.currentContextProvider

        func assertSiteWrote(_ site: String, line: UInt = #line) {
            XCTAssertEqual(spy.writeCount, 1, "\(site) must write exactly once", line: line)
            XCTAssertEqual(file.read(), mirrored(context.snapshot()), "\(site): file ≠ filter(snapshot)", line: line)
            spy.resetCount()
        }

        // 1. installPersistedStores
        recorder.installPersistedStores(
            identityProvider: IdentityProvider(
                keychain: InMemoryKeychainStore(),
                defaults: InMemoryUserDefaultsStore(),
                clock: clock
            ),
            sessionStore: InMemorySessionStore(),
            sidecar: spy
        )
        assertSiteWrote("installPersistedStores")

        // 2. start()
        recorder.start(apiKey: "edge_test_abc", endpoint: URL(string: "https://collect.example.com")!, debug: false)
        assertSiteWrote("start")

        // 3. setUser
        recorder.setUser(RecorderUser(id: "ext-1", name: "Ann", email: "a@x.io", phone: "+254"))
        assertSiteWrote("setUser")
        XCTAssertEqual(file.read()?["user.name"], .string("Ann"))

        // 4. idle rotation
        let before = recorder.currentSessionId
        clock.advance(by: SessionManager.idleRotationInterval + 1)
        recorder.recordEvent(name: "navigation", attributes: [:])
        XCTAssertNotEqual(recorder.currentSessionId, before)
        assertSiteWrote("idle rotation")
        XCTAssertEqual(file.read()?["session.id"], .string(recorder.currentSessionId))

        // 5. didAckBatch
        recorder.didAckBatch()
        assertSiteWrote("didAckBatch")
        XCTAssertEqual(file.read()?["session.sequence"], .int(1))
    }

    // MARK: (b) sdk.thread_time_ms

    func testEnvelopeCarriesCumulativeThreadTime() throws {
        let (recorder, sink) = makeRecorder()

        recorder.recordEvent(name: "navigation", attributes: [:])
        recorder.flush(reason: .manual)
        let first = try XCTUnwrap(sink.envelopes.last?.sdkThreadTimeMs)

        burst(recorder, 20_000)
        recorder.flush(reason: .manual)
        let second = try XCTUnwrap(sink.envelopes.last?.sdkThreadTimeMs)
        XCTAssertGreaterThan(second, first, "cumulative, never a delta")

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sink.envelopes.last!)) as? [String: Any]
        XCTAssertEqual(json?["sdk.thread_time_ms"] as? Int, second)
    }

    func testThreadTimeResetsOnSessionRotation() throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.000))
        let (recorder, sink) = makeRecorder(clock: clock)
        burst(recorder, 20_000)
        recorder.flush(reason: .manual)
        let priorSession = try XCTUnwrap(sink.envelopes.last?.sdkThreadTimeMs)

        clock.advance(by: SessionManager.idleRotationInterval + 1)
        sink.reset()
        recorder.recordPerformance(name: "memory_usage", attributes: [:])
        recorder.flush(reason: .manual)
        let finalized = try XCTUnwrap(sink.envelopes.first { $0.events.contains { $0.name == "session.finalized" } })
        let newSession = try XCTUnwrap(sink.envelopes.last?.sdkThreadTimeMs)

        XCTAssertGreaterThanOrEqual(try XCTUnwrap(finalized.sdkThreadTimeMs), priorSession,
                                    "prior session's last envelope keeps its own total")
        XCTAssertLessThan(newSession, priorSession, "session-scoped: resets on rotation")
    }

    func testStartWithinIdleWindowKeepsThreadTime() throws {
        let (recorder, sink) = makeRecorder()
        burst(recorder, 20_000)
        recorder.start(apiKey: "edge_test_abc", endpoint: URL(string: "https://collect.example.com")!, debug: false)
        recorder.flush(reason: .manual)
        XCTAssertGreaterThan(try XCTUnwrap(sink.envelopes.last?.sdkThreadTimeMs), 0,
                             "start() continuing the same session must not reset")
    }

    /// Acceptance: before/after number for the volume budget. Prints
    /// the burst cost with a real on-disk sidecar wired in.
    func testScriptedBurstThreadTimeMeasurement() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("edge-rum-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("last-session.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (recorder, sink) = makeRecorder(sidecar: SessionSidecar(url: url))

        let count = 100_000
        burst(recorder, count)
        recorder.flush(reason: .manual)

        let ms = try XCTUnwrap(sink.envelopes.last?.sdkThreadTimeMs)
        print("[F25] sdk.thread_time_ms for \(count)-event burst: \(ms)")
    }

    private func burst(_ recorder: Recorder, _ count: Int) {
        for i in 0..<count {
            recorder.recordEvent(name: "user.interaction", attributes: ["interaction.name": .string("b\(i)")])
        }
    }

    // MARK: (c) Consent guard — Recorder level

    func testDisabledRecorderEnqueuesNothing() {
        let (recorder, sink) = makeRecorder()
        recorder.setEnabled(false)

        recorder.recordEvent(name: "custom_event", attributes: [:])
        recorder.recordEvent(name: "app.crash", attributes: [:])
        recorder.recordPerformance(name: "memory_usage", attributes: [:])
        recorder.flush(reason: .manual)

        XCTAssertTrue(sink.envelopes.isEmpty)
    }

    // MARK: (c) Consent guard — public entry points

    func testPublicEmittersEmitNothingAfterDisable() {
        let probe = ProbeRecorder()
        let previous = Recorder.installShared(probe)
        EdgeRum._resetStartedConfigForTesting()
        defer {
            Recorder.installShared(previous)
            EdgeRum._resetStartedConfigForTesting()
        }
        var config = EdgeRumConfig(apiKey: "edge_dev_abc", endpoint: URL(string: "https://collect.example.com")!)
        config.captureNativeCrashes = false
        config.enableHangDetection = false
        config.captureScreens = false
        config.captureHTTP = false
        config.captureTaps = false
        config.captureRenderingPerformance = false
        config.captureLifecycle = false
        config.captureNetworkChanges = false
        config.capturePageLoad = false
        EdgeRum.start(config)  // marks the public API started

        let (recorder, sink) = makeRecorder()
        Recorder.installShared(recorder)
        EdgeRum.disable()

        let timer = EdgeRum.time("checkout")
        EdgeRum.track("buy")
        EdgeRum.captureError(NSError(domain: "x", code: 1))
        timer.end()
        let store = SwiftUIScreenStartStore()
        SwiftUIEmitter.emitScreenAppear(name: "S", attributes: nil, recorder: recorder, clock: recorder.clock, startStore: store)
        SwiftUIEmitter.emitScreenDisappear(name: "S", attributes: nil, recorder: recorder, clock: recorder.clock, startStore: store)
        SwiftUIEmitter.emitTap(name: "t", attributes: nil, recorder: recorder)
        recorder.flush(reason: .manual)

        XCTAssertTrue(sink.envelopes.isEmpty, "disable() must silence every public emitter")
    }
}

// MARK: - Test doubles

private final class SpySidecar: SessionSidecarWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let forward: SessionSidecarWriting?

    init(forwardingTo forward: SessionSidecarWriting? = nil) { self.forward = forward }

    func write(snapshot: AttributeBag) {
        lock.lock(); count += 1; lock.unlock()
        forward?.write(snapshot: snapshot)
    }

    var writeCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    func resetCount() { lock.lock(); count = 0; lock.unlock() }
}

private final class SeqBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var counter: UInt64 = 0
    func next() -> Data {
        lock.lock(); defer { lock.unlock() }
        counter &+= 1
        var v = counter.bigEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }
}
