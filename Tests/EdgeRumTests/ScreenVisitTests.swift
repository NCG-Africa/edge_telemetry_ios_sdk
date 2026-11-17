// Tests/EdgeRumTests/ScreenVisitTests.swift
//
// #264 — the catalogue's navigation / screen model (processor #31):
// every screen entry is a `navigation` with `navigation.to_screen`,
// `navigation.from_screen` and `navigation.method`; leaving a screen for
// another one sends that visit as `screen.duration`.

import XCTest
import EdgeRumCore

final class ScreenVisitTests: XCTestCase {

    private var clock: FixedClock!
    private var visits: [[String: AttributeValue]] = []
    private var riders: Riders!

    override func setUp() {
        super.setUp()
        clock = FixedClock(Date(timeIntervalSince1970: 1_767_225_600))  // 2026-01-01T00:00:00Z
        visits = []
        riders = Riders(clock: clock, emitReady: { _ in }, emitVisit: { [unowned self] in visits.append($0) })
    }

    func testFirstScreenIsInitialWithNoFromScreen() {
        let edge = riders.navigate(to: "Home", method: "push")
        XCTAssertEqual(edge, [
            "navigation.to_screen": .string("Home"),
            "navigation.method": .string("initial")
        ])
        XCTAssertTrue(visits.isEmpty)
    }

    func testNextScreenEndsTheVisitWithTheTransitionMethod() {
        riders.navigate(to: "Home", method: "push")
        clock.advance(by: 1.5)
        let edge = riders.navigate(to: "Detail", method: "push")
        XCTAssertEqual(edge, [
            "navigation.to_screen": .string("Detail"),
            "navigation.from_screen": .string("Home"),
            "navigation.method": .string("push")
        ])
        XCTAssertEqual(visits, [[
            "screen.name": .string("Home"),
            "screen.duration_ms": .int(1_500),
            "screen.exit_method": .string("push"),
            "span.start_time": .string("2026-01-01T00:00:00.000Z")
        ]])
    }

    func testRefiredAppearOfTheSameScreenKeepsTheVisitOpen() {
        riders.navigate(to: "Home", method: "push")
        clock.advance(by: 1)
        riders.navigate(to: "Home", method: "unknown")
        clock.advance(by: 1)
        riders.navigate(to: "Detail", method: "push")
        XCTAssertEqual(visits.count, 1)
        XCTAssertEqual(visits.first?["screen.duration_ms"], .int(2_000))
    }

    func testUnknownMethodPassesThrough() {
        riders.navigate(to: "Home", method: "push")
        let edge = riders.navigate(to: "Settings", method: "unknown")
        XCTAssertEqual(edge["navigation.method"], .string("unknown"))
        XCTAssertEqual(visits.first?["screen.exit_method"], .string("unknown"))
    }
}
