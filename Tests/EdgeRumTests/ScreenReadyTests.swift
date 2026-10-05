// Tests/EdgeRumTests/ScreenReadyTests.swift
//
// F37 / #224 — RUM coverage tranche 13 ("Host-gated readiness").
//
//   - a mark consumes the appear token: `screen_ready`, ms from appear
//   - first mark wins; a mark after navigation moved on is a no-op
//   - a marked screen left pending → `screen.ready_outcome = abandoned`
//   - hole on record: a screen's first appear, before its first mark,
//     is not judged
//
// Refs: docs/specs/rum-coverage-roadmap.md § Tranche 13; ADR-028.

import XCTest
@testable import EdgeRum
import EdgeRumCore

final class ScreenReadyTests: XCTestCase {

    private var clock: FixedClock!
    private var rows: [[String: AttributeValue]] = []
    private var riders: Riders!

    override func setUp() {
        super.setUp()
        clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876))
        rows = []
        riders = Riders(clock: clock) { [unowned self] in rows.append($0) }
    }

    private func advance(ms: Double) { clock.advance(by: ms / 1000) }

    func testMarkEmitsReadyMsFromAppear() {
        riders.enterScreen("Home")
        advance(ms: 420)
        XCTAssertTrue(riders.markScreenReady())
        XCTAssertEqual(rows, [[
            "screen.name": .string("Home"),
            "screen.ready_outcome": .string("ready"),
            "value": .double(420)
        ]])
    }

    func testSecondMarkIsNoOp() {
        riders.enterScreen("Home")
        riders.markScreenReady()
        XCTAssertFalse(riders.markScreenReady())
        XCTAssertEqual(rows.count, 1)
    }

    func testMarkAfterNavigationMovedOnIsNoOp() {
        riders.enterScreen("Sheet")
        riders.leaveScreen("Sheet")  // box restored to nothing pending
        XCTAssertFalse(riders.markScreenReady())
        XCTAssertTrue(rows.isEmpty)
    }

    func testUnmarkedScreenLeftPendingEmitsNothing() {
        riders.enterScreen("Home")
        riders.enterScreen("Detail")
        XCTAssertTrue(rows.isEmpty, "hole on record: first appear before first mark is not judged")
    }

    func testMarkedScreenSupersededPendingIsAbandoned() {
        riders.enterScreen("Home")
        riders.markScreenReady()
        riders.enterScreen("Detail")
        riders.enterScreen("Home")
        advance(ms: 90)
        riders.enterScreen("Detail")  // left Home before ready
        XCTAssertEqual(rows.last, [
            "screen.name": .string("Home"),
            "screen.ready_outcome": .string("abandoned"),
            "value": .double(90)
        ])
    }

    func testMarkedScreenDismissedPendingIsAbandoned() {
        riders.enterScreen("Home")
        riders.enterScreen("Sheet")
        riders.markScreenReady()
        riders.leaveScreen("Sheet")
        riders.enterScreen("Sheet")
        advance(ms: 30)
        riders.leaveScreen("Sheet")
        XCTAssertEqual(rows.last?["screen.ready_outcome"], .string("abandoned"))
        XCTAssertEqual(rows.last?["value"], .double(30))
        XCTAssertEqual(rows.count, 2)
    }

    func testSameScreenReappearKeepsOriginalAnchor() {
        riders.enterScreen("Home")
        advance(ms: 100)
        riders.enterScreen("Home")  // spurious SwiftUI re-fire
        advance(ms: 100)
        riders.markScreenReady()
        XCTAssertEqual(rows.first?["value"], .double(200))
    }

    // MARK: Wire

    func testRecorderAcceptsBothNewMetricNames() {
        XCTAssertTrue(Recorder.allowedMetricNames.isSuperset(of: ["screen_ready", "launch_interactive"]))
        XCTAssertEqual(Recorder.allowedMetricNames.count, 8)
    }
}

final class ReadinessAPITests: XCTestCase {

    private var probe: ProbeRecorder!
    private var previousRecorder: Recording!

    override func setUp() {
        super.setUp()
        probe = ProbeRecorder()
        previousRecorder = Recorder.installShared(probe)
        EdgeRum._resetStartedConfigForTesting()
        Riders.shared._resetForTesting()
    }

    override func tearDown() {
        Recorder.installShared(previousRecorder)
        EdgeRum._resetStartedConfigForTesting()
        Riders.shared._resetForTesting()
        super.tearDown()
    }

    private var perfs: [(String, [String: AttributeValue])] {
        probe.calls.compactMap {
            if case let .performance(name, attributes) = $0 { return (name, attributes) }
            return nil
        }
    }

    private func start() {
        EdgeRum.start(EdgeRumConfig(apiKey: "edge_dev_abc", endpoint: URL(string: "https://example.com")!))
    }

    func testMarkInteractiveFirstCallWins() {
        start()
        EdgeRum.markInteractive()
        EdgeRum.markInteractive()
        XCTAssertEqual(perfs.map(\.0), ["launch_interactive"])
        guard case let .double(ms)? = perfs.first?.1["value"] else { return XCTFail("no value") }
        XCTAssertGreaterThanOrEqual(ms, 0)
    }

    func testMarkInteractiveBeforeStartIsNoOpAndDoesNotConsume() {
        EdgeRum.markInteractive()
        XCTAssertTrue(probe.calls.isEmpty)
        start()
        EdgeRum.markInteractive()
        XCTAssertEqual(perfs.map(\.0), ["launch_interactive"])
    }

    func testMarkScreenReadyRoutesScreenReady() {
        start()
        EdgeRum.trackScreen("Checkout")
        EdgeRum.markScreenReady()
        EdgeRum.markScreenReady()
        XCTAssertEqual(perfs.map(\.0), ["screen_ready"])
        XCTAssertEqual(perfs.first?.1["screen.name"], .string("Checkout"))
    }

    func testMarkScreenReadyBeforeStartIsNoOp() {
        EdgeRum.markScreenReady()
        XCTAssertTrue(probe.calls.isEmpty)
    }
}
