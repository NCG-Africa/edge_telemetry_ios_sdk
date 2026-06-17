import XCTest
@testable import EdgeRum
@testable import EdgeRumCore
#if canImport(UIKit)
import UIKit
#endif

/// Unit tests for `StorageContext` — F16/T16.4's disk capacity +
/// background-refresh capture.
///
/// Refs: PLAN-iOS.md §16.4 / F16 / T16.4; docs/data-flow.md §3.1, §3.2.
final class StorageContextTests: XCTestCase {

    // MARK: write(into:)

    func testWriteEmitsAllThreeKeysWhenPresent() {
        let ctx = StorageContext(
            diskFreeMb: 10_000,
            diskTotalMb: 128_000,
            backgroundRefresh: "available"
        )
        var bag = AttributeBag()
        ctx.write(into: &bag)
        XCTAssertEqual(bag["device.disk_free_mb"], .int(10_000))
        XCTAssertEqual(bag["device.disk_total_mb"], .int(128_000))
        XCTAssertEqual(bag["app.background_refresh"], .string("available"))
        XCTAssertEqual(bag.count, 3)
    }

    func testWriteOmitsKeysWhenNil() {
        let ctx = StorageContext()
        var bag = AttributeBag()
        ctx.write(into: &bag)
        XCTAssertTrue(bag.isEmpty)
    }

    // MARK: readDiskMB

    func testReadDiskMBProducesPositiveValuesOnTestHost() throws {
        let (free, total) = StorageContext.readDiskMB()
        let f = try XCTUnwrap(free, "free disk must be readable on the test host")
        let t = try XCTUnwrap(total, "total disk must be readable on the test host")
        XCTAssertGreaterThan(f, 0)
        XCTAssertGreaterThan(t, 0)
        XCTAssertLessThanOrEqual(f, t)
    }

    /// PLAN-iOS.md §16.4 / T16.4 acceptance: free-disk MB must match
    /// `df -k` ±5%. We use `statvfs` (which `df` itself calls) so the
    /// only delta is the time-of-read drift between the two
    /// invocations; the 5% tolerance is generous on any realistic
    /// CI host.
    func testReadDiskMBMatchesStatfsWithinFivePercent() throws {
        // `statfs` is the cross-platform interface that both
        // `FileManager.attributesOfFileSystem` and the `df` CLI use.
        // We compare our snapshot to a direct `statfs` reading from
        // the same path so the test stays hermetic — no shell out.
        var fsStats = statfs()
        let result = statfs(NSHomeDirectory(), &fsStats)
        try XCTSkipUnless(result == 0, "statfs failed; skip")
        let blockSize = UInt64(fsStats.f_bsize)
        let freeBlocks = UInt64(fsStats.f_bavail)
        let referenceFreeMb = Int((blockSize * freeBlocks) / 1_048_576)

        let (free, _) = StorageContext.readDiskMB()
        let snapshotMb = try XCTUnwrap(free)

        let tolerance = max(Double(referenceFreeMb) * 0.05, 16.0)  // 16 MB floor
        let delta = abs(Double(snapshotMb - referenceFreeMb))
        XCTAssertLessThan(
            delta, tolerance,
            "Snapshot \(snapshotMb) MB drifted from statfs \(referenceFreeMb) MB by \(delta) MB (tolerance \(tolerance))"
        )
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

    func testSnapshotProducesPositiveDiskValues() {
        let ctx = StorageContext.snapshot()
        XCTAssertNotNil(ctx.diskFreeMb)
        XCTAssertNotNil(ctx.diskTotalMb)
        if let f = ctx.diskFreeMb { XCTAssertGreaterThan(f, 0) }
        if let t = ctx.diskTotalMb { XCTAssertGreaterThan(t, 0) }
    }
}
