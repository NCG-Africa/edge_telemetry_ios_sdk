// Tests/EdgeRumCrashTests/HangDetectorInstallTests.swift
//
// Idempotency + teardown coverage for `HangDetector.install/uninstall`.
// The production code path runs once from `EdgeRum.start()`; a second
// call (hot-reload, double-start) must be a no-op so the watchdog
// thread isn't stacked. `uninstall()` must drop the observer + cancel
// the thread so `EdgeRum.disable()` leaves no live timers.
//
// Refs: PLAN-iOS.md §F15/T15.1; CLAUDE.md "Touching swizzles?"
//       checklist (install once on main; idempotent).
//

import XCTest
@testable import EdgeRumCrash
import EdgeRumCore

final class HangDetectorInstallTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HangDetector._resetForTests()
    }

    override func tearDown() {
        HangDetector._resetForTests()
        super.tearDown()
    }

    func testInstallIsIdempotent() {
        let probe = HangProbeRecorder()

        HangDetector._install(
            threshold: 2.0,
            debug: false,
            recorder: probe,
            clock: SystemClock(),
            stackProvider: { ["test-frame"] },
            cpuProvider: { nil }
        )
        let firstWatchdog = HangDetector._activeWatchdog()
        XCTAssertNotNil(firstWatchdog, "first install must set up a watchdog")

        HangDetector._install(
            threshold: 5.0,
            debug: true,
            recorder: HangProbeRecorder(),
            clock: SystemClock(),
            stackProvider: { ["should-not-be-used"] },
            cpuProvider: { 0.99 }
        )
        let secondWatchdog = HangDetector._activeWatchdog()
        XCTAssertTrue(
            firstWatchdog === secondWatchdog,
            "second install must short-circuit; same watchdog instance survives"
        )
    }

    func testUninstallCancelsWatchdogAndDropsObserver() {
        let probe = HangProbeRecorder()
        HangDetector._install(
            threshold: 2.0,
            debug: false,
            recorder: probe,
            clock: SystemClock(),
            stackProvider: { [] },
            cpuProvider: { nil }
        )

        // The observer install hops to the main thread asynchronously
        // when invoked off-main; sync to main to drain the hop.
        let expectation = XCTestExpectation(description: "main runloop drained")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2.0)

        HangDetector.uninstall()

        XCTAssertNil(HangDetector._activeWatchdog(),
                     "uninstall must clear the watchdog reference")
        XCTAssertFalse(HangDetector._hasObserver(),
                       "uninstall must drop the runloop observer")
    }

    func testHostHangTimeoutBelowFloorIsClampedToTwoSeconds() {
        let probe = HangProbeRecorder()
        // Sub-2s thresholds must be clamped to the 2.0s floor per
        // PLAN-iOS.md §17 risk #5 (false-positive guard for older
        // iPhone 8 / SE 2 hardware).
        HangDetector._install(
            threshold: 0.5,
            debug: false,
            recorder: probe,
            clock: SystemClock(),
            stackProvider: { [] },
            cpuProvider: { nil }
        )
        let watchdog = HangDetector._activeWatchdog()
        XCTAssertEqual(watchdog?.threshold, 2.0,
                       "threshold must be clamped to the 2s floor")
    }

    func testInstallFromBackgroundThreadDispatchesToMain() {
        let probe = HangProbeRecorder()
        let expectation = XCTestExpectation(description: "install completes off-main")
        DispatchQueue.global(qos: .userInitiated).async {
            HangDetector._install(
                threshold: 2.0,
                debug: false,
                recorder: probe,
                clock: SystemClock(),
                stackProvider: { [] },
                cpuProvider: { nil }
            )
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        // The runloop observer attaches via DispatchQueue.main.async.
        // Drain main so the test observes the attached state.
        let drain = XCTestExpectation(description: "main runloop drained")
        DispatchQueue.main.async { drain.fulfill() }
        wait(for: [drain], timeout: 2.0)

        XCTAssertNotNil(HangDetector._activeWatchdog())
        XCTAssertTrue(HangDetector._hasObserver())
    }
}

// MARK: - Probe shared with HangDetector detection tests

internal final class HangProbeRecorder: Recording, @unchecked Sendable {

    struct Call: Equatable {
        let name: String
        let attributes: [String: AttributeValue]
    }

    let lock = NSLock()
    private(set) var calls: [Call] = []

    func resetCalls() {
        lock.lock(); calls.removeAll(); lock.unlock()
    }

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
