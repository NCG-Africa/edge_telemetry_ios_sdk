// Tests/EdgeRumCrashTests/MainThreadStackSnapshotTests.swift
//
// Best-effort coverage for the Mach-based main-thread stack walker.
// The full path (suspend → thread_get_state → vm_read_overwrite chain
// walk → dladdr) is exercised on the macOS test runner; on
// architectures where `thread_get_state` is unavailable the test
// downgrades to a smoke check.
//
// Refs: PLAN-iOS.md §F15/T15.2; docs/decisions.md ADR-011.
//

import XCTest
@testable import EdgeRumCrash

final class MainThreadStackSnapshotTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MainThreadStackSnapshot._resetForTests()
    }

    override func tearDown() {
        MainThreadStackSnapshot._resetForTests()
        super.tearDown()
    }

    func testCaptureBeforeInstallReturnsEmpty() {
        // Before `installFromMainThread`, the cached port is
        // `MACH_PORT_NULL`; the helper must return [] cleanly.
        let frames = MainThreadStackSnapshot.capture()
        XCTAssertTrue(frames.isEmpty,
                      "capture without install must return [] (no port)")
    }

    func testCaptureFromMainThreadShortCircuitsToAvoidSelfDeadlock() {
        // Install from the main thread (we're already on it under
        // XCTest's default scheduler).
        let install = XCTestExpectation(description: "main install")
        DispatchQueue.main.async {
            MainThreadStackSnapshot.installFromMainThread()
            install.fulfill()
        }
        wait(for: [install], timeout: 2.0)

        // Capturing FROM the main thread would deadlock (suspend self,
        // never resume), so the helper short-circuits to `[]` instead.
        let mainCapture = XCTestExpectation(description: "main capture")
        DispatchQueue.main.async {
            XCTAssertTrue(MainThreadStackSnapshot.capture().isEmpty,
                          "main-thread capture must short-circuit")
            mainCapture.fulfill()
        }
        wait(for: [mainCapture], timeout: 2.0)
    }

    func testCaptureFromBackgroundThreadProducesFrames() {
        let install = XCTestExpectation(description: "main install")
        DispatchQueue.main.async {
            MainThreadStackSnapshot.installFromMainThread()
            install.fulfill()
        }
        wait(for: [install], timeout: 2.0)

        // Capture from a background thread. On modern Apple Silicon
        // (arm64) and Intel (x86_64), the Mach state read returns a
        // valid PC, so the result MUST include at least one frame.
        let captured = XCTestExpectation(description: "background capture")
        var frames: [String] = []
        DispatchQueue.global(qos: .userInitiated).async {
            frames = MainThreadStackSnapshot.capture()
            captured.fulfill()
        }
        wait(for: [captured], timeout: 5.0)

        XCTAssertFalse(frames.isEmpty,
                       "capture from background thread must yield ≥1 frame")
        // Best-effort symbolication — at least the PC line should be
        // present. Frames are ordered with PC first.
        XCTAssertTrue(frames.first!.contains("0x"),
                      "first frame should include a hex address")
    }

    func testStubFramesAreReturnedVerbatim() {
        // The test-only stub override lets `HangEventEncoder` /
        // `HangWatchdog` exercise the fallback placeholder path
        // without coaxing real Mach calls into failing.
        MainThreadStackSnapshot._installStubForTests([])
        XCTAssertTrue(MainThreadStackSnapshot.capture().isEmpty)

        MainThreadStackSnapshot._installStubForTests(["A", "B", "C"])
        XCTAssertEqual(MainThreadStackSnapshot.capture(), ["A", "B", "C"])
    }
}
