// Tests/EdgeRumCrashTests/PLCrashIntegrationReplayTests.swift
//
// End-to-end test of the replay path: seed a fixture PLCR report and
// a sidecar file on disk, point a fresh `PLCrashIntegration` at the
// same base path, and assert exactly one `app.crash` event lands on a
// `RecordingProbe` carrying the *sidecar* session id (not the live
// one).
//
// Refs: PLAN-iOS.md §6.7, §F14/T14.3 ("Crash → relaunch → first
// batch contains `app.crash` with `crash.fatal = true` carrying the
// crashed session's `session.id`").
//

import XCTest
@testable import EdgeRumCrash
import EdgeRumCore

final class PLCrashIntegrationReplayTests: XCTestCase {

    // MARK: - Probe

    final class RecordingProbe: Recording, @unchecked Sendable {
        struct Call: Equatable {
            let name: String
            let attributes: [String: AttributeValue]
        }
        let lock = NSLock()
        private(set) var calls: [Call] = []

        let _clock: Clock = SystemClock()
        var clock: Clock { _clock }
        var isEnabled: Bool { true }
        var currentSessionId: String { "session_0_0000000000000000_ios" }
        var currentDeviceId: String { "device_0_0000000000000000_ios" }
        var debug: Bool { false }

        func configure(_ config: RecorderConfig) {}
        func start(apiKey: String, endpoint: URL, debug: Bool) {}
        func stop() {}
        func setEnabled(_ enabled: Bool) {}
        func setUser(_ user: RecorderUser) {}
        func recordPerformance(name: String, attributes: [String: AttributeValue]) {}

        func recordEvent(name: String, attributes: [String: AttributeValue]) {
            lock.lock(); calls.append(.init(name: name, attributes: attributes)); lock.unlock()
        }
    }

    // MARK: - Helpers

    private func makeTempBaseDirectory() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edgerum-crashtest-\(UUID().uuidString)",
                                   isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Tests

    func testNoPendingReportIsANoOp() throws {
        let baseDir = makeTempBaseDirectory()
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let probe = RecordingProbe()
        let sidecar = SessionSidecar(url: baseDir.appendingPathComponent("last-session.json"))
        PLCrashIntegration.replayIfNeeded(
            recorder: probe,
            sidecar: sidecar,
            config: PLCrashIntegrationConfig(basePath: baseDir.appendingPathComponent("plcr")),
            debug: false
        )
        XCTAssertTrue(probe.calls.isEmpty, "no pending report → no event")
    }

    func testReplayEmitsAppCrashWithSidecarIdentity() throws {
        guard let fixtureBytes = CrashFixtureGenerator.makeLiveReport() else {
            throw XCTSkip("PLCrashReporter unavailable on this slice")
        }
        let baseDir = makeTempBaseDirectory()
        defer { try? FileManager.default.removeItem(at: baseDir) }

        // 1) Place the fixture report where PLCR would have placed it
        //    after a real crash. PLCR's default crash-report filename
        //    layout sits under `<basePath>/<bundleID-or-fallback>/`.
        //    We use PLCR's own `crashReportPath` API to discover the
        //    exact location so the test stays robust against PLCR's
        //    internal layout changes.
        let plcrBase = baseDir.appendingPathComponent("plcr", isDirectory: true)
        try seedPendingCrashReport(fixtureBytes: fixtureBytes, basePath: plcrBase)

        // 2) Seed the sidecar with a crashed-session identity.
        let sidecarURL = baseDir.appendingPathComponent("last-session.json")
        let sidecar = SessionSidecar(url: sidecarURL)
        var bag = AttributeBag()
        bag.set("session.id", .string("session_1717234870002_ff009988aabbccdd_ios"))
        bag.set("session.start_time", .string("2026-06-14T10:25:00.002Z"))
        bag.set("session.sequence", .int(42))
        bag.set("device.id", .string("device_1717234876123_a1b2c3d4e5f60718_ios"))
        bag.set("user.id", .string("user_1717100000000_deadbeefcafef00d"))
        bag.set("sdk.version", .string("1.0.0"))
        bag.set("sdk.platform", .string("ios-native"))
        sidecar.write(snapshot: bag)

        // 3) Drive the replay path.
        let probe = RecordingProbe()
        PLCrashIntegration.replayIfNeeded(
            recorder: probe,
            sidecar: sidecar,
            config: PLCrashIntegrationConfig(basePath: plcrBase),
            debug: true
        )

        // 4) Assert exactly one app.crash with sidecar identity.
        XCTAssertEqual(probe.calls.count, 1, "replay must emit exactly one event")
        let call = try XCTUnwrap(probe.calls.first)
        XCTAssertEqual(call.name, "app.crash")
        XCTAssertEqual(call.attributes["cause"], .string("NativeCrash"))
        XCTAssertEqual(call.attributes["runtime"], .string("native"))
        XCTAssertEqual(call.attributes["crash.fatal"], .bool(true))
        XCTAssertEqual(
            call.attributes["session.id"],
            .string("session_1717234870002_ff009988aabbccdd_ios"),
            "event must carry the SIDE-CARED session id, not the live one"
        )
        XCTAssertEqual(
            call.attributes["device.id"],
            .string("device_1717234876123_a1b2c3d4e5f60718_ios")
        )
        XCTAssertEqual(call.attributes["session.sequence"], .int(42))
        XCTAssertEqual(call.attributes["user.id"],
                       .string("user_1717100000000_deadbeefcafef00d"))
    }

    func testReplayWithMissingSidecarFallsBackToLiveIdentity() throws {
        guard let fixtureBytes = CrashFixtureGenerator.makeLiveReport() else {
            throw XCTSkip("PLCrashReporter unavailable on this slice")
        }
        let baseDir = makeTempBaseDirectory()
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let plcrBase = baseDir.appendingPathComponent("plcr", isDirectory: true)
        try seedPendingCrashReport(fixtureBytes: fixtureBytes, basePath: plcrBase)

        // No sidecar file on disk → reader returns nil → replay falls
        // through using the live recorder identity (which the
        // PayloadBuilder will merge in at flush time). The event
        // attributes themselves should NOT carry a `session.id`
        // override.
        let sidecar = SessionSidecar(url: baseDir.appendingPathComponent("last-session.json"))
        let probe = RecordingProbe()
        PLCrashIntegration.replayIfNeeded(
            recorder: probe,
            sidecar: sidecar,
            config: PLCrashIntegrationConfig(basePath: plcrBase),
            debug: true
        )

        XCTAssertEqual(probe.calls.count, 1)
        let call = try XCTUnwrap(probe.calls.first)
        XCTAssertEqual(call.name, "app.crash")
        XCTAssertNil(call.attributes["session.id"],
                     "missing sidecar → no event-level session.id override")
    }

    func testPoisonReportPurgesAndEmitsNothing() throws {
        let baseDir = makeTempBaseDirectory()
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let plcrBase = baseDir.appendingPathComponent("plcr", isDirectory: true)
        try seedPendingCrashReport(
            fixtureBytes: Data("not a plcr report".utf8),
            basePath: plcrBase
        )

        let sidecar = SessionSidecar(url: baseDir.appendingPathComponent("last-session.json"))
        let probe = RecordingProbe()
        PLCrashIntegration.replayIfNeeded(
            recorder: probe,
            sidecar: sidecar,
            config: PLCrashIntegrationConfig(basePath: plcrBase),
            debug: true
        )
        XCTAssertTrue(probe.calls.isEmpty,
                      "unparseable report drops the event but does not crash the host")
    }

    // MARK: - Crash report seeding

    /// Place `fixtureBytes` where PLCrashReporter would have written a
    /// pending crash report after a real crash. Walks PLCR's own
    /// `crashReportPath` to discover the exact filename so the test
    /// stays decoupled from PLCR's internal layout.
    private func seedPendingCrashReport(
        fixtureBytes: Data,
        basePath: URL
    ) throws {
        // Use PLCR's path-discovery API by writing through a
        // production-shaped integration config + temporary reporter.
        // The internal helper below sits in the EdgeRumCrash target
        // (added as part of T14.3) and returns the canonical path.
        try FileManager.default.createDirectory(
            at: basePath,
            withIntermediateDirectories: true
        )
        let path = try XCTUnwrap(
            CrashFixtureGenerator.pendingReportPath(basePath: basePath),
            "PLCR did not report a crashReportPath"
        )
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fixtureBytes.write(to: url, options: .atomic)
    }
}
