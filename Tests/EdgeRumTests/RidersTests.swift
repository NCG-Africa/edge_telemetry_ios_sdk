// Tests/EdgeRumTests/RidersTests.swift
//
// F28 / #215 — RUM coverage tranche 3 ("Riders + screen attribution").
//
//   - riders are stamped at enqueue into each event's own attributes
//     (rotation mid-batch → different `device.orientation`)
//   - one-level restore on sheet dismissal
//   - `screen.name` absent until the first screen, capped at 128 B
//   - every change persists through the sidecar's volatile zone,
//     coalesced; `enqueue` still writes nothing
//   - a replayed native crash is not stamped with the live riders
//
// Refs: docs/specs/rum-coverage-roadmap.md § Tranche 3.

import XCTest
@testable import EdgeRum
import EdgeRumCore

final class RidersTests: XCTestCase {

    // MARK: Helpers

    private func makeRecorder(riders: Riders) -> (Recorder, RecordingTransportSink) {
        let sink = RecordingTransportSink()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.000))
        let recorder = Recorder(
            clock: clock,
            sessionManager: SessionManager(store: InMemorySessionStore(), clock: clock),
            sampler: Sampler(sampleRate: 1.0, entropy: { 0.0 }),
            transport: sink,
            sdkVersion: "1.0.0",
            riders: riders
        )
        recorder.configure(RecorderConfig(
            apiKey: "edge_test_abc",
            endpoint: URL(string: "https://collect.example.com")!,
            batchSize: 1_000
        ))
        recorder.setEnabled(true)
        return (recorder, sink)
    }

    /// Event-own attributes (before the flush-time context merge).
    private func attributes(_ event: Event) -> AttributeBag {
        switch event {
        case let .event(_, _, attrs): return attrs
        case let .metric(_, _, _, attrs): return attrs
        }
    }

    private func tempSidecarURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("edge-rum-riders-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("last-session.json")
    }

    // MARK: Stamping

    func testRotationMidBatchStampsEachEventWithItsOwnOrientation() throws {
        let riders = Riders()
        let (recorder, sink) = makeRecorder(riders: riders)

        riders.setOrientation("portrait")
        recorder.recordEvent(name: "custom_event", attributes: [:])
        riders.setOrientation("landscape")
        recorder.recordPerformance(name: "memory_usage", attributes: [:])
        recorder.flush(reason: .manual)

        let events = try XCTUnwrap(sink.envelopes.last).events
        XCTAssertEqual(events.count, 2, "one batch")
        XCTAssertEqual(attributes(events[0])["device.orientation"], .string("portrait"))
        XCTAssertEqual(attributes(events[1])["device.orientation"], .string("landscape"))
    }

    func testAppStateAndScreenRideEveryEvent() throws {
        let riders = Riders()
        let (recorder, sink) = makeRecorder(riders: riders)
        riders.setAppState("background")
        riders.enterScreen("Checkout")

        recorder.recordEvent(name: "network_change", attributes: [:])
        recorder.flush(reason: .manual)

        let attrs = attributes(try XCTUnwrap(sink.envelopes.last?.events.first))
        XCTAssertEqual(attrs["app.state"], .string("background"))
        XCTAssertEqual(attrs["screen.name"], .string("Checkout"))
    }

    func testScreenNameAbsentUntilFirstScreen() throws {
        let riders = Riders()
        let (recorder, sink) = makeRecorder(riders: riders)

        recorder.recordEvent(name: "custom_event", attributes: [:])
        recorder.flush(reason: .manual)

        let attrs = attributes(try XCTUnwrap(sink.envelopes.last?.events.first))
        XCTAssertNil(attrs["screen.name"])
        XCTAssertNil(attrs["device.orientation"])
        XCTAssertNil(attrs["app.state"])
    }

    func testEventOwnValueWinsOverRider() throws {
        let riders = Riders()
        let (recorder, sink) = makeRecorder(riders: riders)
        riders.enterScreen("Next")

        recorder.recordPerformance(name: "custom_timer", attributes: ["screen.name": .string("Leaving")])
        recorder.flush(reason: .manual)

        let attrs = attributes(try XCTUnwrap(sink.envelopes.last?.events.first))
        XCTAssertEqual(attrs["screen.name"], .string("Leaving"))
    }

    func testReplayedNativeCrashIsNotStampedWithLiveRiders() throws {
        let riders = Riders()
        let (recorder, sink) = makeRecorder(riders: riders)
        riders.enterScreen("ReportingLaunchHome")
        riders.setAppState("active")

        // Sidecar-sourced crash-time values; app.state absent on purpose.
        recorder.recordEvent(name: "app.crash", attributes: [
            "screen.name": .string("Checkout")
        ])
        recorder.recordEvent(name: "app.error", attributes: [:])
        recorder.flush(reason: .manual)

        let events = sink.envelopes.flatMap(\.events)
        XCTAssertEqual(events.count, 2)
        let native = attributes(events[0])
        XCTAssertEqual(native["screen.name"], .string("Checkout"))
        XCTAssertNil(native["app.state"], "a live app.state must not describe the crashed launch")
        XCTAssertEqual(attributes(events[1])["app.state"], .string("active"), "handled errors are live")
    }

    // MARK: Screen box

    func testSheetDismissalRestoresPresenter() {
        let riders = Riders()
        riders.enterScreen("Settings")
        riders.enterScreen("Picker")       // sheet presented
        XCTAssertEqual(riders.currentScreen, "Picker")

        riders.leaveScreen("Picker")       // sheet dismissed; presenter's appear does not fire
        XCTAssertEqual(riders.currentScreen, "Settings")

        riders.leaveScreen("Settings")     // only one level is kept
        XCTAssertEqual(riders.currentScreen, "Settings")
    }

    func testFromEdgeIsLastEnteredNotTheRestoredScreen() {
        let riders = Riders()
        XCTAssertNil(riders.enterScreen("A"))
        XCTAssertEqual(riders.enterScreen("B"), "A")
        riders.leaveScreen("B")                       // pop restores A
        XCTAssertEqual(riders.enterScreen("A"), "B", "from-edge is the popped screen")
    }

    func testLeavingANonCurrentScreenIsIgnored() {
        let riders = Riders()
        riders.enterScreen("A")
        riders.enterScreen("B")
        riders.leaveScreen("A")
        XCTAssertEqual(riders.currentScreen, "B")
    }

    func testEmptyScreenNameIsIgnored() {
        let riders = Riders()
        riders.enterScreen("")
        XCTAssertNil(riders.currentScreen)
        XCTAssertTrue(riders.values().isEmpty)
    }

    func testScreenNameCappedAt128BytesWithTruncatedCount() {
        let riders = Riders()
        let long = String(repeating: "é", count: 100)   // 200 B
        riders.enterScreen(long)

        let values = riders.values()
        guard case let .string(name)? = values["screen.name"] else { return XCTFail("screen.name missing") }
        XCTAssertEqual(name.utf8.count, 128)
        XCTAssertEqual(values["screen.name.truncated"], .int(72))

        riders.enterScreen("Short")
        XCTAssertNil(riders.values()["screen.name.truncated"], "omitted when zero")
    }

    func testSwiftUIModifierWritesTheBox() {
        let riders = Riders()
        let probe = ProbeRecorder()
        SwiftUIEmitter.emitScreenAppear(
            name: "Cart", attributes: nil, recorder: probe, riders: riders
        )
        XCTAssertEqual(riders.currentScreen, "Cart")

        SwiftUIEmitter.emitScreenAppear(
            name: "Sheet", attributes: nil, recorder: probe, riders: riders
        )
        SwiftUIEmitter.emitScreenDisappear(name: "Sheet", riders: riders)
        XCTAssertEqual(riders.currentScreen, "Cart", ".sheet dismissal restores the presenter")
    }

    // MARK: Volatile persistence

    func testChangesPersistToSidecarVolatileZoneAlongsideIdentity() throws {
        let url = tempSidecarURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let sidecar = SessionSidecar(url: url)
        sidecar.write(snapshot: [
            "session.id": .string("session_1717234870002_ff009988aabbccdd_ios"),
            "device.id": .string("device_1717234876123_a1b2c3d4e5f60718_ios"),
            "network.type": .string("wifi")
        ])
        let riders = Riders()
        riders.attach(sidecar: sidecar)

        riders.enterScreen("Checkout")
        riders.setOrientation("landscape")
        riders.setAppState("background")
        riders._drainForTesting()

        let read = try XCTUnwrap(sidecar.read())
        XCTAssertEqual(read["screen.name"], .string("Checkout"))
        XCTAssertEqual(read["device.orientation"], .string("landscape"))
        XCTAssertEqual(read["app.state"], .string("background"))
        XCTAssertEqual(read["session.id"], .string("session_1717234870002_ff009988aabbccdd_ios"))
        XCTAssertNil(read["network.type"], "context is never mirrored")

        // A later identity write keeps the volatile zone.
        sidecar.write(snapshot: [
            "session.id": .string("session_1717234870002_ff009988aabbccdd_ios"),
            "device.id": .string("device_1717234876123_a1b2c3d4e5f60718_ios"),
            "session.sequence": .int(3)
        ])
        XCTAssertEqual(sidecar.read()?["screen.name"], .string("Checkout"))
        XCTAssertEqual(sidecar.read()?["session.sequence"], .int(3))
    }

    func testVolatileWriteBeforeIdentityWriteLandsVolatileOnly() throws {
        let url = tempSidecarURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let sidecar = SessionSidecar(url: url)
        sidecar.writeVolatile(["app.state": .string("active"), "network.type": .string("wifi")])
        XCTAssertEqual(sidecar.read(), ["app.state": .string("active")])
    }

    func testBurstOfChangesCoalescesAndEnqueueWritesNothing() {
        let spy = VolatileSpy()
        let riders = Riders()
        let (recorder, _) = makeRecorder(riders: riders)
        riders.attach(sidecar: spy)
        riders._drainForTesting()
        spy.reset()

        for i in 0..<200 { riders.enterScreen("S\(i)") }
        riders._drainForTesting()
        XCTAssertGreaterThanOrEqual(spy.volatileWrites, 1)
        XCTAssertLessThan(spy.volatileWrites, 200, "a burst collapses")
        XCTAssertEqual(spy.lastVolatile?["screen.name"], .string("S199"), "latest wins")

        spy.reset()
        for _ in 0..<50 {
            recorder.recordEvent(name: "custom_event", attributes: [:])
            recorder.recordPerformance(name: "memory_usage", attributes: [:])
        }
        riders._drainForTesting()
        XCTAssertEqual(spy.volatileWrites, 0, "enqueue never writes the sidecar")
        XCTAssertEqual(spy.identityWrites, 0)
    }

    func testUnchangedValueSchedulesNoWrite() {
        let spy = VolatileSpy()
        let riders = Riders()
        riders.setOrientation("portrait")
        riders.attach(sidecar: spy)
        riders._drainForTesting()
        spy.reset()

        riders.setOrientation("portrait")
        riders.enterScreen("A")
        riders._drainForTesting()
        spy.reset()
        riders.enterScreen("A")
        riders._drainForTesting()
        XCTAssertEqual(spy.volatileWrites, 0)
    }

    // MARK: device.family

    func testDeviceFamilyIsContext() {
        var bag = AttributeBag()
        DeviceContext(family: "pad").write(into: &bag)
        XCTAssertEqual(bag["device.family"], .string("pad"))

        var empty = AttributeBag()
        DeviceContext().write(into: &empty)
        XCTAssertNil(empty["device.family"], "omitted when unread")
    }
}

private final class VolatileSpy: SessionSidecarWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var _identity = 0
    private var _volatile = 0
    private var _last: [String: AttributeValue]?

    func write(snapshot: AttributeBag) { lock.lock(); _identity += 1; lock.unlock() }
    func writeVolatile(_ values: [String: AttributeValue]) {
        lock.lock(); _volatile += 1; _last = values; lock.unlock()
    }

    var identityWrites: Int { lock.lock(); defer { lock.unlock() }; return _identity }
    var volatileWrites: Int { lock.lock(); defer { lock.unlock() }; return _volatile }
    var lastVolatile: [String: AttributeValue]? { lock.lock(); defer { lock.unlock() }; return _last }
    func reset() { lock.lock(); _identity = 0; _volatile = 0; lock.unlock() }
}
