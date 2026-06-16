// EdgeRumVersionPlugin — SwiftPM build-tool plugin.
//
// Runs `Tools/gen-version.sh` before the EdgeRum target compiles,
// producing a Swift file with the SemVer string read from the repo-root
// `VERSION` file. The generated constant is consumed by
// `EdgeRum.sdkVersion`, which becomes the `sdk.version` attribute on
// every emitted event.
//
// Refs: PLAN-iOS.md §2.6, F1/T1.3 (issue #4).

import Foundation
import PackagePlugin

@main
struct EdgeRumVersionPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext,
                             target: Target) throws -> [Command] {
        // Plugin writes into a per-target work directory that SwiftPM
        // adds to the compiler inputs automatically.
        let outputDir = context.pluginWorkDirectoryURL
            .appendingPathComponent("Generated", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDir,
            withIntermediateDirectories: true
        )
        let outputFile = outputDir.appendingPathComponent("EdgeRumVersion.swift")
        let script = context.package.directoryURL
            .appendingPathComponent("Tools/gen-version.sh")

        return [
            .prebuildCommand(
                displayName: "Generating EdgeRumVersion.swift from VERSION",
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: [script.path, outputFile.path],
                outputFilesDirectory: outputDir
            )
        ]
    }
}
