// Tests/EdgeRumTests/ScreenReadyTests.swift
//
// F37 / #224 — RUM coverage tranche 13 ("Host-gated readiness").
//
//   - a mark consumes the appear token: `screen.load`, settled ms from appear
//   - first mark wins; a mark after navigation moved on is a no-op
//   - a marked screen left pending → `screen.load.outcome = abandoned`
//   - hole on record: a screen's first appear, before its first mark,
//     is not judged
//
// Refs: docs/specs/rum-coverage-roadmap.md § Tranche 13; ADR-028.

import XCTest
@testable import EdgeRum
import EdgeRumCore
import EdgeRumCapture

final class ScreenReadyTests: XCTestCase {

    private var clock: FixedClock!
    private var rows: [[String: AttributeValue]] = []
    private var riders: Riders!

    override func setUp() {
        super.setUp()
        clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876))
        rows = []
        riders = Riders(clock: clock, emitReady: { [unowned self] in rows.append($0) }, emitVisit: { _ in })
    }

    private func advance(ms: Double) { clock.advance(by: ms / 1000) }

    func testMarkEmitsReadyMsFromAppear() {
        riders.enterScreen("Home")
        advance(ms: 420)
        XCTAssertTrue(riders.markScreenReady())
        XCTAssertEqual(rows, [[
            "screen.name": .string("Home"),
            "screen.load.outcome": .string("settled"),
            "screen.load.settled_ms": .int(420),
            "screen.load.source": .string("reported")
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
        riders.disappearScreen("Sheet")
        riders.leaveScreen("Sheet")
        XCTAssertFalse(riders.markScreenReady())
        XCTAssertTrue(rows.isEmpty)
    }

    func testUnmarkedScreenLeftPendingEmitsNothing() {
        riders.enterScreen("Home")
        riders.enterScreen("Detail")
        XCTAssertTrue(rows.isEmpty, "hole on record: first appear before first mark is not judged")
    }

    func testMarkedScreenDisappearedPendingIsAbandoned() {
        riders.enterScreen("Home")
        riders.markScreenReady()
        riders.disappearScreen("Home")
        riders.enterScreen("Detail")
        riders.disappearScreen("Detail")
        riders.enterScreen("Home")
        advance(ms: 90)
        riders.disappearScreen("Home")  // left Home before ready
        riders.enterScreen("Detail")
        XCTAssertEqual(rows.last, [
            "screen.name": .string("Home"),
            "screen.load.outcome": .string("abandoned"),
            "screen.load.settled_ms": .int(90),
            "screen.load.source": .string("reported")
        ])
        XCTAssertEqual(rows.count, 2)
    }

    func testSheetOverPendingMarkedScreenIsNotAbandoned() {
        riders.enterScreen("Home")
        riders.markScreenReady()
        riders.disappearScreen("Home")
        riders.enterScreen("Home")
        riders.enterScreen("Sheet")  // pageSheet: Home never disappears
        XCTAssertEqual(rows.count, 1, "supersede is not abandon")
    }

    func testMarkedScreenDismissedPendingIsAbandoned() {
        riders.enterScreen("Home")
        riders.enterScreen("Sheet")
        riders.markScreenReady()
        riders.disappearScreen("Sheet")
        riders.leaveScreen("Sheet")
        riders.enterScreen("Sheet")
        advance(ms: 30)
        riders.disappearScreen("Sheet")
        riders.leaveScreen("Sheet")
        XCTAssertEqual(rows.last?["screen.load.outcome"], .string("abandoned"))
        XCTAssertEqual(rows.last?["screen.load.settled_ms"], .int(30))
        XCTAssertEqual(rows.count, 2)
    }

    func testSameScreenReappearKeepsOriginalAnchor() {
        riders.enterScreen("Home")
        advance(ms: 100)
        riders.enterScreen("Home")  // spurious SwiftUI re-fire
        advance(ms: 100)
        riders.markScreenReady()
        XCTAssertEqual(rows.first?["screen.load.settled_ms"], .int(200))
    }

    // MARK: Wire

    func testRecorderAcceptsTheReadinessNames() {
        XCTAssertTrue(Recorder.allowedEventNames.contains("screen.load"))
        XCTAssertTrue(Recorder.allowedMetricNames.contains("perf.launch_interactive"))
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
        let before = PageLoadCapture.elapsedMs(fromNs: PageLoadCapture.launchStartNs, toNs: PageLoadCapture.monotonicNs())
        EdgeRum.markInteractive()
        EdgeRum.markInteractive()
        let after = PageLoadCapture.elapsedMs(fromNs: PageLoadCapture.launchStartNs, toNs: PageLoadCapture.monotonicNs())
        XCTAssertEqual(perfs.map(\.0), ["perf.launch_interactive"])
        guard case let .double(ms)? = perfs.first?.1["value"], let before, let after else { return XCTFail("no value") }
        // Anchored at `launchStart`, the `page_load` anchor.
        XCTAssertTrue(Double(before)...Double(after) ~= ms)
    }

    func testMarkInteractiveBeforeStartIsNoOpAndDoesNotConsume() {
        EdgeRum.markInteractive()
        XCTAssertTrue(probe.calls.isEmpty)
        start()
        EdgeRum.markInteractive()
        XCTAssertEqual(perfs.map(\.0), ["perf.launch_interactive"])
    }

    func testMarkScreenReadyRoutesScreenReady() {
        start()
        EdgeRum.trackScreen("Checkout")
        EdgeRum.markScreenReady()
        EdgeRum.markScreenReady()
        let loads = probe.calls.compactMap { call -> [String: AttributeValue]? in
            if case let .event(name, attributes) = call, name == "screen.load" { return attributes }
            return nil
        }
        XCTAssertEqual(loads.count, 1)
        XCTAssertEqual(loads.first?["screen.name"], .string("Checkout"))
    }

    func testMarkScreenReadyBeforeStartIsNoOp() {
        EdgeRum.markScreenReady()
        XCTAssertTrue(probe.calls.isEmpty)
    }
}
