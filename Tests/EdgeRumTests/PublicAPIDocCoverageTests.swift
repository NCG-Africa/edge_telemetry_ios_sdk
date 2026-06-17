// Tests/EdgeRumTests/PublicAPIDocCoverageTests.swift
//
// Behavioural test for `Tools/check-doc-coverage.sh`. The shell script
// shells out to `swift package dump-symbol-graph` and scans the
// resulting EdgeRum.symbols.json for any public symbol whose
// `docComment.lines` is missing or empty.
//
// We mirror the pattern in SupportedIOSScriptTests: locate the repo
// root, run the script against the live repo, and assert it succeeds
// today. Breakage from a missing `///` on a future PR shows up here
// as an XCTest failure before the CI doc job even runs.
//
// Refs: PLAN-iOS.md §12.5 (Doc-quality CI),
//       CLAUDE.md "Swift conventions" (doc comments on every public symbol).

import XCTest

final class PublicAPIDocCoverageTests: XCTestCase {

    func testEveryPublicSymbolHasADocComment() throws {
        // The script requires a live SwiftPM checkout with the
        // PLCrashReporter binary available. CI machines run
        // `Tools/fetch-plcrashreporter.sh` ahead of the test job; on
        // a developer machine the same script needs to have run at
        // least once. If it hasn't, skip rather than fail — the doc
        // contract is still enforced by CI on every PR.
        let repoRoot = try Self.locateRepoRoot()
        let plcr = repoRoot.appendingPathComponent("Frameworks/CrashReporter.xcframework")
        guard FileManager.default.fileExists(atPath: plcr.path) else {
            throw XCTSkip("CrashReporter.xcframework not present — run Tools/fetch-plcrashreporter.sh once.")
        }

        let script = repoRoot.appendingPathComponent("Tools/check-doc-coverage.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw XCTSkip("check-doc-coverage.sh not found — wrong checkout layout?")
        }

        let result = try Self.runScript(at: script, repoRoot: repoRoot)
        XCTAssertEqual(
            result.exitCode, 0,
            """
            check-doc-coverage.sh failed.
            stdout:
            \(result.stdout)
            stderr:
            \(result.stderr)
            """
        )
    }

    // MARK: - Test plumbing

    private static func runScript(at script: URL, repoRoot: URL) throws
        -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.currentDirectoryURL = repoRoot
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["REPO_ROOT": repoRoot.path]
        ) { _, new in new }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, out, err)
    }

    private static func locateRepoRoot(file: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<10 {
            let pkg = dir.appendingPathComponent("Package.swift")
            let plan = dir.appendingPathComponent("PLAN-iOS.md")
            let script = dir.appendingPathComponent("Tools/check-doc-coverage.sh")
            if [pkg, plan, script].allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(
            domain: "PublicAPIDocCoverageTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate repo root from \(file)"]
        )
    }
}
