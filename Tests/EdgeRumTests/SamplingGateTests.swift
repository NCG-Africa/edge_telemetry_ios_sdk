// Tests/EdgeRumTests/SamplingGateTests.swift
//
// F30 / #217 — open ⇔ active ∧ ¬low power ∧ thermal < serious.

import XCTest
@testable import EdgeRumCore

final class SamplingGateTests: XCTestCase {

    private let cool = PowerContext(thermalState: "nominal", lowPowerMode: false)

    func test_open_whenActiveCoolAndNotLowPower() {
        XCTAssertTrue(SamplingGate.isOpen(appState: "active", power: cool))
        XCTAssertTrue(SamplingGate.isOpen(
            appState: "active", power: PowerContext(thermalState: "fair", lowPowerMode: nil)))
    }

    func test_closed_whenNotActive() {
        for state in ["inactive", "background", nil] as [String?] {
            XCTAssertFalse(SamplingGate.isOpen(appState: state, power: cool), "\(state ?? "nil")")
        }
    }

    func test_closed_onLowPower() {
        XCTAssertFalse(SamplingGate.isOpen(
            appState: "active", power: PowerContext(thermalState: "nominal", lowPowerMode: true)))
    }

    func test_closed_atSeriousThermalAndAbove() {
        for thermal in ["serious", "critical"] {
            XCTAssertFalse(SamplingGate.isOpen(
                appState: "active", power: PowerContext(thermalState: thermal, lowPowerMode: false)))
        }
    }

    func test_live_readsAppStateRider() {
        defer { Riders.shared._resetForTesting() }
        Riders.shared.setAppState("background")
        XCTAssertFalse(SamplingGate.isOpen())
    }
}
