// Tests/EdgeRumTests/ActionsTests.swift
//
// F36 / #223 — RUM coverage tranche 12 ("Action lifecycle"). Acceptance:
//
//   - an OTP-style background hop ends `completed` with
//     `background_count = 1`
//   - out-of-order completion removes by identity and the rider falls back
//   - a process killed mid-action yields `abandoned` / `process_death`
//     next launch
//   - the name cap emits `action.name.dropped`
//
// Plus rotation / timeout abandonment, idempotency, `parent_id`, and
// session sampling.
//
// Refs: docs/specs/rum-coverage-roadmap.md § Tranche 12.

import XCTest
@testable import EdgeRum
import EdgeRumCore

final class ActionsTests: XCTestCase {

    // MARK: Helpers

    private var dir: URL!
    private var nowNs: UInt64 = 0

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edge-rum-actions-\(UUID().uuidString)", isDirectory: true)
        nowNs = 1_000_000_000
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private var fileURL: URL { dir.appendingPathComponent("open-actions.json") }

    private struct Rig {
        let recorder: Recorder
        let sink: RecordingTransportSink
        let actions: Actions
        let riders: Riders
        let clock: FixedClock

        func start(_ name: String) -> RumAction {
            RumAction(name: name, recorder: recorder, actions: actions, live: true)
        }

        func events(_ name: String) -> [AttributeBag] {
            recorder.flush(reason: .manual)
            return sink.envelopes.flatMap(\.events).compactMap {
                if case let .event(n, _, attrs) = $0, n == name { return attrs }
                return nil
            }
        }
    }

    private func makeRig(sampleRate: Double = 1.0, url: URL? = nil) -> Rig {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.000))
        let riders = Riders()
        let actions = Actions(riders: riders, monotonicNs: { [unowned self] in nowNs })
        actions.configure(url: url)
        let sink = RecordingTransportSink()
        let recorder = Recorder(
            clock: clock,
            sessionManager: SessionManager(store: InMemorySessionStore(), clock: clock),
            sampler: Sampler(sampleRate: sampleRate, entropy: { 0.5 }),
            transport: sink,
            sdkVersion: "1.0.0",
            riders: riders,
            breadcrumbs: Breadcrumbs(),
            actions: actions
        )
        recorder.configure(RecorderConfig(
            apiKey: "edge_test_abc",
            endpoint: URL(string: "https://collect.example.com")!,
            sampleRate: sampleRate,
            batchSize: 1_000
        ))
        recorder.setEnabled(true)
        return Rig(recorder: recorder, sink: sink, actions: actions, riders: riders, clock: clock)
    }

    // MARK: Acceptance

    func testOTPBackgroundHopEndsCompletedWithOneBackground() {
        let rig = makeRig()
        let checkout = rig.start("checkout")
        rig.actions.noteAppState("inactive")
        rig.actions.noteAppState("background")
        nowNs += 12_000_000_000  // 12 s fetching the OTP
        rig.actions.noteAppState("inactive")
        rig.actions.noteAppState("active")
        checkout.complete()

        let ended = rig.events("action.ended")
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(ended[0]["action.outcome"], .string("completed"))
        XCTAssertEqual(ended[0]["action.background_count"], .int(1))
        XCTAssertEqual(ended[0]["action.background_duration_ms"], .int(12_000))
        XCTAssertNil(ended[0]["action.abandon_reason"])
    }

    func testOutOfOrderCompletionRemovesByIdentityAndRiderFallsBack() {
        let rig = makeRig()
        let outer = rig.start("checkout")
        let inner = rig.start("apply_promo")
        let started = rig.events("action.started")
        let outerId = started[0]["action.id"]
        let innerId = started[1]["action.id"]
        XCTAssertEqual(started[1]["action.parent_id"], outerId)
        XCTAssertNil(started[0]["action.parent_id"])
        XCTAssertEqual(rig.riders.values()["action.id"], innerId, "rider = top of the stack")

        outer.complete()  // not the top
        XCTAssertEqual(rig.riders.values()["action.id"], innerId)
        rig.recorder.recordEvent(name: "navigation", attributes: [:])
        XCTAssertEqual(rig.events("navigation").last?["action.id"], innerId)

        inner.complete()
        XCTAssertNil(rig.riders.values()["action.id"])
        rig.recorder.recordEvent(name: "custom_event", attributes: [:])
        XCTAssertNil(rig.events("custom_event").last?["action.id"])

        let ended = rig.events("action.ended")
        XCTAssertEqual(ended.map { $0["action.id"] }, [outerId, innerId], "own id wins over the rider")
    }

    func testProcessDeathIsAbandonedNextLaunch() {
        let rig = makeRig(url: fileURL)
        _ = rig.start("checkout")
        rig.actions.noteAppState("background")
        rig.actions._drainForTesting()
        // …process dies here.

        let prior = Actions.takePrior(url: fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "read and deleted")
        XCTAssertEqual(prior.count, 1)
        XCTAssertEqual(prior[0]["action.name"], .string("checkout"))
        XCTAssertEqual(prior[0]["action.outcome"], .string("abandoned"))
        XCTAssertEqual(prior[0]["action.abandon_reason"], .string("process_death"))
        XCTAssertEqual(prior[0]["action.background_count"], .int(1))
        XCTAssertEqual(prior[0]["action.id"], rig.events("action.started")[0]["action.id"])
        XCTAssertTrue(Actions.takePrior(url: fileURL).isEmpty)
    }

    func testFileRemovedOnceNothingIsOpen() {
        let rig = makeRig(url: fileURL)
        let a = rig.start("checkout")
        rig.actions._drainForTesting()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        a.complete()
        rig.actions._drainForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testNameCapBucketsOverflowAndCountsDistinctDrops() {
        let rig = makeRig()
        for i in 0..<Actions.nameCap { rig.start("name-\(i)").complete() }
        rig.start("checkout-1").complete()
        rig.start("checkout-1").complete()
        rig.start("checkout-2").complete()
        rig.start("name-0").complete()  // already kept

        let started = rig.events("action.started")
        XCTAssertNil(started[Actions.nameCap - 1]["action.name.dropped"], "omitted when zero")
        let tail = Array(started.suffix(4))
        XCTAssertEqual(tail.map { $0["action.name"] },
                       [.string("_other"), .string("_other"), .string("_other"), .string("name-0")])
        XCTAssertEqual(tail.map { $0["action.name.dropped"] }, [.int(1), .int(1), .int(2), .int(2)])
        XCTAssertEqual(rig.events("action.ended").last?["action.name.dropped"], .int(2))
    }

    // MARK: Abandonment

    func testRotationAbandonsOnTheEndingSession() {
        let rig = makeRig()
        let checkout = rig.start("checkout")
        let endingSession = rig.recorder.currentSessionId
        rig.clock.advance(by: 31 * 60)
        rig.recorder.recordEvent(name: "navigation", attributes: [:])  // rotates

        let names = rig.sink.envelopes.flatMap(\.events).map(\.name)
        XCTAssertEqual(Array(names.prefix(3)), ["action.started", "action.ended", "session.finalized"])
        let ended = rig.events("action.ended")
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(ended[0]["action.outcome"], .string("abandoned"))
        XCTAssertEqual(ended[0]["action.abandon_reason"], .string("rotation"))
        XCTAssertEqual(ended[0]["session.id"], .string(endingSession))
        XCTAssertNil(rig.events("navigation").last?["action.id"])

        checkout.complete()
        XCTAssertEqual(rig.events("action.ended").count, 1, "already closed by rotation")
    }

    func testRotationDueAtCompletionWinsOverTheCompletion() {
        let rig = makeRig()
        let checkout = rig.start("checkout")
        rig.clock.advance(by: 31 * 60)  // resumed after a long suspend
        checkout.complete()

        let ended = rig.events("action.ended")
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(ended[0]["action.abandon_reason"], .string("rotation"),
                       "an action whose session ended cannot complete in the next one")
    }

    func testLeakGuardIsScheduledAtStart() {
        let rig = makeRig()
        _ = RumAction(name: "forgotten", recorder: rig.recorder, actions: rig.actions, live: true, ceiling: 0.05)
        let done = expectation(description: "timeout fired")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(rig.events("action.ended").first?["action.abandon_reason"], .string("timeout"))
    }

    func testProcessDeathReplayCarriesSidecarIdentityNotLiveRiders() {
        let rig = makeRig()
        rig.riders.enterScreen("LiveScreen")
        let prior: [[String: AttributeValue]] = [[
            "action.id": .string("action_1717234876000_0123456789abcdef"),
            "action.outcome": .string("abandoned"),
            "action.abandon_reason": .string("process_death")
        ]]
        EdgeRum.replayPriorActions(prior, sidecarContents: [
            "session.id": .string("session_1717234870002_ff009988aabbccdd_ios"),
            "device.id": .string("device_1717234876123_a1b2c3d4e5f60718_ios"),
            "action.id": .string("action_1717234876000_ffffffffffffffff"),
            "screen.name": .string("CrashTimeScreen")
        ], recorder: rig.recorder)

        let ended = rig.events("action.ended")
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(ended[0]["session.id"], .string("session_1717234870002_ff009988aabbccdd_ios"))
        XCTAssertEqual(ended[0]["action.id"], .string("action_1717234876000_0123456789abcdef"), "event keys win")
        XCTAssertEqual(ended[0]["screen.name"], .string("CrashTimeScreen"), "riders from the dead process")
    }

    func testTimeoutAbandonsOnce() {
        let rig = makeRig()
        let a = rig.start("checkout")
        a.expire()
        a.complete()
        let ended = rig.events("action.ended")
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(ended[0]["action.abandon_reason"], .string("timeout"))
    }

    // MARK: Handle contract

    func testSecondCallsAreNoOps() {
        let rig = makeRig()
        let a = rig.start("checkout")
        a.fail(reason: "card declined")
        a.complete()
        a.fail(reason: "again")
        let ended = rig.events("action.ended")
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(ended[0]["action.outcome"], .string("failed"))
        XCTAssertEqual(ended[0]["action.error_message"], .string("card declined"))
        XCTAssertEqual(ended[0]["action.background_count"], .int(0))
    }

    func testNotLiveHandleRecordsNothing() {
        let rig = makeRig()
        let a = RumAction(name: "checkout", recorder: rig.recorder, actions: rig.actions, live: false)
        a.complete()
        XCTAssertTrue(rig.events("action.started").isEmpty)
        XCTAssertTrue(rig.events("action.ended").isEmpty)
    }

    func testActionsFollowSessionSampling() {
        let rig = makeRig(sampleRate: 0.0)
        rig.start("checkout").complete()
        XCTAssertTrue(rig.events("action.started").isEmpty)
        XCTAssertTrue(rig.events("action.ended").isEmpty)
    }

    func testActionIdShape() {
        let rig = makeRig()
        rig.start("checkout").complete()
        guard case let .string(id)? = rig.events("action.started").first?["action.id"] else {
            return XCTFail("no action.id")
        }
        XCTAssertNotNil(id.range(of: #"^action_\d+_[0-9a-f]{16}$"#, options: .regularExpression))
    }
}
