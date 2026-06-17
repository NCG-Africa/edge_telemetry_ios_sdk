// Sources/EdgeRumCapture/LifecycleCapture.swift
//
// F11 / T11.1 — UIApplication lifecycle capture.
//
// Subscribes to the five UIApplication notifications that map to the
// `lifecycle.state` vocabulary (PLAN-iOS.md §6.18):
//
//   willResignActive       → "inactive"   + emit `session.finalized` (auto-flushes)
//   didEnterBackground     → "backgrounded"
//   willEnterForeground    → "foregrounded"
//   didBecomeActive        → "active"     + drainOfflineQueue()
//   willTerminate          → "will_terminate" + immediate finalize+flush
//
// Each transition emits one `app_lifecycle` event carrying
// `lifecycle.state` and `lifecycle.previous_state` (the last state
// this capture observed; `"unknown"` until the first transition).
//
// Recorder access: live `Recorder.shared` is fetched per emission;
// tests swap a probe in via `Recorder.installShared(_:)`.
//
// All UIKit code is gated behind `#if canImport(UIKit) && os(iOS)` so
// `swift test` on the macOS CI host still compiles this file.
//
// Refs: PLAN-iOS.md §F11/T11.1, §6.18; CLAUDE.md "eventName values" +
//       "When in doubt checklist" items 1, 2, 4, 8, 10.
//

import Foundation
#if canImport(UIKit) && os(iOS)
import UIKit
#endif
import os.log
#if canImport(EdgeRumCore)
import EdgeRumCore
#endif

/// F11 installer — UIKit lifecycle capture.
///
/// `public` here only means "visible to other internal SDK targets
/// and the test target". `EdgeRumCapture` is not a SwiftPM `product`,
/// so consumers who write `import EdgeRum` never see this type.
public enum LifecycleCapture {

    // MARK: Diagnostics

    private static let log = OSLog(subsystem: "com.edge.rum", category: "LifecycleCapture")

    // MARK: Once token

    private static let installLock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()

    nonisolated(unsafe) private static var _installed: Bool = false

    /// `true` once `install(...)` has registered the lifecycle
    /// observers. Read by tests and by the EdgeRum opt-out path.
    public static var isInstalled: Bool {
        os_unfair_lock_lock(installLock)
        defer { os_unfair_lock_unlock(installLock) }
        return _installed
    }

    // MARK: Previous-state tracking

    /// Tracked transition target. `"unknown"` until the first
    /// notification arrives.
    nonisolated(unsafe) private static var previousState: String = "unknown"
    private static let previousStateLock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()

    nonisolated(unsafe) private static var lifecycleObservers: [NSObjectProtocol] = []

    // MARK: Public install

    /// Install lifecycle capture. Idempotent + main-thread-safe; on
    /// non-UIKit hosts (the macOS unit-test runner) this is a no-op.
    public static func install(debug: Bool = false) {
        #if canImport(UIKit) && os(iOS)
        if Thread.isMainThread {
            performInstall(debug: debug)
        } else {
            DispatchQueue.main.sync { performInstall(debug: debug) }
        }
        #else
        _ = debug
        #endif
    }

    // MARK: Pure attribute builder (test seam)

    /// Build the `app_lifecycle` attribute bag for a given
    /// `(newState, previousState)` pair. Pure; tests drive it directly.
    static func makeAttributes(state: String, previousState: String) -> [String: AttributeValue] {
        [
            "lifecycle.state": .string(state),
            "lifecycle.previous_state": .string(previousState)
        ]
    }

    // MARK: Emission

    /// Emit one `app_lifecycle` event with the supplied state. Updates
    /// the internal previous-state pointer so the next emission carries
    /// the correct transition source. Exposed `internal` so tests can
    /// drive emission without posting real notifications.
    static func emit(state: String) {
        let recorder = Recorder.shared
        guard recorder.isEnabled else { return }

        os_unfair_lock_lock(previousStateLock)
        let prior = previousState
        previousState = state
        os_unfair_lock_unlock(previousStateLock)

        recorder.recordEvent(
            name: "app_lifecycle",
            attributes: makeAttributes(state: state, previousState: prior)
        )
    }

    /// Emit `session.finalized` (which auto-flushes per Recorder
    /// transport rules). Used on `willResignActive` and `willTerminate`
    /// so the in-memory buffer is on the wire before the OS suspends
    /// or kills the process.
    static func emitSessionFinalized() {
        let recorder = Recorder.shared
        guard recorder.isEnabled else { return }
        recorder.recordEvent(name: "session.finalized", attributes: [:])
    }

    // MARK: Install machinery

    #if canImport(UIKit) && os(iOS)
    private static func performInstall(debug: Bool) {
        os_unfair_lock_lock(installLock)
        if _installed {
            os_unfair_lock_unlock(installLock)
            return
        }

        let nc = NotificationCenter.default

        let willResign = nc.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            LifecycleCapture.emit(state: "inactive")
            LifecycleCapture.emitSessionFinalized()
        }
        let didEnterBackground = nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            LifecycleCapture.emit(state: "backgrounded")
        }
        let willEnterForeground = nc.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            LifecycleCapture.emit(state: "foregrounded")
        }
        let didBecomeActive = nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            LifecycleCapture.emit(state: "active")
            Recorder.shared.drainOfflineQueue()
        }
        let willTerminate = nc.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            LifecycleCapture.emit(state: "will_terminate")
            LifecycleCapture.emitSessionFinalized()
        }

        lifecycleObservers = [
            willResign,
            didEnterBackground,
            willEnterForeground,
            didBecomeActive,
            willTerminate
        ]
        _installed = true
        os_unfair_lock_unlock(installLock)

        if debug {
            os_log(
                "LifecycleCapture installed",
                log: log,
                type: .info
            )
        }
    }
    #endif

    // MARK: Test-only helpers

    #if DEBUG
    /// Tear down the registered observers and clear the install flag so
    /// subsequent tests can drive `install()` from a clean state.
    public static func _resetInstallFlagForTesting() {
        os_unfair_lock_lock(installLock)
        let nc = NotificationCenter.default
        for token in lifecycleObservers {
            nc.removeObserver(token)
        }
        lifecycleObservers.removeAll()
        _installed = false
        os_unfair_lock_unlock(installLock)

        os_unfair_lock_lock(previousStateLock)
        previousState = "unknown"
        os_unfair_lock_unlock(previousStateLock)
    }

    /// Test seam — read the tracked previous state without emitting.
    public static var _previousStateForTesting: String {
        os_unfair_lock_lock(previousStateLock)
        defer { os_unfair_lock_unlock(previousStateLock) }
        return previousState
    }

    /// Test seam — reset just the tracked previous state without
    /// touching install observers.
    public static func _resetPreviousStateForTesting() {
        os_unfair_lock_lock(previousStateLock)
        previousState = "unknown"
        os_unfair_lock_unlock(previousStateLock)
    }
    #endif
}
