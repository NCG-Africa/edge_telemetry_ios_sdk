// Sources/EdgeRumCrash/CrashFixtureGenerator.swift
//
// Internal helper that wraps PLCrashReporter's
// `generateLiveReport()` so the unit test target can drive the
// encoder end-to-end without importing the `@_implementationOnly`
// `CrashReporter` module directly.
//
// `generateLiveReport()` snapshots the current thread / process /
// binary state and produces a PLCR report blob WITHOUT installing
// any signal handlers. That makes it safe to call from arbitrary
// test code (`enableCrashReporter` would conflict with the host test
// runner's own crash handling).
//
// Refs: PLAN-iOS.md §F14/T14.1.
//

import Foundation
#if canImport(CrashReporter)
@_implementationOnly import CrashReporter
#endif

internal enum CrashFixtureGenerator {

    /// Produce a fresh PLCR report for the current process. Returns
    /// `nil` on platforms where the framework isn't available or if
    /// PLCR refuses the request. Test-only; the production replay
    /// path reads pre-existing on-disk reports instead.
    internal static func makeLiveReport() -> Data? {
        #if canImport(CrashReporter)
        guard let reporter = PLCrashReporter(
            configuration: PLCrashReporterConfig.defaultConfiguration()
        ) else { return nil }
        return reporter.generateLiveReport()
        #else
        return nil
        #endif
    }

    /// Discover the path PLCrashReporter would use to persist a
    /// pending crash report given a base directory. Used by replay
    /// tests to seed a fixture report where the production code
    /// path would look for it.
    internal static func pendingReportPath(basePath: URL) -> String? {
        #if canImport(CrashReporter)
        let config = PLCrashReporterConfig(
            signalHandlerType: .mach,
            symbolicationStrategy: .all,
            shouldRegisterUncaughtExceptionHandler: true,
            basePath: basePath.path,
            maxReportBytes: 256 * 1024
        )
        guard let reporter = PLCrashReporter(configuration: config) else { return nil }
        return reporter.crashReportPath()
        #else
        _ = basePath
        return nil
        #endif
    }
}
