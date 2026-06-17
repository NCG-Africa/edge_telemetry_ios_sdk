import XCTest
@testable import EdgeRum
@testable import EdgeRumCore

/// Unit tests for `PowerContext` — F16/T16.1's thermal state +
/// low-power-mode capture.
///
/// Refs: PLAN-iOS.md §16.4 / F16 / T16.1; docs/data-flow.md §3.2.
final class PowerContextTests: XCTestCase {

    // MARK: write(into:)

    func testWriteEmitsBothKeysWhenPresent() {
        let ctx = PowerContext(thermalState: "fair", lowPowerMode: true)
        var bag = AttributeBag()
        ctx.write(into: &bag)
        XCTAssertEqual(bag["device.thermal_state"], .string("fair"))
        XCTAssertEqual(bag["device.low_power_mode"], .bool(true))
        XCTAssertEqual(bag.count, 2)
    }

    func testWriteOmitsBothKeysWhenNil() {
        let ctx = PowerContext()
        var bag = AttributeBag()
        ctx.write(into: &bag)
        XCTAssertNil(bag["device.thermal_state"])
        XCTAssertNil(bag["device.low_power_mode"])
        XCTAssertEqual(bag.count, 0)
    }

    func testWriteEmitsOnlyThermalWhenLowPowerNil() {
        let ctx = PowerContext(thermalState: "critical", lowPowerMode: nil)
        var bag = AttributeBag()
        ctx.write(into: &bag)
        XCTAssertEqual(bag["device.thermal_state"], .string("critical"))
        XCTAssertNil(bag["device.low_power_mode"])
    }

    // MARK: thermalStateString mapping

    func testThermalStateMappingNominal() {
        XCTAssertEqual(PowerContext.thermalStateString(.nominal), "nominal")
    }

    func testThermalStateMappingFair() {
        XCTAssertEqual(PowerContext.thermalStateString(.fair), "fair")
    }

    func testThermalStateMappingSerious() {
        XCTAssertEqual(PowerContext.thermalStateString(.serious), "serious")
    }

    func testThermalStateMappingCritical() {
        XCTAssertEqual(PowerContext.thermalStateString(.critical), "critical")
    }

    // MARK: snapshot()

    func testSnapshotPopulatesThermalState() {
        let ctx = PowerContext.snapshot()
        XCTAssertNotNil(ctx.thermalState)
        // The host process is almost certainly nominal under XCTest,
        // but we accept any of the four documented values to avoid
        // CI flakes if a runner happens to be hot.
        let allowed: Set<String> = ["nominal", "fair", "serious", "critical"]
        XCTAssertTrue(allowed.contains(ctx.thermalState ?? ""),
                      "thermal_state must be one of \(allowed), got \(String(describing: ctx.thermalState))")
    }

    func testSnapshotProducesBoolForLowPowerOnAvailablePlatforms() {
        let ctx = PowerContext.snapshot()
        // On iOS / macOS 12+ we expect a bool; pre-macOS-12 builds may
        // surface nil. We allow either to keep the suite green on the
        // package's macOS 11 floor while still asserting "Bool when
        // present" on iOS.
        #if os(iOS)
        XCTAssertNotNil(ctx.lowPowerMode)
        #else
        if #available(macOS 12.0, *) {
            XCTAssertNotNil(ctx.lowPowerMode)
        }
        #endif
    }
}
