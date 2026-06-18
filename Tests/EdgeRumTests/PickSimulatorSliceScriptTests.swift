// Tests/EdgeRumTests/PickSimulatorSliceScriptTests.swift
//
// Behavioural tests for `Tools/pick-simulator-slice.sh`. The script
// reads `xcrun simctl list devices available -j` on the runner; we
// can't easily mock simctl from a unit test, so we exercise the
// negative paths and assert the argument-handling contract holds.
// The happy path is exercised on every CI run by the `test-device-
// matrix` job (PLAN-iOS.md §13.7).
//
// Refs: F19/T19.6.

import XCTest

final class PickSimulatorSliceScriptTests: XCTestCase {

    func testRejectsMissingSlot() throws {
        let result = try runScript(args: [])
        XCTAssertNotEqual(result.exitCode, 0,
                          "missing --slot must exit non-zero")
        XCTAssertTrue(result.stderr.contains("missing --slot"),
                      "error message should mention the missing flag; got:\n\(result.stderr)")
    }

    func testRejectsUnknownSlot() throws {
        let result = try runScript(args: ["--slot", "ancient"])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(
            result.stderr.contains("unknown slot 'ancient'"),
            "error message should call out the unknown slot; got:\n\(result.stderr)"
        )
    }

    func testHelpPrintsUsageAndExitsZero() throws {
        let result = try runScript(args: ["--help"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Usage:"),
                      "help output should mention usage; got:\n\(result.stdout)")
        XCTAssertTrue(result.stdout.contains("--slot"),
                      "help output should mention --slot")
    }

    func testPicksADestinationForEachSlotOnThisHost() throws {
        // Smoke test the actual runner-side path. On a Mac with at
        // least one iOS Simulator runtime, the script should print
        // a `platform=iOS Simulator,id=…` string per slot.
        for slot in ["min", "mid", "new"] {
            let result = try runScript(args: ["--slot", slot,
                                              "--print-destination",
                                              "--allow-any-device"])
            // The script logs a warning to stderr when fewer than
            // three runtimes are installed (common on developer
            // machines). Exit code is still 0 when at least one
            // runtime exists.
            XCTAssertEqual(
                result.exitCode, 0,
                "pick-simulator-slice should succeed for slot \(slot) when at least one runtime is installed.\nstderr:\n\(result.stderr)"
            )
            XCTAssertTrue(
                result.stdout.contains("platform=iOS Simulator,id="),
                "stdout should contain a destination string for slot \(slot); got:\n\(result.stdout)"
            )
        }
    }

    // MARK: - Helpers

    struct Result { let exitCode: Int32; let stdout: String; let stderr: String }

    private func runScript(args: [String]) throws -> Result {
        let repoRoot = Self.discoverRepoRoot()
        let url = repoRoot.appendingPathComponent("Tools/pick-simulator-slice.sh")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [url.path] + args

        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr

        try task.run()
        task.waitUntilExit()

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        return Result(exitCode: task.terminationStatus, stdout: out, stderr: err)
    }

    private static func discoverRepoRoot(file: StaticString = #filePath) -> URL {
        let here = URL(fileURLWithPath: "\(file)")
        return here
            .deletingLastPathComponent()  // Tests/EdgeRumTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }
}
