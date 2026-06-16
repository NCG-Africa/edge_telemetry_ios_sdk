import XCTest

/// Behavioural tests for `Tools/check-supported-ios.sh`. We shadow-copy
/// the real `Package.swift` / `PLAN-iOS.md` / `EdgeRum.podspec` /
/// `README.md` into a tmpdir, mutate one of them, and assert the script
/// agrees / disagrees as expected.
///
/// Refs: F1/T1.5 (issue #6), PLAN-iOS.md §12.5.
final class SupportedIOSScriptTests: XCTestCase {

    func testPassesWhenAllSourcesAgree() throws {
        let sandbox = try Self.makeSandbox()
        defer { sandbox.cleanup() }

        let result = try sandbox.runScript()
        XCTAssertEqual(result.exitCode, 0,
                       "Script should succeed on the unmodified repo snapshot.\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)")
    }

    func testFailsWhenPackageSwiftDrifts() throws {
        let sandbox = try Self.makeSandbox()
        defer { sandbox.cleanup() }

        try sandbox.mutate(file: "Package.swift",
                           replacing: ".iOS(.v14)",
                           with: ".iOS(.v15)")

        let result = try sandbox.runScript()
        XCTAssertNotEqual(result.exitCode, 0,
                          "Script must flag a Package.swift / PLAN-iOS.md mismatch.\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)")
        XCTAssertTrue(result.stderr.contains("PLAN-iOS.md"),
                      "Error should name the drifted source.\n\(result.stderr)")
    }

    func testFailsWhenPlanDrifts() throws {
        let sandbox = try Self.makeSandbox()
        defer { sandbox.cleanup() }

        try sandbox.mutate(file: "PLAN-iOS.md",
                           replacing: "**Minimum**: **iOS 14.0**",
                           with: "**Minimum**: **iOS 16.0**")

        let result = try sandbox.runScript()
        XCTAssertNotEqual(result.exitCode, 0,
                          "Script must flag a PLAN-iOS.md drift.")
    }

    func testFailsWhenPodspecDrifts() throws {
        let sandbox = try Self.makeSandbox()
        defer { sandbox.cleanup() }

        // Drop a tiny podspec stub into the sandbox so the script picks it up.
        let stub = """
        Pod::Spec.new do |s|
          s.name = 'EdgeRum'
          s.ios.deployment_target = '15.0'
        end
        """
        try sandbox.writeFile("EdgeRum.podspec", contents: stub)

        let result = try sandbox.runScript()
        XCTAssertNotEqual(result.exitCode, 0,
                          "Script must flag a podspec / Package.swift mismatch.")
        XCTAssertTrue(result.stderr.contains("podspec"),
                      "Error should name the podspec.\n\(result.stderr)")
    }

    func testSkipsReadmeWhenAbsent() throws {
        let sandbox = try Self.makeSandbox()
        defer { sandbox.cleanup() }

        // No README written into the sandbox.
        let result = try sandbox.runScript()
        XCTAssertEqual(result.exitCode, 0,
                       "Missing README must not break the audit during F1 (README ships with F18).")
    }

    func testReportsMissingPackageSwift() throws {
        let sandbox = try Self.makeSandbox()
        defer { sandbox.cleanup() }

        try FileManager.default.removeItem(at: sandbox.root.appendingPathComponent("Package.swift"))

        let result = try sandbox.runScript()
        XCTAssertNotEqual(result.exitCode, 0)
    }

    // MARK: - Sandbox

    private struct Sandbox {
        let root: URL
        let scriptCopy: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }

        func runScript() throws -> (exitCode: Int32, stdout: String, stderr: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptCopy.path]
            // Force the script's REPO_ROOT detection at the sandbox dir.
            process.environment = ProcessInfo.processInfo.environment.merging(
                ["REPO_ROOT": root.path]
            ) { _, new in new }

            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            try process.run()
            process.waitUntilExit()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (process.terminationStatus, out, err)
        }

        func mutate(file: String, replacing needle: String, with replacement: String) throws {
            let url = root.appendingPathComponent(file)
            let contents = try String(contentsOf: url, encoding: .utf8)
            guard contents.contains(needle) else {
                throw NSError(domain: "Sandbox", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "expected '\(needle)' in \(file)"])
            }
            let mutated = contents.replacingOccurrences(of: needle, with: replacement)
            try mutated.write(to: url, atomically: true, encoding: .utf8)
        }

        func writeFile(_ name: String, contents: String) throws {
            try contents.write(to: root.appendingPathComponent(name),
                               atomically: true, encoding: .utf8)
        }
    }

    private static func makeSandbox() throws -> Sandbox {
        let realRoot = try locateRepoRoot()
        let sandboxRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edgerum-supios-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxRoot, withIntermediateDirectories: true)

        for name in ["Package.swift", "PLAN-iOS.md"] {
            try FileManager.default.copyItem(
                at: realRoot.appendingPathComponent(name),
                to: sandboxRoot.appendingPathComponent(name)
            )
        }

        let toolsDir = sandboxRoot.appendingPathComponent("Tools", isDirectory: true)
        try FileManager.default.createDirectory(at: toolsDir, withIntermediateDirectories: true)
        let scriptDest = toolsDir.appendingPathComponent("check-supported-ios.sh")
        try FileManager.default.copyItem(
            at: realRoot.appendingPathComponent("Tools/check-supported-ios.sh"),
            to: scriptDest
        )

        return Sandbox(root: sandboxRoot, scriptCopy: scriptDest)
    }

    private static func locateRepoRoot(file: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<10 {
            let pkg = dir.appendingPathComponent("Package.swift")
            let plan = dir.appendingPathComponent("PLAN-iOS.md")
            let script = dir.appendingPathComponent("Tools/check-supported-ios.sh")
            if [pkg, plan, script].allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "SupportedIOSScriptTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not locate repo root from \(file)"])
    }
}
