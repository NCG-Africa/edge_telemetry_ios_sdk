import XCTest

/// Script-level tests for `Tools/gen-version.sh` — the generator behind
/// `EdgeRumVersionPlugin`. These tests exec the script in a sandbox
/// directory so they cannot affect the real repo state.
///
/// macOS-host only — `Foundation.Process` is not available on iOS.
/// The script under test is a build-time helper executed by SwiftPM
/// on the developer's Mac, not the device.
///
/// Refs: F1/T1.3 (issue #4).
#if os(macOS)
final class GenVersionScriptTests: XCTestCase {

    func testGeneratesSwiftFileFromValidVersion() throws {
        let sandbox = try Self.makeSandbox(version: "2.3.4")
        defer { sandbox.cleanup() }

        let result = try sandbox.runScript()
        XCTAssertEqual(result.exitCode, 0,
                       "gen-version.sh should exit 0 on a valid SemVer. stderr:\n\(result.stderr)")

        let generated = try String(contentsOf: sandbox.outputFile, encoding: .utf8)
        XCTAssertTrue(generated.contains("internal enum EdgeRumGeneratedVersion"))
        XCTAssertTrue(generated.contains("\"2.3.4\""),
                      "Generated file should embed the SemVer string verbatim.\n\(generated)")
    }

    func testIsIdempotent() throws {
        let sandbox = try Self.makeSandbox(version: "1.0.0")
        defer { sandbox.cleanup() }

        XCTAssertEqual(try sandbox.runScript().exitCode, 0)
        let firstWrite = try FileManager.default.attributesOfItem(atPath: sandbox.outputFile.path)[.modificationDate] as! Date

        // Re-run; mtime must NOT advance because content is unchanged.
        Thread.sleep(forTimeInterval: 1.1)
        XCTAssertEqual(try sandbox.runScript().exitCode, 0)
        let secondWrite = try FileManager.default.attributesOfItem(atPath: sandbox.outputFile.path)[.modificationDate] as! Date

        XCTAssertEqual(firstWrite, secondWrite,
                       "Second run with unchanged VERSION must be a no-op to preserve SwiftPM's incremental build cache.")
    }

    func testRejectsInvalidSemVer() throws {
        let sandbox = try Self.makeSandbox(version: "not-a-version")
        defer { sandbox.cleanup() }

        let result = try sandbox.runScript()
        XCTAssertNotEqual(result.exitCode, 0,
                          "gen-version.sh must reject non-SemVer strings.")
        XCTAssertTrue(result.stderr.contains("SemVer"),
                      "Error message should mention SemVer. Got: \(result.stderr)")
    }

    func testRejectsEmptyVersion() throws {
        let sandbox = try Self.makeSandbox(version: "")
        defer { sandbox.cleanup() }

        let result = try sandbox.runScript()
        XCTAssertNotEqual(result.exitCode, 0)
    }

    func testAcceptsPrereleaseSuffix() throws {
        let sandbox = try Self.makeSandbox(version: "1.0.0-alpha.7")
        defer { sandbox.cleanup() }

        let result = try sandbox.runScript()
        XCTAssertEqual(result.exitCode, 0, "Pre-release suffixes are valid SemVer 2.0.\n\(result.stderr)")
        let generated = try String(contentsOf: sandbox.outputFile, encoding: .utf8)
        XCTAssertTrue(generated.contains("\"1.0.0-alpha.7\""))
    }

    // MARK: - Sandbox helpers

    private struct Sandbox {
        let root: URL
        let scriptCopy: URL
        let outputFile: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }

        func runScript() throws -> (exitCode: Int32, stdout: String, stderr: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptCopy.path, outputFile.path]

            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            try process.run()
            process.waitUntilExit()

            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (process.terminationStatus, out, err)
        }
    }

    private static func makeSandbox(version: String) throws -> Sandbox {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edgerum-genver-\(UUID().uuidString)", isDirectory: true)

        let tools = root.appendingPathComponent("Tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)

        // Copy the real gen-version.sh into the sandbox and a sibling VERSION
        // file. Because the script resolves VERSION via its own parent dir,
        // both must travel together.
        let realScript = try locateRealScript()
        let scriptCopy = tools.appendingPathComponent("gen-version.sh")
        try FileManager.default.copyItem(at: realScript, to: scriptCopy)

        try version.write(to: root.appendingPathComponent("VERSION"),
                          atomically: true, encoding: .utf8)

        let outputFile = root.appendingPathComponent("EdgeRumVersion.swift")
        return Sandbox(root: root, scriptCopy: scriptCopy, outputFile: outputFile)
    }

    private static func locateRealScript(file: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("Tools/gen-version.sh")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "GenVersionScriptTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not locate Tools/gen-version.sh from \(file)"])
    }
}
#endif
