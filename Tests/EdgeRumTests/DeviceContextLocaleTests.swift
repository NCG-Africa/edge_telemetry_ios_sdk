import XCTest
@testable import EdgeRum
import EdgeRumCore

/// Unit tests for the F16/T16.5 locale + timezone fields added to
/// `DeviceContext`. Kept in a separate file from the broader
/// `ContextProviderTests` so the v1.0 device assertions there don't
/// pick up dependencies on the v1.0+ keys.
///
/// Refs: PLAN-iOS.md §16.4 / F16 / T16.5; docs/data-flow.md §3.2.
final class DeviceContextLocaleTests: XCTestCase {

    // MARK: write(into:)

    func testWriteEmitsLocaleTimezoneAndOffset() {
        let ctx = DeviceContext(
            locale: "en_KE",
            timezone: "Africa/Nairobi",
            timezoneOffsetMin: 180
        )
        var bag = AttributeBag()
        ctx.write(into: &bag)
        XCTAssertEqual(bag["device.locale"], .string("en_KE"))
        XCTAssertEqual(bag["device.timezone"], .string("Africa/Nairobi"))
        XCTAssertEqual(bag["device.timezone_offset_min"], .int(180))
    }

    func testWriteOmitsLocaleKeysWhenNil() {
        let ctx = DeviceContext()
        var bag = AttributeBag()
        ctx.write(into: &bag)
        XCTAssertNil(bag["device.locale"])
        XCTAssertNil(bag["device.timezone"])
        XCTAssertNil(bag["device.timezone_offset_min"])
    }

    // MARK: snapshot()

    func testSnapshotPopulatesLocaleAndTimezoneFromHost() {
        let ctx = DeviceContext.snapshot()
        XCTAssertEqual(ctx.locale, Locale.current.identifier)
        XCTAssertEqual(ctx.timezone, TimeZone.current.identifier)
        XCTAssertEqual(
            ctx.timezoneOffsetMin,
            TimeZone.current.secondsFromGMT() / 60
        )
    }

    /// Offset must be in the canonical −720…+840 minute range so the
    /// backend can store it as a small int.
    func testSnapshotTimezoneOffsetIsInValidMinuteRange() {
        let ctx = DeviceContext.snapshot()
        let offset = try? XCTUnwrap(ctx.timezoneOffsetMin)
        if let offset = offset {
            XCTAssertGreaterThanOrEqual(offset, -720)
            XCTAssertLessThanOrEqual(offset, 840)
        }
    }
}
