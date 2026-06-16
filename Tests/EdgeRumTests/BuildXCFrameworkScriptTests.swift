import XCTest

/// Lightweight contract tests for `Tools/build-xcframework.sh`. We do
/// NOT exec the script (full archive takes ~1 min per slice and needs
/// the framework dependency on disk). Instead we lint the script for
/// the contractual invariants T1.2 promises:
///
///   - archives the three required slices
///   - bundles `PrivacyInfo.xcprivacy` into every slice (flat layout for
///     iOS / iOS Simulator, versioned layout for Mac Catalyst)
///   - signs with `--options=runtime` when `$CODESIGN_IDENTITY` is set
///   - produces a `.xcframework.zip` at `build/` and reports its size
///
/// The full end-to-end build is exercised manually pre-merge and in CI.
///
/// Refs: F1/T1.2 (issue #3), PLAN-iOS.md §2.5.
final class BuildXCFrameworkScriptTests: XCTestCase {
    private var scriptSource: String!

    override func setUpWithError() throws {
        let url = try Self.locateScript()
        scriptSource = try String(contentsOf: url, encoding: .utf8)
    }

    func testArchivesAllThreeRequiredSlices() {
        XCTAssertTrue(scriptSource.contains("generic/platform=iOS"),
                      "Must archive an iphoneos slice.")
        XCTAssertTrue(scriptSource.contains("generic/platform=iOS Simulator"),
                      "Must archive an iphonesimulator slice.")
        XCTAssertTrue(scriptSource.contains("variant=Mac Catalyst"),
                      "Must archive a maccatalyst slice (or skip via SKIP_CATALYST).")
    }

    func testUsesDistributionBuildFlags() {
        // PLAN-iOS.md §2.5 mandates these for an ABI-stable XCFramework.
        XCTAssertTrue(scriptSource.contains("BUILD_LIBRARIES_FOR_DISTRIBUTION=YES"))
        XCTAssertTrue(scriptSource.contains("SKIP_INSTALL=NO"))
    }

    func testInvokesCreateXcframework() {
        XCTAssertTrue(scriptSource.contains("-create-xcframework"))
    }

    func testCopiesPrivacyManifestPerSlice() {
        XCTAssertTrue(scriptSource.contains("PrivacyInfo.xcprivacy"),
                      "Must reference the PrivacyInfo manifest.")
        XCTAssertTrue(scriptSource.contains("Versions/A/Resources"),
                      "Versioned bundle (Mac Catalyst) needs the Resources path variant.")
    }

    func testCodesignUsesHardenedRuntimeWhenIdentitySet() {
        XCTAssertTrue(scriptSource.contains("--options=runtime"),
                      "codesign must request the hardened runtime.")
        XCTAssertTrue(scriptSource.contains("CODESIGN_IDENTITY"),
                      "codesign step must be opt-in via $CODESIGN_IDENTITY.")
    }

    func testProducesZippedOutput() {
        XCTAssertTrue(scriptSource.contains("EdgeRum.xcframework.zip"),
                      "Final output path is EdgeRum.xcframework.zip.")
        XCTAssertTrue(scriptSource.contains("ditto -c -k"),
                      "Use `ditto` so the produced zip is byte-identical to Finder zips.")
    }

    func testAutoFetchesPLCrashReporter() {
        XCTAssertTrue(scriptSource.contains("fetch-plcrashreporter.sh"),
                      "Must invoke fetch-plcrashreporter.sh so the binary target resolves before archive.")
    }

    func testSetsErrExitMode() {
        XCTAssertTrue(scriptSource.contains("set -euo pipefail"),
                      "Shell scripts in Tools/ all run under strict mode.")
    }

    // MARK: - Helpers

    private static func locateScript(file: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("Tools/build-xcframework.sh")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "BuildXCFrameworkScriptTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not locate Tools/build-xcframework.sh from \(file)"])
    }
}
