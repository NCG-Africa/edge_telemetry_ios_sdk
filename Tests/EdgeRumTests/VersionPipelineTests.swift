import XCTest
@testable import EdgeRum

/// Locks down the SemVer pipeline: `VERSION` file → `Tools/gen-version.sh`
/// → `EdgeRumVersionPlugin` → `EdgeRumGeneratedVersion.string` →
/// `EdgeRum.sdkVersion`. Any break in that chain fails this target.
///
/// F1/T1.3 acceptance: "Runtime `sdk.version` attribute matches `VERSION`
/// file at build time."
final class VersionPipelineTests: XCTestCase {
    func testSDKVersionIsNonEmpty() {
        XCTAssertFalse(EdgeRum.sdkVersion.isEmpty,
                       "sdkVersion must never be empty — it becomes the sdk.version attribute on every event.")
    }

    /// `EdgeRum.sdkVersion` must match the SemVer string in `VERSION`
    /// at the repo root. The `VERSION` file is located by walking up
    /// from the test bundle until we find the package directory.
    func testSDKVersionMatchesVersionFile() throws {
        let versionFromFile = try Self.readRepoVersionFile()
        XCTAssertEqual(EdgeRum.sdkVersion, versionFromFile,
                       "sdkVersion must equal the SemVer string in the repo-root VERSION file.")
    }

    func testSDKVersionIsValidSemVer() {
        let pattern = #"^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$"#
        XCTAssertNotNil(EdgeRum.sdkVersion.range(of: pattern, options: .regularExpression),
                        "sdkVersion '\(EdgeRum.sdkVersion)' is not valid SemVer 2.0.")
    }

    // MARK: - Helpers

    private static func readRepoVersionFile() throws -> String {
        let url = try locateRepoRoot().appendingPathComponent("VERSION")
        let raw = try String(contentsOf: url, encoding: .utf8)
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Walk up from the current source file until a directory containing
    /// both `Package.swift` and `VERSION` is found. This is robust whether
    /// tests run from `swift test`, Xcode, or CI.
    private static func locateRepoRoot(file: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<10 {
            let pkg = dir.appendingPathComponent("Package.swift")
            let ver = dir.appendingPathComponent("VERSION")
            if fm.fileExists(atPath: pkg.path) && fm.fileExists(atPath: ver.path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "VersionPipelineTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not locate repo root from \(file)"])
    }
}
