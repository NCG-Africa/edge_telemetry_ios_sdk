import XCTest

/// Static lint checks on `EdgeRum.podspec`. We don't exec
/// `pod lib lint` here (it needs CocoaPods, network, and a 30-second
/// build); that's a separate CI job. Instead we pin the contractual
/// invariants T1.4 promises so a hand-edit can't silently break them.
///
/// Refs: F1/T1.4 (issue #5), PLAN-iOS.md §2.4.
final class PodspecTests: XCTestCase {
    private var podspecSource: String!
    private var versionString: String!

    override func setUpWithError() throws {
        podspecSource = try String(contentsOf: try Self.locate("EdgeRum.podspec"), encoding: .utf8)
        versionString = try String(contentsOf: try Self.locate("VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testPodspecExists() {
        XCTAssertFalse(podspecSource.isEmpty)
    }

    func testReadsVersionFromVersionFile() {
        XCTAssertTrue(podspecSource.contains("File.read"),
                      "Podspec should source s.version from the repo-root VERSION file, not duplicate it.")
        XCTAssertTrue(podspecSource.contains("'VERSION'"),
                      "Podspec should reference 'VERSION' literally.")
        XCTAssertFalse(versionString.isEmpty)
    }

    func testIOSFloorMatchesPlan() {
        // T1.5's check-supported-ios.sh covers this dynamically; we
        // re-assert it here so the unit suite alone catches a drift.
        XCTAssertTrue(podspecSource.contains("s.ios.deployment_target = '14.0'"),
                      "iOS floor must stay at 14.0 — see PLAN-iOS.md §2.2 and ADR-001.")
    }

    func testDeclaresSwift5And6() {
        XCTAssertTrue(podspecSource.contains("'5.10'") && podspecSource.contains("'6.0'"),
                      "Both Swift 5.10 (consumer floor) and Swift 6.0 (build toolchain) must be advertised.")
    }

    func testDeclaresInternalSubspecs() {
        for sub in ["Internal-Core", "Internal-Capture", "Internal-Crash"] {
            XCTAssertTrue(podspecSource.contains("s.subspec '\(sub)'"),
                          "Missing subspec \(sub).")
        }
    }

    func testVendorsPLCrashReporter() {
        XCTAssertTrue(podspecSource.contains("Frameworks/CrashReporter.xcframework"),
                      "Internal-Crash must vendor the PLCrashReporter xcframework.")
    }

    func testShipsPrivacyManifestAsResourceBundle() {
        XCTAssertTrue(podspecSource.contains("resource_bundles"))
        XCTAssertTrue(podspecSource.contains("PrivacyInfo.xcprivacy"))
        XCTAssertTrue(podspecSource.contains("EdgeRumPrivacy"),
                      "Resource bundle name must match the SwiftPM convention so consumers see one PrivacyInfo bundle regardless of channel.")
    }

    // MARK: - Helpers

    private static func locate(_ filename: String, file: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "PodspecTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not locate \(filename) from \(file)"])
    }
}
