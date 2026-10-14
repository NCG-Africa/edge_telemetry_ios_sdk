// Sources/EdgeRumCore/Context/ContextObservers.swift
//
// F16 — Idempotent installer for the notification observers that keep
// `PowerContext`,
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
//     - UIApplication.backgroundRefreshStatusDidChangeNotification
//   T16.5 DeviceContext locale/timezone refresh:
//     - NSLocale.currentLocaleDidChangeNotification
//   F28 riders (written to `Riders`, not the ContextProvider):
//     - app.state: the four UIApplication activation notifications
//     - device.orientation: UIDevice.orientationDidChangeNotification,
//       read back as the window scene's *interface* orientation
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
    /// observers.
    public static var isInstalled: Bool {
        os_unfair_lock_lock(installLock)
        defer { os_unfair_lock_unlock(installLock) }
        return _installed
    }

    // MARK: - State

    nonisolated(unsafe) private static var observers: [NSObjectProtocol] = []

    // MARK: - Public install

    /// Install all F16 observers.
    /// Idempotent — second and subsequent calls are no-ops. Safe to
    /// call from any thread; UIKit reads inside the notification
    /// callbacks hop to main as needed.
    public static func install(
        provider: ContextProvider,
        riders: Riders = .shared,
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

        // T16.4 — `app.background_refresh` changes only on this
        // notification. (No disk polling: #254, E174.1 keeps disk space
        // on the device.)
        tokens.append(nc.addObserver(
            forName: UIApplication.backgroundRefreshStatusDidChangeNotification,
            object: nil, queue: .main
        ) { [weak provider] _ in
            provider?.refreshStorage(StorageContext.snapshot())
        })

        // F28 — app.state + device.orientation riders.
        let appStates: [(Notification.Name, String)] = [
            (UIApplication.didBecomeActiveNotification, "active"),
            (UIApplication.willResignActiveNotification, "inactive"),
            (UIApplication.willEnterForegroundNotification, "inactive"),
            (UIApplication.didEnterBackgroundNotification, "background")
        ]
        for (name, state) in appStates {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                riders.setAppState(state)
                riders.setOrientation(interfaceOrientation())
                Actions.shared.noteAppState(state)  // F36 background hops
            })
        }
        // F33 — the only clean exit iOS announces.
        tokens.append(nc.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { _ in
            (Recorder.shared as? Recorder)?.markCleanExit()
        })
        tokens.append(nc.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            // ponytail: one main-queue hop so the scene has rotated before
            // the read. If it ever lags, observe the scene's geometry instead.
            DispatchQueue.main.async { riders.setOrientation(interfaceOrientation()) }
        })
        let seed = {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            let state = appStateName(UIApplication.shared.applicationState)
            riders.setAppState(state)
            Actions.shared.noteAppState(state)  // F36: a background launch
            riders.setOrientation(interfaceOrientation())
        }
        if Thread.isMainThread { seed() } else { DispatchQueue.main.async(execute: seed) }
        #endif

        os_unfair_lock_lock(installLock)
        observers = tokens
        os_unfair_lock_unlock(installLock)

        if debug {
            os_log("ContextObservers installed (F16)", log: log, type: .info)
        }
    }

    // MARK: - Rider reads (main thread)

    #if canImport(UIKit) && os(iOS)
    internal static func appStateName(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .background: return "background"
        default: return "inactive"
        }
    }

    /// Interface (not hardware) orientation of the foreground scene;
    /// upside-down and both landscapes collapse. `nil` when unknown.
    private static func interfaceOrientation() -> String? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let orientation = scene?.interfaceOrientation else { return nil }
        if orientation.isLandscape { return "landscape" }
        if orientation.isPortrait { return "portrait" }
        return nil
    }
    #endif

    // MARK: - Test-only helpers

    #if DEBUG
    /// Tear down the registered observers and clear
    /// the install flag so subsequent tests can drive `install(...)`
    /// from a clean state.
    public static func _resetInstallFlagForTesting() {
        os_unfair_lock_lock(installLock)
        let removedObservers = observers
        observers.removeAll()
        _installed = false
        os_unfair_lock_unlock(installLock)

        let nc = NotificationCenter.default
        for token in removedObservers {
            nc.removeObserver(token)
        }
    }

    /// Force a one-shot storage refresh.
    public static func _refreshStorageNowForTesting(provider: ContextProvider) {
        provider.refreshStorage(StorageContext.snapshot())
    }
    #endif
}
