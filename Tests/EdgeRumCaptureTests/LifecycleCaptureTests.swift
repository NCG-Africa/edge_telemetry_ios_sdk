// Tests/EdgeRumCaptureTests/LifecycleCaptureTests.swift
//
// F11 / T11.1 unit tests. Covers:
//
//   - makeAttributes: lifecycle.state / lifecycle.previous_state
//     primitives-only shape for every state pair.
//   - emit(state:) routes through Recorder.shared.recordEvent with
//     `app_lifecycle`, carrying the right (state, previous_state).
//   - emit(state:) updates the internal previous-state pointer so
//     consecutive emissions chain correctly.
//   - emitSessionFinalized() routes through Recorder.shared.recordEvent
//     with `session.finalized`.
//   - install() idempotent + concurrent-safe (just exercises the
//     install/uninstall cycle — the actual notification fan-out is
//     covered by the iOS-only path below).
//   - Recorder.isEnabled = false halts emission.
//
// Notification-driven coverage:
//   On iOS we post each UIApplication notification by hand and assert
//   the right calls land on the probe recorder (drainOfflineQueue
//   for didBecomeActive, session.finalized auto-emit on willResignActive
//   and willTerminate, etc.).
//
// Refs: PLAN-iOS.md §F11/T11.1 acceptance; CLAUDE.md "Testing
//       conventions".
//

import XCTest
import Foundation
import EdgeRumCore
@testable import EdgeRumCapture
#if canImport(UIKit) && os(iOS)
import UIKit
#endif

// MARK: - Local probe recorder with drain tracking

private final class CaptureProbeRecorder: Recording, @unchecked Sendable {

    enum Call: Equatable {
        case event(name: String, attributes: [String: AttributeValue])
        case performance(name: String, attributes: [String: AttributeValue])
        case drain
        case refreshNetwork(NetworkContext)
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _enabled: Bool = true
    private let _clock: Clock

    init(clock: Clock = SystemClock(), enabled: Bool = true) {
        self._clock = clock
        self._enabled = enabled
    }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    var clock: Clock { _clock }
    var currentSessionId: String { "session_0_0000000000000000_ios" }
    var currentDeviceId: String { "device_0_0000000000000000_ios" }

    var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _enabled
    }

    func configure(_ config: RecorderConfig) { _ = config }
    func start(apiKey: String, endpoint: URL, debug: Bool) {
        _ = (apiKey, endpoint, debug)
    }
    func stop() {}
    func setEnabled(_ enabled: Bool) {
        lock.lock(); _enabled = enabled; lock.unlock()
    }

    func recordEvent(name: String, attributes: [String: AttributeValue]) {
        lock.lock()
        _calls.append(.event(name: name, attributes: attributes))
        lock.unlock()
    }

    func recordPerformance(name: String, attributes: [String: AttributeValue]) {
        lock.lock()
        _calls.append(.performance(name: name, attributes: attributes))
        lock.unlock()
    }

    func recordError(
        domain: String, code: Int, message: String?,
        context: [String: AttributeValue]
    ) {
        _ = (domain, code, message, context)
    }

    func setUser(_ user: RecorderUser) { _ = user }

    func refreshNetworkContext(_ context: NetworkContext) {
        lock.lock()
        _calls.append(.refreshNetwork(context))
        lock.unlock()
    }

    func drainOfflineQueue() {
        lock.lock()
        _calls.append(.drain)
        lock.unlock()
    }
}

final class LifecycleCaptureTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LifecycleCapture._resetPreviousStateForTesting()
    }

    override func tearDown() {
        LifecycleCapture._resetInstallFlagForTesting()
        Recorder.resetShared()
        super.tearDown()
    }

    // MARK: makeAttributes shape

    func test_makeAttributes_shape() {
        let attrs = LifecycleCapture.makeAttributes(
            state: "active",
            previousState: "inactive"
        )
        XCTAssertEqual(attrs["lifecycle.state"], .string("active"))
        XCTAssertEqual(attrs["lifecycle.previous_state"], .string("inactive"))
        XCTAssertEqual(attrs.count, 2)
    }

    func test_makeAttributes_unknownPrevious_onFirstEmission() {
        let attrs = LifecycleCapture.makeAttributes(
            state: "foregrounded",
            previousState: "unknown"
        )
        XCTAssertEqual(attrs["lifecycle.previous_state"], .string("unknown"))
    }

    // MARK: emit routes through Recorder.shared.recordEvent

    func test_emit_routes_app_lifecycle_to_recorder() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)

        LifecycleCapture.emit(state: "backgrounded")

        XCTAssertEqual(probe.calls.count, 1)
        guard case let .event(name, attrs) = probe.calls[0] else {
            XCTFail("Expected event call, got \(probe.calls[0])")
            return
        }
        XCTAssertEqual(name, "app_lifecycle")
        XCTAssertEqual(attrs["lifecycle.state"], .string("backgrounded"))
        XCTAssertEqual(attrs["lifecycle.previous_state"], .string("unknown"))
    }

    func test_emit_chainsPreviousState_acrossCalls() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)

        LifecycleCapture.emit(state: "inactive")
        LifecycleCapture.emit(state: "backgrounded")
        LifecycleCapture.emit(state: "foregrounded")
        LifecycleCapture.emit(state: "active")

        XCTAssertEqual(probe.calls.count, 4)
        // Each event's previous_state matches the prior emission's
        // new state.
        guard case let .event(_, a0) = probe.calls[0],
              case let .event(_, a1) = probe.calls[1],
              case let .event(_, a2) = probe.calls[2],
              case let .event(_, a3) = probe.calls[3] else {
            XCTFail("Expected four event calls")
            return
        }
        XCTAssertEqual(a0["lifecycle.previous_state"], .string("unknown"))
        XCTAssertEqual(a1["lifecycle.previous_state"], .string("inactive"))
        XCTAssertEqual(a2["lifecycle.previous_state"], .string("backgrounded"))
        XCTAssertEqual(a3["lifecycle.previous_state"], .string("foregrounded"))
    }

    func test_emit_disabledRecorder_short_circuits() {
        let probe = CaptureProbeRecorder(enabled: false)
        Recorder.installShared(probe)

        LifecycleCapture.emit(state: "active")

        XCTAssertTrue(probe.calls.isEmpty)
    }

    // MARK: emitSessionFinalized

    func test_emitSessionFinalized_routesToRecorder() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)

        LifecycleCapture.emitSessionFinalized()

        XCTAssertEqual(probe.calls.count, 1)
        guard case let .event(name, attrs) = probe.calls[0] else {
            XCTFail("Expected event call, got \(probe.calls[0])")
            return
        }
        XCTAssertEqual(name, "session.finalized")
        XCTAssertTrue(attrs.isEmpty, "session.finalized rides on context-only attributes")
    }

    func test_emitSessionFinalized_disabledRecorder_short_circuits() {
        let probe = CaptureProbeRecorder(enabled: false)
        Recorder.installShared(probe)

        LifecycleCapture.emitSessionFinalized()

        XCTAssertTrue(probe.calls.isEmpty)
    }

    // MARK: install — idempotent
    //
    // The install body is gated behind `#if canImport(UIKit) && os(iOS)`
    // so on the macOS test runner `install(...)` is a no-op and
    // `isInstalled` stays `false`. The concurrent-safety test only
    // makes sense on iOS where the install body actually runs.

    #if canImport(UIKit) && os(iOS)

    func test_install_isIdempotent() {
        XCTAssertFalse(LifecycleCapture.isInstalled)
        LifecycleCapture.install(debug: false)
        XCTAssertTrue(LifecycleCapture.isInstalled)
        LifecycleCapture.install(debug: false)
        XCTAssertTrue(LifecycleCapture.isInstalled)
    }

    func test_install_concurrent_callsAreSafe() {
        // Pump the main runloop while waiting — `install()` does a
        // `DispatchQueue.main.sync` hop on background callers; blocking
        // main with `DispatchGroup.wait` would deadlock.
        let exp = expectation(description: "32 concurrent installs converge")
        exp.expectedFulfillmentCount = 32
        for _ in 0..<32 {
            DispatchQueue.global().async {
                LifecycleCapture.install(debug: false)
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 30)
        XCTAssertTrue(LifecycleCapture.isInstalled)
    }

    #else

    func test_install_isNoop_onNonUIKitHost() {
        XCTAssertFalse(LifecycleCapture.isInstalled)
        LifecycleCapture.install(debug: false)
        XCTAssertFalse(LifecycleCapture.isInstalled,
                       "Non-UIKit hosts must remain uninstalled — no UIApplication notifications to observe")
    }

    #endif

    // MARK: Notification-driven fan-out — iOS only

    #if canImport(UIKit) && os(iOS)

    func test_willResignActive_emits_inactive_and_sessionFinalized() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)
        LifecycleCapture.install(debug: false)

        let expectation = expectation(description: "main runloop drained")
        NotificationCenter.default.post(
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        let calls = probe.calls
        let eventNames = calls.compactMap { call -> String? in
            if case let .event(name, _) = call { return name } else { return nil }
        }
        XCTAssertTrue(eventNames.contains("app_lifecycle"))
        XCTAssertTrue(eventNames.contains("session.finalized"))

        guard let lifecycle = calls.first(where: { call in
            if case let .event(name, _) = call { return name == "app_lifecycle" }
            return false
        }), case let .event(_, attrs) = lifecycle else {
            XCTFail("Expected an app_lifecycle event")
            return
        }
        XCTAssertEqual(attrs["lifecycle.state"], .string("inactive"))
    }

    func test_didBecomeActive_emits_active_and_drainsOfflineQueue() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)
        LifecycleCapture.install(debug: false)

        let expectation = expectation(description: "main runloop drained")
        NotificationCenter.default.post(
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        let calls = probe.calls
        XCTAssertTrue(calls.contains { call in
            if case let .event(name, attrs) = call {
                return name == "app_lifecycle" &&
                    attrs["lifecycle.state"] == .string("active")
            }
            return false
        })
        XCTAssertTrue(calls.contains(.drain))
    }

    func test_didEnterBackground_emits_backgrounded() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)
        LifecycleCapture.install(debug: false)

        let expectation = expectation(description: "main runloop drained")
        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        XCTAssertTrue(probe.calls.contains { call in
            if case let .event(name, attrs) = call {
                return name == "app_lifecycle" &&
                    attrs["lifecycle.state"] == .string("backgrounded")
            }
            return false
        })
    }

    func test_willEnterForeground_emits_foregrounded() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)
        LifecycleCapture.install(debug: false)

        let expectation = expectation(description: "main runloop drained")
        NotificationCenter.default.post(
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        XCTAssertTrue(probe.calls.contains { call in
            if case let .event(name, attrs) = call {
                return name == "app_lifecycle" &&
                    attrs["lifecycle.state"] == .string("foregrounded")
            }
            return false
        })
    }

    func test_willTerminate_emits_will_terminate_and_sessionFinalized() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)
        LifecycleCapture.install(debug: false)

        let expectation = expectation(description: "main runloop drained")
        NotificationCenter.default.post(
            name: UIApplication.willTerminateNotification,
            object: nil
        )
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        let names = probe.calls.compactMap { call -> String? in
            if case let .event(name, _) = call { return name } else { return nil }
        }
        XCTAssertTrue(names.contains("app_lifecycle"))
        XCTAssertTrue(names.contains("session.finalized"))

        XCTAssertTrue(probe.calls.contains { call in
            if case let .event(name, attrs) = call {
                return name == "app_lifecycle" &&
                    attrs["lifecycle.state"] == .string("will_terminate")
            }
            return false
        })
    }

    #endif
}
