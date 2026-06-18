// Tests/EdgeRumTests/TransportEnvironmentTests.swift
//
// F19 / T19.1 — small coverage filler for `TransportEnvironment`,
// which exists only to keep UIKit out of the EdgeRum umbrella module.
// `deviceModel()` and `osVersion()` are both pure functions with no
// side effects; the test confirms the macOS-host fallback values are
// stable so the `User-Agent` header has a meaningful identifier even
// when the SDK runs under `swift test`.
//
// Refs: PLAN-iOS.md §7.1, §13.1; F5/T5.1.
//

import XCTest
@testable import EdgeRumCore

final class TransportEnvironmentTests: XCTestCase {

    func testDeviceModelHasStableNonEmptyValue() {
        let model = TransportEnvironment.deviceModel()
        XCTAssertFalse(model.isEmpty, "deviceModel must never return an empty string")
        #if canImport(UIKit) && targetEnvironment(simulator)
        XCTAssertTrue(model.hasPrefix("iPhone") || model.hasPrefix("iPad") || model.hasPrefix("arm"),
                      "simulator deviceModel should look like a real iOS device id; got \(model)")
        #elseif !canImport(UIKit)
        XCTAssertEqual(model, "macOS-host",
                       "Non-iOS hosts get the documented fallback value for stable User-Agent")
        #endif
    }

    func testOsVersionLooksLikeSemver() {
        let version = TransportEnvironment.osVersion()
        XCTAssertFalse(version.isEmpty, "osVersion must never return an empty string")
        // Both branches produce dot-separated numbers — UIDevice's
        // `systemVersion` (e.g. "17.4.1") and ProcessInfo's
        // `operatingSystemVersionString` formatted manually below.
        XCTAssertTrue(version.contains("."), "osVersion should look semver-ish; got \(version)")
    }

    func testCalledRepeatedlyReturnsEqualValues() {
        XCTAssertEqual(TransportEnvironment.deviceModel(),
                       TransportEnvironment.deviceModel(),
                       "Same process snapshot — model must be deterministic")
        XCTAssertEqual(TransportEnvironment.osVersion(),
                       TransportEnvironment.osVersion(),
                       "Same process snapshot — osVersion must be deterministic")
    }
}
