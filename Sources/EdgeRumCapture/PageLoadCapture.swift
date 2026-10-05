// Sources/EdgeRumCapture/PageLoadCapture.swift
//
// F12 — Page-load timing.
//
// Emits exactly one `page_load` event per process, measuring the cold-
// start window from the SDK's earliest observable launch instant
// (PageLoadCapture.launchStart — first reference touches it; the first
// line of `EdgeRum.start()` touches it) to the first `CADisplayLink`
// tick observed while `UIApplication.shared.applicationState ==
// .active`. The event carries:
//
//   page_load.duration_ms      : Int?   ms launchStart → first active tick,
//                                       monotonic; omitted if unreadable
//   page_load.prewarmed        : Bool   iOS 15+ ActivePrewarm env == "1"
//   page_load.source           : String "displaylink"
//   launch.pre_sdk_duration_ms : Int?   process start (p_starttime) →
//                                       launchStart; omitted when
//                                       prewarmed or unreadable (F34)
//
// Time to first frame = pre_sdk_duration_ms + duration_ms.
//
// Two static tokens guarantee correctness:
//
//   _installed — guards the install path so repeated `install()` calls
//                are no-ops.
//   _emitted   — guards the emit path so we record one event per process
//                even if the display link fires before we can invalidate.
//
// `page_load.cold_start` was deleted in F29: it was only `!prewarmed`,
// and warm vs cold is not observable in-process.
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
    // Captured on first reference to `launchStart`. The first line of
    // `EdgeRum.start()` touches it, so the SDK's whole start cost is a
    // prefix of `page_load.duration_ms`. The wall instant pairs with a
    // monotonic reading; durations use the monotonic one (F34).

    nonisolated(unsafe) private static let _launchStartLock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()

    nonisolated(unsafe) private static var _launchStart: (wall: Date, ns: UInt64) = (Date(), monotonicNs())

    /// The instant the SDK first observed launch. First access initializes
    /// it via the `_launchStart` default expression; `touchLaunchStart()`
    /// is the standard way `EdgeRum.start(_:)` forces that first access.
    public static var launchStart: Date {
        os_unfair_lock_lock(_launchStartLock)
        defer { os_unfair_lock_unlock(_launchStartLock) }
        return _launchStart.wall
    }

    /// `launchStart` on the monotonic clock (`CLOCK_MONOTONIC_RAW`, ns).
    public static var launchStartNs: UInt64 {
        os_unfair_lock_lock(_launchStartLock)
        defer { os_unfair_lock_unlock(_launchStartLock) }
        return _launchStart.ns
    }

    /// `CLOCK_MONOTONIC_RAW` in ns; `0` when the clock cannot be read.
    public static func monotonicNs() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    }

    /// Whole ms from `startNs` to `endNs`, or `nil` when either reading
    /// failed (`0`) or the interval runs backwards — omit, never `0`.
    public static func elapsedMs(fromNs startNs: UInt64, toNs endNs: UInt64) -> Int? {
        guard startNs != 0, endNs != 0, endNs >= startNs else { return nil }
        return Int((Double(endNs - startNs) / 1_000_000).rounded())
    }

    /// `launch.pre_sdk_duration_ms`: process start → `launchStart`. `nil`
    /// when prewarmed (the fork may be hours old), when the process
    /// start is unreadable, or when the wall clock ran backwards.
    static func preSdkDurationMs(processStart: Date?, launchStart: Date, prewarmed: Bool) -> Int? {
        guard !prewarmed, let processStart else { return nil }
        let ms = launchStart.timeIntervalSince(processStart) * 1000
        return ms >= 0 ? Int(ms.rounded()) : nil
    }

    /// Kernel process start time (`kinfo_proc.p_starttime`), or `nil`
    /// when `sysctl` fails.
    static func processStartTime() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        guard tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
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
    /// `prewarmed` is passed in (rather than read from static state)
    /// so this function stays trivially testable.
    static func makeAttributes(
        durationMs: Int?,
        prewarmed: Bool,
        preSdkDurationMs: Int? = nil
    ) -> [String: AttributeValue] {
        var attrs: [String: AttributeValue] = [
            "page_load.prewarmed": .bool(prewarmed),
            "page_load.source": .string("displaylink")
        ]
        if let durationMs { attrs["page_load.duration_ms"] = .int(durationMs) }
        if let preSdkDurationMs { attrs["launch.pre_sdk_duration_ms"] = .int(preSdkDurationMs) }
        return attrs
    }

    // MARK: Emission

    /// Emit one `page_load` event. One-shot per process: subsequent
    /// calls return without touching the Recorder. Returns `true` if
    /// the event was recorded, `false` if the guard short-circuited.
    @discardableResult
    static func emit(
        durationMs: Int?,
        prewarmed: Bool,
        preSdkDurationMs: Int? = nil
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
                prewarmed: prewarmed,
                preSdkDurationMs: preSdkDurationMs
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
            // Monotonic, so an NTP step cannot bend it; an unreadable
            // interval is omitted, never shipped as 0 (F34).
            let durationMs = PageLoadCapture.elapsedMs(
                fromNs: PageLoadCapture.launchStartNs,
                toNs: PageLoadCapture.monotonicNs()
            )
            let preSdkMs = PageLoadCapture.preSdkDurationMs(
                processStart: PageLoadCapture.processStartTime(),
                launchStart: PageLoadCapture.launchStart,
                prewarmed: prewarmed
            )

            let recorded = PageLoadCapture.emit(
                durationMs: durationMs,
                prewarmed: prewarmed,
                preSdkDurationMs: preSdkMs
            )

            link.invalidate()
            self.displayLink = nil
            if let token = activationObserver {
                NotificationCenter.default.removeObserver(token)
                activationObserver = nil
            }

            if debug {
                os_log(
                    "page_load fired: duration_ms=%{public}d prewarmed=%{public}@ recorded=%{public}@",
                    log: PageLoadCapture.log,
                    type: .info,
                    durationMs ?? -1,
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
        let ago = UInt64(max(0, -date.timeIntervalSinceNow) * 1_000_000_000)
        let ns = monotonicNs()
        os_unfair_lock_lock(_launchStartLock)
        _launchStart = (date, ns > ago ? ns - ago : 1)
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
