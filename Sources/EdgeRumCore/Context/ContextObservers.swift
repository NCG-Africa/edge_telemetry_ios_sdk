// Sources/EdgeRumCore/Context/ContextObservers.swift
//
// F16 — Idempotent installer for the notification observers and the
// periodic storage refresh timer that keep `PowerContext`,
// `AccessibilityContext`, and `StorageContext` (and the locale/timezone
// fields on `DeviceContext`) up to date.
//
// Lives in `EdgeRumCore` rather than `EdgeRumCapture` because these
// observers don't swizzle anything and don't emit events; they only
// refresh in-memory snapshots on the supplied `ContextProvider`. See
// `docs/decisions.md` ADR-F16.
//
// Install machinery mirrors `LifecycleCapture` lines 137-226:
//   - one os_unfair_lock-guarded `_installed` flag
//   - notification observers stored in a static array of tokens
//   - DEBUG-only reset for tests
//
// Subscriptions (F16):
//   T16.1 PowerContext:
//     - ProcessInfo.thermalStateDidChangeNotification
//     - NSProcessInfoPowerStateDidChange
//   T16.2 AccessibilityContext:
//     - UIAccessibility.voiceOverStatusDidChangeNotification
//     - UIAccessibility.reduceMotionStatusDidChangeNotification
//     - UIAccessibility.boldTextStatusDidChangeNotification
//     - UIAccessibility.darkerSystemColorsStatusDidChangeNotification
//     - UIContentSizeCategory.didChangeNotification
//   T16.4 StorageContext:
//     - 5-minute `DispatchSource.makeTimerSource` on a utility queue
//     - suspend on willResignActive, resume on didBecomeActive
//   T16.5 DeviceContext locale/timezone refresh:
//     - NSLocale.currentLocaleDidChangeNotification
//
// Refs: PLAN-iOS.md §16.4 / F16; CLAUDE.md "When in doubt checklist"
//       item 1 (no public-surface change), item 8 (single install
//       guarded by Once token).
//

import Foundation
import os.log
#if canImport(UIKit)
import UIKit
#endif

public enum ContextObservers {

    // MARK: - Diagnostics

    private static let log = OSLog(subsystem: "com.edge.rum", category: "ContextObservers")

    // MARK: - Once token

    nonisolated(unsafe) private static let installLock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()

    nonisolated(unsafe) private static var _installed: Bool = false

    /// `true` once `install(provider:debug:)` has registered the
    /// observers and armed the storage timer.
    public static var isInstalled: Bool {
        os_unfair_lock_lock(installLock)
        defer { os_unfair_lock_unlock(installLock) }
        return _installed
    }

    // MARK: - State

    nonisolated(unsafe) private static var observers: [NSObjectProtocol] = []
    nonisolated(unsafe) private static var storageTimer: DispatchSourceTimer?
    nonisolated(unsafe) private static var storageTimerSuspended: Bool = false

    /// Storage refresh interval. 5 minutes per PLAN-iOS.md §16.4 / T16.4
    /// ("Refresh at session start + every 5 min").
    internal static let storageRefreshInterval: DispatchTimeInterval = .seconds(300)

    // MARK: - Public install

    /// Install all F16 observers and arm the storage refresh timer.
    /// Idempotent — second and subsequent calls are no-ops. Safe to
    /// call from any thread; UIKit reads inside the notification
    /// callbacks hop to main as needed.
    public static func install(
        provider: ContextProvider,
        debug: Bool = false
    ) {
        os_unfair_lock_lock(installLock)
        if _installed {
            os_unfair_lock_unlock(installLock)
            return
        }
        _installed = true
        os_unfair_lock_unlock(installLock)

        // Seed every context once so the very first event after
        // install carries fresh F16 attributes.
        provider.refreshPower(PowerContext.snapshot())
        provider.refreshAccessibility(AccessibilityContext.snapshot())
        provider.refreshStorage(StorageContext.snapshot())

        let nc = NotificationCenter.default
        var tokens: [NSObjectProtocol] = []

        // T16.1 — thermal + low power mode
        tokens.append(nc.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak provider] _ in
            provider?.refreshPower(PowerContext.snapshot())
        })
        // `NSProcessInfoPowerStateDidChange` is iOS 9.0+ but
        // macOS 12.0+. The package floor is macOS 11 (test host only),
        // so guard on macOS while leaving iOS unconditional.
        #if os(iOS)
        tokens.append(nc.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: nil
        ) { [weak provider] _ in
            provider?.refreshPower(PowerContext.snapshot())
        })
        #else
        if #available(macOS 12.0, *) {
            tokens.append(nc.addObserver(
                forName: Notification.Name.NSProcessInfoPowerStateDidChange,
                object: nil,
                queue: nil
            ) { [weak provider] _ in
                provider?.refreshPower(PowerContext.snapshot())
            })
        }
        #endif

        // T16.5 — locale & timezone (re-snapshot DeviceContext)
        tokens.append(nc.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak provider] _ in
            provider?.refreshDevice(DeviceContext.snapshot())
        })

        #if canImport(UIKit) && os(iOS)
        // T16.2 — accessibility flags
        let a11yRefresh: (Notification) -> Void = { [weak provider] _ in
            provider?.refreshAccessibility(AccessibilityContext.snapshot())
        }
        tokens.append(nc.addObserver(
            forName: UIAccessibility.voiceOverStatusDidChangeNotification,
            object: nil, queue: .main, using: a11yRefresh
        ))
        tokens.append(nc.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil, queue: .main, using: a11yRefresh
        ))
        tokens.append(nc.addObserver(
            forName: UIAccessibility.boldTextStatusDidChangeNotification,
            object: nil, queue: .main, using: a11yRefresh
        ))
        tokens.append(nc.addObserver(
            forName: UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
            object: nil, queue: .main, using: a11yRefresh
        ))
        tokens.append(nc.addObserver(
            forName: UIContentSizeCategory.didChangeNotification,
            object: nil, queue: .main, using: a11yRefresh
        ))

        // T16.4 — pause/resume storage timer on lifecycle transitions
        // so we don't run statfs while the app is backgrounded.
        tokens.append(nc.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main
        ) { _ in
            suspendStorageTimer()
        })
        tokens.append(nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak provider] _ in
            // Refresh once on foreground in case disk grew/shrank
            // while we were backgrounded.
            provider?.refreshStorage(StorageContext.snapshot())
            resumeStorageTimer()
        })
        #endif

        os_unfair_lock_lock(installLock)
        observers = tokens
        os_unfair_lock_unlock(installLock)

        // Arm the 5-minute storage refresh timer (utility queue,
        // mirrors `MemorySampler.swift:240`). Starts in the running
        // state; lifecycle hooks suspend/resume it.
        armStorageTimer(provider: provider)

        if debug {
            os_log("ContextObservers installed (F16)", log: log, type: .info)
        }
    }

    // MARK: - Storage timer

    private static func armStorageTimer(provider: ContextProvider) {
        let queue = DispatchQueue(label: "com.edge.rum.context.storage", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + storageRefreshInterval,
            repeating: storageRefreshInterval,
            leeway: .seconds(5)
        )
        timer.setEventHandler { [weak provider] in
            provider?.refreshStorage(StorageContext.snapshot())
        }
        os_unfair_lock_lock(installLock)
        storageTimer = timer
        storageTimerSuspended = false
        os_unfair_lock_unlock(installLock)
        timer.resume()
    }

    private static func suspendStorageTimer() {
        os_unfair_lock_lock(installLock)
        let timer = storageTimer
        let wasSuspended = storageTimerSuspended
        if let _ = timer, !wasSuspended {
            storageTimerSuspended = true
        }
        os_unfair_lock_unlock(installLock)
        if let timer = timer, !wasSuspended {
            timer.suspend()
        }
    }

    private static func resumeStorageTimer() {
        os_unfair_lock_lock(installLock)
        let timer = storageTimer
        let wasSuspended = storageTimerSuspended
        if let _ = timer, wasSuspended {
            storageTimerSuspended = false
        }
        os_unfair_lock_unlock(installLock)
        if let timer = timer, wasSuspended {
            timer.resume()
        }
    }

    // MARK: - Test-only helpers

    #if DEBUG
    /// Tear down the registered observers + storage timer and clear
    /// the install flag so subsequent tests can drive `install(...)`
    /// from a clean state.
    public static func _resetInstallFlagForTesting() {
        os_unfair_lock_lock(installLock)
        let removedObservers = observers
        let removedTimer = storageTimer
        let wasSuspended = storageTimerSuspended
        observers.removeAll()
        storageTimer = nil
        storageTimerSuspended = false
        _installed = false
        os_unfair_lock_unlock(installLock)

        let nc = NotificationCenter.default
        for token in removedObservers {
            nc.removeObserver(token)
        }
        if let timer = removedTimer {
            // `DispatchSourceTimer` must be resumed before
            // cancel/release; otherwise a suspended source crashes on
            // dealloc with EXC_BAD_INSTRUCTION.
            if wasSuspended {
                timer.resume()
            }
            timer.cancel()
        }
    }

    /// Force a one-shot storage refresh so tests can assert the timer
    /// path without waiting 5 minutes.
    public static func _refreshStorageNowForTesting(provider: ContextProvider) {
        provider.refreshStorage(StorageContext.snapshot())
    }
    #endif
}
