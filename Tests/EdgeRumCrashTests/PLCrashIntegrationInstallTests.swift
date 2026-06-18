// Tests/EdgeRumCrashTests/PLCrashIntegrationInstallTests.swift
//
// Idempotency coverage for `PLCrashIntegration.install(...)`. The
// production code path runs once from `EdgeRum.start()`; a second
// call (hot-reload, double-start, etc.) must be a no-op so we don't
// stack two Mach exception servers on top of each other.
//
// These tests go through the internal `_install` seam with a stub
// enable closure rather than the public entry point. The real
// `enable` registers PLCrashReporter's Mach exception server +
// uncaught NSException handler in-process, which hangs the xctest
// runner on sandboxed/hardened-runtime macOS CI hosts and burned the
// full 6h GitHub Actions ceiling on the F18 run. The single-shot
// guard we actually care about lives in `_install`, not in the
// real `enable`, so a stub is the right level to test at.
//
// Refs: PLAN-iOS.md §F14/T14.1; CLAUDE.md "Touching swizzles?"
// checklist (install once on main thread, guard with Once token).
//

import XCTest
@testable import EdgeRumCrash

final class PLCrashIntegrationInstallTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PLCrashIntegration._resetForTests()
    }

    override func tearDown() {
        PLCrashIntegration._resetForTests()
        super.tearDown()
    }

    func testInstallIsIdempotent() {
        let baseDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edgerum-install-\(UUID().uuidString)",
                                   isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        var enableCount = 0
        let stub: (PLCrashIntegrationConfig, Bool) -> Void = { _, _ in
            enableCount += 1
        }

        let config = PLCrashIntegrationConfig(basePath: baseDir)
        PLCrashIntegration._install(config: config, debug: false, enable: stub)
        PLCrashIntegration._install(config: config, debug: false, enable: stub)
        PLCrashIntegration._install(config: config, debug: false, enable: stub)

        XCTAssertEqual(
            enableCount, 1,
            "single-shot guard must short-circuit subsequent install() calls"
        )
    }

    func testInstallDoesNotCrashWithMissingBasePath() {
        // `nil` basePath should fall through to PLCR's own defaults
        // (a directory under the app's caches). The guard still
        // engages on the first call regardless. We only assert
        // here that the guard accepts a nil-basePath config and
        // dispatches to enable exactly once.
        var config = PLCrashIntegrationConfig()
        config.basePath = nil

        var enableCount = 0
        PLCrashIntegration._install(config: config, debug: false) { _, _ in
            enableCount += 1
        }
        XCTAssertEqual(enableCount, 1)
    }
}
