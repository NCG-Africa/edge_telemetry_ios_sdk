import XCTest

/// Behavioural tests for `Tools/firewall-check.sh`.
///
/// We point the script at a tmpdir prepared to mimic the parts of the
/// repo the script actually inspects (`Sources/EdgeRum/`, `README.md`,
/// `docs/`). The script doesn't need a real Swift build to exercise
/// its source-pre-check and markdown steps, so the symbol-graph step
/// short-circuits with a warning when no `.build/` is present —
/// the source/README/docs grep paths still run and we assert on those.
///
/// macOS-host only — `Foundation.Process` is not available on iOS.
/// The script under test is a macOS-only build helper.
///
/// Refs: PLAN-iOS.md §F2/T2.7, CLAUDE.md Rule 1.
#if os(macOS)
final class FirewallCheckScriptTests: XCTestCase {

    func testCleanSandboxPasses() throws {
        let sandbox = try Self.makeSandbox(seed: .clean)
        defer { sandbox.cleanup() }

        let result = try sandbox.runScript()
        XCTAssertEqual(result.exitCode, 0,
                       "Clean sandbox must pass.\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)")
    }

    func testDocCommentLeakFailsTheScript() throws {
        let sandbox = try Self.makeSandbox(seed: .clean)
        defer { sandbox.cleanup() }

        let file = sandbox.root.appendingPathComponent("Sources/EdgeRum/Leaky.swift")
        try """
        /// This file accidentally mentions a tracer in its doc comment.
        public enum Leaky {}
        """.write(to: file, atomically: true, encoding: .utf8)

        let result = try sandbox.runScript()
        XCTAssertNotEqual(result.exitCode, 0, "Doc-comment leak should fail.")
        XCTAssertTrue(result.stderr.contains("tracer"),
                      "stderr should call out the banned term.\n\(result.stderr)")
    }

    func testReadmeLeakFailsTheScript() throws {
        let sandbox = try Self.makeSandbox(seed: .clean)
        defer { sandbox.cleanup() }

        try """
        # EdgeRum

        Internally, EdgeRum uses an OpenTelemetry span exporter.
        """.write(
            to: sandbox.root.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let result = try sandbox.runScript()
        XCTAssertNotEqual(result.exitCode, 0, "README leak should fail.")
        XCTAssertTrue(
            result.stderr.contains("README.md"),
            "stderr should reference README.md.\n\(result.stderr)"
        )
    }

    func testConsumerDocsLeakFailsTheScript() throws {
        let sandbox = try Self.makeSandbox(seed: .clean)
        defer { sandbox.cleanup() }

        let doc = sandbox.root.appendingPathComponent("docs/integration.md")
        try "Pass your tracer to the integration step.".write(
            to: doc, atomically: true, encoding: .utf8
        )

        let result = try sandbox.runScript()
        XCTAssertNotEqual(result.exitCode, 0,
                          "Leak in a consumer-facing doc should fail.")
    }

    func testInternalDocsAreSkipped() throws {
        let sandbox = try Self.makeSandbox(seed: .clean)
        defer { sandbox.cleanup() }

        // data-flow.md is on the INTERNAL_DOCS allowlist — banned
        // terms here are intentional and should NOT fail the script.
        try """
        # data-flow

        Internally we use OpenTelemetry's span/trace primitives.
        """.write(
            to: sandbox.root.appendingPathComponent("docs/data-flow.md"),
            atomically: true,
            encoding: .utf8
        )

        let result = try sandbox.runScript()
        XCTAssertEqual(result.exitCode, 0,
                       "docs/data-flow.md must be skipped.\nstderr:\n\(result.stderr)")
    }

    // MARK: - Sandbox

    private enum Seed { case clean }

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
    }

    private static func makeSandbox(seed: Seed) throws -> Sandbox {
        let realRoot = try locateRepoRoot()
        let sandboxRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edgerum-firewall-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: sandboxRoot, withIntermediateDirectories: true)

        // Tools/firewall-check.sh — the script under test.
        let toolsDir = sandboxRoot.appendingPathComponent("Tools", isDirectory: true)
        try fm.createDirectory(at: toolsDir, withIntermediateDirectories: true)
        let scriptDest = toolsDir.appendingPathComponent("firewall-check.sh")
        try fm.copyItem(
            at: realRoot.appendingPathComponent("Tools/firewall-check.sh"),
            to: scriptDest
        )

        // Sources/EdgeRum/ — non-empty so the source-pre-check has
        // something to inspect. A single clean file lives here.
        let sourcesDir = sandboxRoot.appendingPathComponent("Sources/EdgeRum", isDirectory: true)
        try fm.createDirectory(at: sourcesDir, withIntermediateDirectories: true)
        try """
        /// Clean public surface placeholder.
        public enum SandboxedSurface {}
        """.write(
            to: sourcesDir.appendingPathComponent("Sandboxed.swift"),
            atomically: true,
            encoding: .utf8
        )

        // Empty docs/ directory so the script's docs-walk step has a
        // target. Tests that need files in docs/ add them themselves.
        try fm.createDirectory(
            at: sandboxRoot.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )

        // Empty Package.swift so any `swift package` invocation by
        // the script fails predictably (we expect it to fall back to
        // the source-only path in this sandbox).
        try "// placeholder".write(
            to: sandboxRoot.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        _ = seed
        return Sandbox(root: sandboxRoot, scriptCopy: scriptDest)
    }

    private static func locateRepoRoot(file: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<10 {
            let script = dir.appendingPathComponent("Tools/firewall-check.sh")
            if FileManager.default.fileExists(atPath: script.path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(
            domain: "FirewallCheckScriptTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate repo root from \(file)"]
        )
    }
}
#endif
