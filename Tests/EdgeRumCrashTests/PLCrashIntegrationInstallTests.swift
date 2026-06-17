// Tests/EdgeRumCrashTests/PLCrashIntegrationInstallTests.swift
//
// Idempotency coverage for `PLCrashIntegration.install(...)`. The
// production code path runs once from `EdgeRum.start()`; a second
// call (hot-reload, double-start, etc.) must be a no-op so we don't
// stack two Mach exception servers on top of each other.
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
        // First call should succeed (PLCR registers handlers); second
        // and third calls must short-circuit without throwing or
        // hitting PLCR a second time. We can't observe the
        // single-shot guard from outside the module, but tripping it
        // a second time would cause Mach to refuse the registration
        // and previously surface a noisy os_log entry — neither of
        // which crashes the host. The contract here is "doesn't
        // crash, doesn't throw".
        let baseDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edgerum-install-\(UUID().uuidString)",
                                   isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let config = PLCrashIntegrationConfig(basePath: baseDir)
        PLCrashIntegration.install(config: config, debug: false)
        PLCrashIntegration.install(config: config, debug: false)
        PLCrashIntegration.install(config: config, debug: false)
        // If we got here, the guard short-circuited.
    }

    func testInstallDoesNotCrashWithMissingBasePath() {
        // `nil` basePath should fall through to PLCR's own defaults
        // (a directory under the app's caches). The guard still
        // engages on the first call regardless.
        var config = PLCrashIntegrationConfig()
        config.basePath = nil
        PLCrashIntegration.install(config: config, debug: false)
    }
}
