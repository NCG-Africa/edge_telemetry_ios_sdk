// Sources/EdgeRumCapture/PageLoadCapture.swift
//
// F12 — Page-load timing.
//
// Emits exactly one `page_load` event per process, measuring the cold-
// start window from the SDK's earliest observable launch instant
// (PageLoadCapture.launchStart — first reference touches it; EdgeRum
// touches it before any other startup work) to the first
// `CADisplayLink` tick observed while `UIApplication.shared.application-
// State == .active`. The event carries:
//
//   page_load.duration_ms : Int     ms from launchStart to first active tick
//   page_load.cold_start  : Bool    true unless prewarmed
//   page_load.prewarmed   : Bool    iOS 15+ ActivePrewarm env == "1"
//   page_load.source      : String  "displaylink"
//
// Two static tokens guarantee correctness:
//
//   _installed — guards the install path so repeated `install()` calls
//                are no-ops.
//   _emitted   — guards the emit path so we record one event per process
//                even if the display link fires before we can invalidate.
//
// PLAN-iOS.md §6.4 originally described the keys as `page_load.cold` /
// `page_load.prewarm`; the GitHub issues (#17 / #69 / #70) refined them
// to the snake_case `cold_start` / `prewarmed`. We emit the issue
// vocabulary; PLAN-iOS.md is updated in the same change.
//
// All UIKit / CADisplayLink code is gated behind `#if canImport(UIKit)
// && os(iOS)` so `swift test` on the macOS CI host still compiles this
// file — the non-iOS `install(...)` is a no-op.
//
// Refs: PLAN-iOS.md §F12, §6.4; CLAUDE.md "eventName values" +
//       "When in doubt checklist" items 1, 2, 4, 8, 10.
//

import Foundation
#if canImport(UIKit) && os(iOS)
import UIKit
import QuartzCore
#endif
import os.log
#if canImport(EdgeRumCore)
import EdgeRumCore
#endif

/// F12 installer — single-shot page-load capture.
///
/// `public` here only means "visible to other internal SDK targets and
/// the test target". `EdgeRumCapture` is not a SwiftPM `product`, so
/// consumers who write `import EdgeRum` never see this type.
public enum PageLoadCapture {

    // MARK: Diagnostics

    private static let log = OSLog(subsystem: "com.edge.rum", category: "PageLoadCapture")

    // MARK: Launch-start anchor
    //
    // Captured on first reference to `launchStart`. `EdgeRum.start()`
    // touches it before any other startup work (Recorder, samplers,
    // observers) so the anchor is sampled as close to host-app launch
    // as the SDK can observe.

    nonisolated(unsafe) private static let _launchStartLock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()

    nonisolated(unsafe) private static var _launchStart: Date = Date()

    /// The instant the SDK first observed launch. First access initializes
    /// it via the `_launchStart` default expression; `touchLaunchStart()`
    /// is the standard way `EdgeRum.start(_:)` forces that first access.
    public static var launchStart: Date {
        os_unfair_lock_lock(_launchStartLock)
        defer { os_unfair_lock_unlock(_launchStartLock) }
        return _launchStart
    }

    /// Touch `launchStart` so its lazy default expression fires now.
    /// Idempotent. Returns the captured instant.
    @discardableResult
    public static func touchLaunchStart() -> Date {
        return launchStart
    }

    // MARK: Prewarm detection
    //
    // iOS 15+: `ProcessInfo.processInfo.environment["ActivePrewarm"]`
    // reads `"1"` on a prewarmed launch. iOS 14 has no such env var so
    // we always return `false`. The value is computed once at first
    // access; `_overridePrewarmedForTesting(_:)` lets the unit tests
    // drive both branches.

    nonisolated(unsafe) private static let _prewarmOverrideLock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()

    nonisolated(unsafe) private static var _prewarmedOverride: Bool?

    private static let _prewarmedDetected: Bool = {
        #if canImport(UIKit) && os(iOS)
        if #available(iOS 15.0, *) {
            return ProcessInfo.processInfo.environment["ActivePrewarm"] == "1"
        }
        return false
        #else
        return false
        #endif
    }()

    /// `true` iff the OS marked this launch as prewarmed (iOS 15+ with
    /// `ActivePrewarm=1`). Tests can override via
    /// `_overridePrewarmedForTesting(_:)`.
    public static var prewarmedAtLaunch: Bool {
        os_unfair_lock_lock(_prewarmOverrideLock)
        let override = _prewarmedOverride
        os_unfair_lock_unlock(_prewarmOverrideLock)
        return override ?? _prewarmedDetected
    }

    // MARK: Install + emit tokens

    nonisolated(unsafe) private static let installLock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()

    nonisolated(unsafe) private static var _installed: Bool = false

    /// `true` once `install(...)` has wired the display link / observer.
    public static var isInstalled: Bool {
        os_unfair_lock_lock(installLock)
        defer { os_unfair_lock_unlock(installLock) }
        return _installed
    }

    nonisolated(unsafe) private static let emitLock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()

    nonisolated(unsafe) private static var _emitted: Bool = false

    /// `true` once the single `page_load` event for this process has
    /// been recorded.
    public static var hasEmitted: Bool {
        os_unfair_lock_lock(emitLock)
        defer { os_unfair_lock_unlock(emitLock) }
        return _emitted
    }

    // MARK: Public install

    /// Install page-load capture. Idempotent + main-thread-safe; on
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

    /// Build the `page_load` attribute bag. Pure; tests drive it directly.
    /// `coldStart` and `prewarmed` are passed in (rather than read from
    /// static state) so this function stays trivially testable.
    static func makeAttributes(
        durationMs: Int,
        coldStart: Bool,
        prewarmed: Bool
    ) -> [String: AttributeValue] {
        [
            "page_load.duration_ms": .int(durationMs),
            "page_load.cold_start": .bool(coldStart),
            "page_load.prewarmed": .bool(prewarmed),
            "page_load.source": .string("displaylink")
        ]
    }

    // MARK: Emission

    /// Emit one `page_load` event. One-shot per process: subsequent
    /// calls return without touching the Recorder. Returns `true` if
    /// the event was recorded, `false` if the guard short-circuited.
    @discardableResult
    static func emit(
        durationMs: Int,
        coldStart: Bool,
        prewarmed: Bool
    ) -> Bool {
        os_unfair_lock_lock(emitLock)
        if _emitted {
            os_unfair_lock_unlock(emitLock)
            return false
        }
        _emitted = true
        os_unfair_lock_unlock(emitLock)

        let recorder = Recorder.shared
        guard recorder.isEnabled else {
            // Recorder declined emission — rewind the one-shot so a
            // later `enable()` + retry path can still produce the
            // event. Today nothing drives that retry path, but the
            // rewind keeps the gate honest.
            os_unfair_lock_lock(emitLock)
            _emitted = false
            os_unfair_lock_unlock(emitLock)
            return false
        }

        recorder.recordEvent(
            name: "page_load",
            attributes: makeAttributes(
                durationMs: durationMs,
                coldStart: coldStart,
                prewarmed: prewarmed
            )
        )
        return true
    }

    // MARK: UIKit install machinery

    #if canImport(UIKit) && os(iOS)

    /// The CADisplayLink target. UIKit retains a link's target weakly
    /// via the runloop; we hold a strong reference here so the driver
    /// outlives `install(...)`.
    private final class Driver: NSObject {

        private var displayLink: CADisplayLink?
        private var activationObserver: NSObjectProtocol?
        private let debug: Bool

        init(debug: Bool) {
            self.debug = debug
            super.init()
        }

        deinit {
            displayLink?.invalidate()
            if let token = activationObserver {
                NotificationCenter.default.removeObserver(token)
            }
        }

        /// Decide whether to schedule the link now or wait for the app
        /// to reach `.active`. Called once from `performInstall`.
        func arm() {
            if UIApplication.shared.applicationState == .active {
                scheduleDisplayLink()
                return
            }
            activationObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleDisplayLink()
            }
        }

        private func scheduleDisplayLink() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.displayLink = link
        }

        @objc
        private func tick(_ link: CADisplayLink) {
            // Defensive: a link scheduled from `didBecomeActive` should
            // already be active, but a same-runloop transition into
            // `.inactive` (e.g. an alert) can race us. Skip the frame
            // and wait for the next active tick.
            guard UIApplication.shared.applicationState == .active else {
                return
            }

            let prewarmed = PageLoadCapture.prewarmedAtLaunch
            let coldStart = !prewarmed
            let durationMs = Int(
                (Date().timeIntervalSince(PageLoadCapture.launchStart) * 1000.0).rounded()
            )

            // Defensive clamp — if the clock jumped backwards (rare,
            // but documented to happen across NTP corrections) we'd
            // otherwise ship a negative duration that the backend would
            // reject. The clamp keeps the event valid while preserving
            // the "exactly one event" guarantee.
            let safeDuration = max(0, durationMs)

            let recorded = PageLoadCapture.emit(
                durationMs: safeDuration,
                coldStart: coldStart,
                prewarmed: prewarmed
            )

            link.invalidate()
            self.displayLink = nil
            if let token = activationObserver {
                NotificationCenter.default.removeObserver(token)
                activationObserver = nil
            }

            if debug {
                os_log(
                    "page_load fired: duration_ms=%{public}d cold_start=%{public}@ prewarmed=%{public}@ recorded=%{public}@",
                    log: PageLoadCapture.log,
                    type: .info,
                    safeDuration,
                    coldStart ? "true" : "false",
                    prewarmed ? "true" : "false",
                    recorded ? "true" : "false"
                )
            }
        }

        func tearDown() {
            displayLink?.invalidate()
            displayLink = nil
            if let token = activationObserver {
                NotificationCenter.default.removeObserver(token)
                activationObserver = nil
            }
        }
    }

    nonisolated(unsafe) private static var sharedDriver: Driver?

    private static func performInstall(debug: Bool) {
        os_unfair_lock_lock(installLock)
        if _installed {
            os_unfair_lock_unlock(installLock)
            return
        }
        let driver = Driver(debug: debug)
        sharedDriver = driver
        _installed = true
        os_unfair_lock_unlock(installLock)

        driver.arm()

        if debug {
            os_log(
                "PageLoadCapture installed",
                log: log,
                type: .info
            )
        }
    }
    #endif

    // MARK: Test-only helpers

    #if DEBUG
    /// Tear down the running display link / observer and clear both the
    /// install and emit tokens, plus any test overrides, so subsequent
    /// tests can drive `install()` and `emit()` from a clean state.
    public static func _resetInstallFlagForTesting() {
        #if canImport(UIKit) && os(iOS)
        os_unfair_lock_lock(installLock)
        sharedDriver?.tearDown()
        sharedDriver = nil
        _installed = false
        os_unfair_lock_unlock(installLock)
        #else
        os_unfair_lock_lock(installLock)
        _installed = false
        os_unfair_lock_unlock(installLock)
        #endif

        os_unfair_lock_lock(emitLock)
        _emitted = false
        os_unfair_lock_unlock(emitLock)

        os_unfair_lock_lock(_prewarmOverrideLock)
        _prewarmedOverride = nil
        os_unfair_lock_unlock(_prewarmOverrideLock)
    }

    /// Pin the launch-start anchor to a fixed instant. Tests drive this
    /// before invoking the emit path so `duration_ms` is deterministic.
    public static func _setLaunchStartForTesting(_ date: Date) {
        os_unfair_lock_lock(_launchStartLock)
        _launchStart = date
        os_unfair_lock_unlock(_launchStartLock)
    }

    /// Override the prewarm detection branch. Pass `nil` to clear and
    /// fall back to the on-device detection. The unit tests use this
    /// to exercise both code paths without launching a fresh process
    /// with `ActivePrewarm=1` set.
    public static func _overridePrewarmedForTesting(_ value: Bool?) {
        os_unfair_lock_lock(_prewarmOverrideLock)
        _prewarmedOverride = value
        os_unfair_lock_unlock(_prewarmOverrideLock)
    }
    #endif
}
