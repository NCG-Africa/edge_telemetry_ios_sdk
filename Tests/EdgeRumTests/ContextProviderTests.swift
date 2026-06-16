import XCTest
@testable import EdgeRum
import EdgeRumCore

/// Unit tests for `ContextProvider` — the seam that snapshots all six
/// identity-attribute groups into the merged bag the `Recorder` adds
/// to every event.
///
/// Refs: PLAN-iOS.md §7.5, §F3/T3.3.
final class ContextProviderTests: XCTestCase {

    private func makeProvider() -> ContextProvider {
        ContextProvider(
            app: AppContext(name: "Shop", packageName: "com.example.shop", version: "2.1.0", buildNumber: "412", environment: "production"),
            device: DeviceContext(platformVersion: "17.4.1", model: "iPhone15,3", isVirtual: false, screenWidth: 1290, screenHeight: 2796, pixelRatio: 3.0),
            deviceIdentity: DeviceIdentitySnapshot(id: "device_1_aaaaaaaaaaaaaaaa_ios"),
            network: NetworkContext(type: .wifi, effectiveType: "wifi"),
            session: SessionContextSnapshot(id: "session_1_bbbbbbbbbbbbbbbb_ios", startTime: Date(timeIntervalSince1970: 1), sequence: 0),
            user: UserContextSnapshot(id: "user_1_cccccccccccccccc"),
            sdk: SdkContext(version: "1.0.0")
        )
    }

    // MARK: Snapshot contents

    func testSnapshotIncludesAllSixIdentityGroups() {
        let p = makeProvider()
        let bag = p.snapshot()
        // app.*
        XCTAssertEqual(bag["app.name"], .string("Shop"))
        XCTAssertEqual(bag["app.package_name"], .string("com.example.shop"))
        XCTAssertEqual(bag["app.version"], .string("2.1.0"))
        XCTAssertEqual(bag["app.build_number"], .string("412"))
        XCTAssertEqual(bag["app.environment"], .string("production"))
        // device.*
        XCTAssertEqual(bag["device.platform"], .string("ios"))
        XCTAssertEqual(bag["device.manufacturer"], .string("Apple"))
        XCTAssertEqual(bag["device.os"], .string("ios"))
        XCTAssertEqual(bag["device.platform_version"], .string("17.4.1"))
        XCTAssertEqual(bag["device.model"], .string("iPhone15,3"))
        XCTAssertEqual(bag["device.isVirtual"], .bool(false))
        XCTAssertEqual(bag["device.screenWidth"], .int(1290))
        XCTAssertEqual(bag["device.screenHeight"], .int(2796))
        XCTAssertEqual(bag["device.pixelRatio"], .double(3.0))
        XCTAssertEqual(bag["device.id"], .string("device_1_aaaaaaaaaaaaaaaa_ios"))
        // network.*
        XCTAssertEqual(bag["network.type"], .string("wifi"))
        XCTAssertEqual(bag["network.effectiveType"], .string("wifi"))
        // session.*
        XCTAssertEqual(bag["session.id"], .string("session_1_bbbbbbbbbbbbbbbb_ios"))
        XCTAssertEqual(bag["session.sequence"], .int(0))
        XCTAssertNotNil(bag["session.start_time"])
        // user.*
        XCTAssertEqual(bag["user.id"], .string("user_1_cccccccccccccccc"))
        // sdk.*
        XCTAssertEqual(bag["sdk.version"], .string("1.0.0"))
        XCTAssertEqual(bag["sdk.platform"], .string("ios-native"))
    }

    func testUnsetOptionalAttributesAreOmitted() {
        let p = ContextProvider(
            app: AppContext(),
            device: DeviceContext(),
            deviceIdentity: DeviceIdentitySnapshot(id: "device_1_00_ios"),
            network: NetworkContext(),
            session: SessionContextSnapshot(id: "s", startTime: Date(timeIntervalSince1970: 0), sequence: 0),
            user: UserContextSnapshot(id: "u"),
            sdk: SdkContext(version: "0.0.0")
        )
        let bag = p.snapshot()
        XCTAssertNil(bag["app.name"])
        XCTAssertNil(bag["app.version"])
        XCTAssertNil(bag["device.batteryLevel"])
    }

    // MARK: Refresh hooks

    func testSetUserUpdatesOptionalFieldsButKeepsId() {
        let p = makeProvider()
        p.setUser(RecorderUser(id: "external-123", name: "Asha", email: "a@b.c", phone: nil))
        let bag = p.snapshot()
        XCTAssertEqual(bag["user.id"], .string("user_1_cccccccccccccccc"),
                       "SDK-owned user.id must not change on identify()")
        XCTAssertEqual(bag["user.name"], .string("Asha"))
        XCTAssertEqual(bag["user.email"], .string("a@b.c"))
        XCTAssertNil(bag["user.phone"])
    }

    func testRefreshNetworkReplacesNetworkKeys() {
        let p = makeProvider()
        p.refreshNetwork(NetworkContext(type: .cellular, effectiveType: "cellular"))
        let bag = p.snapshot()
        XCTAssertEqual(bag["network.type"], .string("cellular"))
        XCTAssertEqual(bag["network.effectiveType"], .string("cellular"))
    }

    func testRefreshSessionReplacesSessionKeys() {
        let p = makeProvider()
        let newSession = SessionContextSnapshot(
            id: "session_2_dddddddddddddddd_ios",
            startTime: Date(timeIntervalSince1970: 2_000_000),
            sequence: 42
        )
        p.refreshSession(newSession)
        let bag = p.snapshot()
        XCTAssertEqual(bag["session.id"], .string("session_2_dddddddddddddddd_ios"))
        XCTAssertEqual(bag["session.sequence"], .int(42))
    }

    // MARK: Bundle.main / UIDevice parity (issue #38 acceptance)

    func testAppContextSnapshotReadsBundleMain() {
        // Bundle.main during XCTest is the test runner; its
        // bundleIdentifier should still be non-nil even if
        // CFBundleName is missing. We assert the snapshot doesn't
        // crash and gracefully tolerates missing keys.
        let ctx = AppContext.snapshot()
        // Either the bundle identifier is present, or both are nil —
        // neither case throws.
        if let pkg = ctx.packageName {
            XCTAssertFalse(pkg.isEmpty)
        }
    }

    func testDeviceContextSnapshotPopulatesConstantIdentity() {
        let ctx = DeviceContext.snapshot()
        XCTAssertEqual(ctx.platform, "ios")
        XCTAssertEqual(ctx.manufacturer, "Apple")
        XCTAssertEqual(ctx.os, "ios")
    }
}
