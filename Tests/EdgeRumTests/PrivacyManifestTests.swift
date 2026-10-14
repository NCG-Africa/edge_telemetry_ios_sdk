// Tests/EdgeRumTests/PrivacyManifestTests.swift
//
// #254 / SDK-008 — the shipped privacy manifest declares what the code
// does. Disk space and boot timestamps are deliberately absent: no
// required reason lets either leave the device.

import XCTest

final class PrivacyManifestTests: XCTestCase {

    private func manifest() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/EdgeRum/Resources/PrivacyInfo.xcprivacy")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    func testAccessedAPIReasons() throws {
        let types = try XCTUnwrap(manifest()["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: [String]] = [:]
        for t in types {
            reasons[try XCTUnwrap(t["NSPrivacyAccessedAPIType"] as? String)] = t["NSPrivacyAccessedAPITypeReasons"] as? [String]
        }
        XCTAssertEqual(reasons, [
            "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
            "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"]
        ])
    }

    func testCollectedDataTypesAreLinkedAndNotTracking() throws {
        let m = try manifest()
        XCTAssertEqual(m["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((m["NSPrivacyTrackingDomains"] as? [String])?.isEmpty, true)
        let types = try XCTUnwrap(m["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let names = Set(types.compactMap { ($0["NSPrivacyCollectedDataType"] as? String)?
            .replacingOccurrences(of: "NSPrivacyCollectedDataType", with: "") })
        XCTAssertEqual(names, ["DeviceID", "UserID", "CrashData", "PerformanceData", "OtherDiagnosticData",
                               "ProductInteraction", "Name", "EmailAddress", "PhoneNumber"])
        for t in types {
            XCTAssertEqual(t["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
            XCTAssertEqual(t["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
            XCTAssertEqual(t["NSPrivacyCollectedDataTypePurposes"] as? [String], [
                "NSPrivacyCollectedDataTypePurposeAnalytics",
                "NSPrivacyCollectedDataTypePurposeAppFunctionality"
            ])
        }
    }
}
