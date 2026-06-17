import XCTest
@testable import EdgeRum
@testable import EdgeRumCore

/// Unit tests for the F16 `ContextObservers` installer.
///
/// `ContextObservers.install(provider:debug:)` must be:
///   - idempotent (second call is a no-op)
///   - seed every F16 context on install so the first event after
///     install carries the new attributes
///   - teardown-clean for tests (no live timers / observers after
///     `_resetInstallFlagForTesting`)
///
/// We cannot easily fire system notifications from a unit test, but
/// we can drive the install path and verify the seeded snapshots
/// land in the provider's bag.
///
/// Refs: PLAN-iOS.md §16.4 / F16.
final class ContextObserversTests: XCTestCase {

    private func makeProvider() -> ContextProvider {
        ContextProvider(
            app: AppContext(),
            device: DeviceContext(),
            deviceIdentity: DeviceIdentitySnapshot(id: "device_1_aa_ios"),
            network: NetworkContext(),
            session: SessionContextSnapshot(id: "s", startTime: Date(timeIntervalSince1970: 0), sequence: 0),
            user: UserContextSnapshot(id: "u"),
            sdk: SdkContext(version: "1.0.0")
        )
    }

    override func setUp() {
        super.setUp()
        #if DEBUG
        ContextObservers._resetInstallFlagForTesting()
        #endif
    }

    override func tearDown() {
        #if DEBUG
        ContextObservers._resetInstallFlagForTesting()
        #endif
        super.tearDown()
    }

    func testInstallIsIdempotent() {
        let p = makeProvider()
        XCTAssertFalse(ContextObservers.isInstalled)
        ContextObservers.install(provider: p)
        XCTAssertTrue(ContextObservers.isInstalled)
        // Second call must be a no-op (would otherwise crash the
        // dispatch source by resuming an already-running timer).
        ContextObservers.install(provider: p)
        XCTAssertTrue(ContextObservers.isInstalled)
    }

    func testInstallSeedsPowerAccessibilityAndStorage() {
        let p = makeProvider()
        // Pre-install: nothing populated.
        let preBag = p.snapshot()
        XCTAssertNil(preBag["device.thermal_state"])
        XCTAssertNil(preBag["device.disk_total_mb"])

        ContextObservers.install(provider: p)

        let bag = p.snapshot()
        // Power should always seed thermal state on iOS/macOS.
        XCTAssertNotNil(bag["device.thermal_state"])
        // Storage seeded — at least total disk should resolve on the
        // test host.
        XCTAssertNotNil(bag["device.disk_total_mb"])
    }

    #if DEBUG
    func testResetClearsInstallFlag() {
        let p = makeProvider()
        ContextObservers.install(provider: p)
        XCTAssertTrue(ContextObservers.isInstalled)
        ContextObservers._resetInstallFlagForTesting()
        XCTAssertFalse(ContextObservers.isInstalled)
        // Re-installable after reset.
        ContextObservers.install(provider: p)
        XCTAssertTrue(ContextObservers.isInstalled)
    }
    #endif

    func testStorageRefreshIntervalIsFiveMinutes() {
        // The PLAN-iOS.md §16.4 / T16.4 acceptance pins this at 5 min.
        // Reading the constant directly catches accidental drift.
        XCTAssertEqual(ContextObservers.storageRefreshInterval, .seconds(300))
    }
}
