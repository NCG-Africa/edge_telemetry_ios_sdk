import XCTest
@testable import EdgeRum
@testable import EdgeRumCore
#if canImport(UIKit)
import UIKit
#endif

/// Unit tests for `StorageContext` — F16/T16.4's background-refresh
/// capture.
///
/// Refs: PLAN-iOS.md §16.4 / F16 / T16.4; docs/data-flow.md §3.1, §3.2.
final class StorageContextTests: XCTestCase {

    // MARK: write(into:)

    func testWriteEmitsBackgroundRefreshWhenPresent() {
        var bag = AttributeBag()
        StorageContext(backgroundRefresh: "available").write(into: &bag)
        XCTAssertEqual(bag, ["app.background_refresh": .string("available")])
    }

    func testWriteOmitsKeysWhenNil() {
        let ctx = StorageContext()
        var bag = AttributeBag()
        ctx.write(into: &bag)
        XCTAssertTrue(bag.isEmpty)
    }

    // MARK: backgroundRefreshString mapping

    #if canImport(UIKit)
    func testBackgroundRefreshMappingAvailable() {
        XCTAssertEqual(StorageContext.backgroundRefreshString(.available), "available")
    }

    func testBackgroundRefreshMappingDenied() {
        XCTAssertEqual(StorageContext.backgroundRefreshString(.denied), "denied")
    }

    func testBackgroundRefreshMappingRestricted() {
        XCTAssertEqual(StorageContext.backgroundRefreshString(.restricted), "restricted")
    }
    #endif

    // MARK: snapshot()

    /// #254 / SDK-008: disk space never leaves the device (E174.1).
    func testSnapshotCarriesNoDiskSpace() {
        var bag = AttributeBag()
        StorageContext.snapshot().write(into: &bag)
        XCTAssertNil(bag["device.disk_free_mb"])
        XCTAssertNil(bag["device.disk_total_mb"])
    }
}
