// Sources/EdgeRumCapture/UIViewControllerCapture.swift
//
// F6 — UIKit screen-entry/exit capture.
//
// Installs once from `EdgeRum.start()`. Swizzles base
// `UIViewController.viewDidAppear(_:)` and `viewWillDisappear(_:)`
// so every screen produces:
//
//   - One `navigation` event on appear, carrying:
//       navigation.screen          — accessibilityIdentifier (preferred)
//                                    or `String(reflecting: type(of: vc))`
//       navigation.kind            — "uikit" or "swiftui"
//       navigation.type            — "viewDidAppear"
//       navigation.previous_screen — last appeared screen (omitted if nil)
//   - One `screen.duration` performance metric on disappear, carrying
//     `value` (seconds, Double) and `screen.duration_ms` (Int) plus
//     `screen.name` and `screen.kind`.
//
// Container view controllers (`UINavigationController`,
// `UITabBarController`, `UIPageViewController`) are skipped — the
// contained controller's own `viewDidAppear` does the work.
//
// `UIHostingController<Content>` is detected by `String(reflecting:)`
// match and emits `navigation.kind = "swiftui"` with the hosted
// Content type as the screen name (per PLAN-iOS.md §6.2). No new
// `eventName` is introduced for SwiftUI hosting.
//
// Recorder access: the live shared `Recorder` is fetched via
// `Recorder.shared` on each call. Tests swap a probe in via
// `Recorder.installShared(_:)` / `Recorder.resetShared()` — no
// closure injection needed.
//
// All UIKit code is gated behind `#if canImport(UIKit) && os(iOS)`
// so `swift test` on the macOS CI host still compiles this file.
//
// Refs: PLAN-iOS.md §F6, §6.1, §6.2; CLAUDE.md "When in doubt
//       checklist" items 1, 2, 3, 4, 8.
//

import Foundation
#if canImport(UIKit) && os(iOS)
import UIKit
import ObjectiveC.runtime
#endif
import os.log
#if canImport(EdgeRumCore)
// SwiftPM build — EdgeRumCore is a separate module. CocoaPods rolls
// everything into one umbrella, so the import is gated.
import EdgeRumCore
#endif

/// F6 installer — UIKit screen capture via base-class swizzling.
///
/// `public` here only means "visible to other internal SDK targets
/// and the test target". `EdgeRumCapture` is not a SwiftPM `product`,
/// so consumers who write `import EdgeRum` never see this type.
public enum UIViewControllerCapture {

    // MARK: Diagnostics

    private static let log = OSLog(subsystem: "com.edge.rum", category: "UIViewControllerCapture")

    // MARK: Once token

    /// Tiny once-token wrapping an `os_unfair_lock`. The Objective-C
    /// runtime guarantees that `method_exchangeImplementations` is
    /// atomic, but the surrounding "have I done this yet?" decision
    /// is not — so we serialise the whole install behind one lock.
    private static let installLock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()

    nonisolated(unsafe) private static var _installed: Bool = false

    /// `true` once `install(...)` has performed the IMP swap. Read by
    /// tests and by the `EdgeRum.start()` opt-out path. Module-internal
    /// — never used by consumers.
    public static var isInstalled: Bool {
        os_unfair_lock_lock(installLock)
        defer { os_unfair_lock_unlock(installLock) }
        return _installed
    }

    // MARK: Public install

    /// Install the UIKit screen capture swizzles. Idempotent and
    /// thread-safe; only the first call performs the IMP exchange.
    /// Subsequent calls are silent no-ops.
    ///
    /// Must be called on the main thread. When called off the main
    /// thread, dispatches synchronously to main so the IMP swap
    /// remains safe.
    ///
    /// - Parameter debug: when `true`, install diagnostics route to
    ///   `os_log` so the host can confirm the swizzle landed. When
    ///   `false` (production default) the install is silent.
    public static func install(debug: Bool = false) {
        #if canImport(UIKit) && os(iOS)
        if Thread.isMainThread {
            performInstall(debug: debug)
        } else {
            DispatchQueue.main.sync { performInstall(debug: debug) }
        }
        #else
        _ = debug
        // Non-UIKit hosts (macOS unit-test runner) — no-op.
        #endif
    }

    #if canImport(UIKit) && os(iOS)
    private static func performInstall(debug: Bool) {
        os_unfair_lock_lock(installLock)
        if _installed {
            os_unfair_lock_unlock(installLock)
            return
        }
        swizzle(
            base: UIViewController.self,
            original: #selector(UIViewController.viewDidAppear(_:)),
            swizzled: #selector(UIViewController.edgerum_swizzled_viewDidAppear(_:))
        )
        swizzle(
            base: UIViewController.self,
            original: #selector(UIViewController.viewWillDisappear(_:)),
            swizzled: #selector(UIViewController.edgerum_swizzled_viewWillDisappear(_:))
        )
        _installed = true
        os_unfair_lock_unlock(installLock)
        if debug {
            os_log("UIViewControllerCapture installed", log: log, type: .info)
        }
    }

    private static func swizzle(base: AnyClass, original: Selector, swizzled: Selector) {
        guard
            let originalMethod = class_getInstanceMethod(base, original),
            let swizzledMethod = class_getInstanceMethod(base, swizzled)
        else {
            os_log(
                "Could not resolve %{public}@ / %{public}@ on UIViewController — swizzle skipped",
                log: log,
                type: .error,
                NSStringFromSelector(original),
                NSStringFromSelector(swizzled)
            )
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }
    #endif

    // MARK: Per-VC bookkeeping (via associated objects)

    /// Used as the key for `objc_setAssociatedObject` storing the
    /// per-controller `ScreenState`. Pointer identity is what `objc`
    /// keys on, so we just need any stable static address.
    nonisolated(unsafe) static var screenStateKey: UInt8 = 0

    /// Per-controller bookkeeping retained on the controller itself
    /// (via associated objects) so it is freed automatically when the
    /// controller deallocates — no risk of leaking entries the way a
    /// Swift-side `[ObjectIdentifier: …]` dictionary would.
    final class ScreenState: NSObject {
        let name: String
        let kind: String
        let appearedAt: Date
        init(name: String, kind: String, appearedAt: Date) {
            self.name = name
            self.kind = kind
            self.appearedAt = appearedAt
        }
    }

    // MARK: Previous-screen pointer

    private static let prevLock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()
    nonisolated(unsafe) private static var _previousScreen: String?

    static func currentPreviousScreen() -> String? {
        os_unfair_lock_lock(prevLock)
        defer { os_unfair_lock_unlock(prevLock) }
        return _previousScreen
    }

    static func setPreviousScreen(_ name: String?) {
        os_unfair_lock_lock(prevLock)
        _previousScreen = name
        os_unfair_lock_unlock(prevLock)
    }

    // MARK: Name resolution

    #if canImport(UIKit) && os(iOS)
    static func resolveScreenName(_ vc: UIViewController) -> (name: String, kind: String) {
        let typeName = String(reflecting: type(of: vc))
        // 1. UIHostingController<Content> → SwiftUI; surface the hosted
        //    Content type as the screen name.
        if isHostingControllerTypeName(typeName) {
            let content = extractHostedContent(from: typeName) ?? typeName
            return (content, "swiftui")
        }
        // 2. accessibilityIdentifier wins for regular UIKit screens —
        //    stable across renames.
        if let aid = vc.accessibilityIdentifier, !aid.isEmpty {
            return (aid, "uikit")
        }
        // 3. Fallback: reflected type name.
        return (typeName, "uikit")
    }

    static func isContainerController(_ vc: UIViewController) -> Bool {
        vc is UINavigationController
            || vc is UITabBarController
            || vc is UIPageViewController
    }
    #endif

    /// `true` when the reflected type name names a `UIHostingController`
    /// generic specialisation. Matches both the `SwiftUI.` prefix (the
    /// vanilla case) and any module-qualified subclass like
    /// `MyApp.MyHostingController<…>`.
    static func isHostingControllerTypeName(_ typeName: String) -> Bool {
        if typeName.contains("UIHostingController<") {
            return true
        }
        return false
    }

    /// Extract the outermost `<…>` content from a Swift reflected type
    /// name. Returns `nil` when the name doesn't contain a generic
    /// specialisation. Balances angle brackets so nested generics
    /// (e.g. `UIHostingController<NavigationStack<HomeView>>`) come
    /// back intact.
    static func extractHostedContent(from typeName: String) -> String? {
        guard let openIdx = typeName.firstIndex(of: "<") else { return nil }
        var depth = 0
        var i = openIdx
        while i < typeName.endIndex {
            let ch = typeName[i]
            if ch == "<" {
                depth += 1
            } else if ch == ">" {
                depth -= 1
                if depth == 0 {
                    let contentStart = typeName.index(after: openIdx)
                    return String(typeName[contentStart..<i])
                }
            }
            i = typeName.index(after: i)
        }
        return nil
    }

    // MARK: Emission

    #if canImport(UIKit) && os(iOS)
    static func handleViewDidAppear(_ vc: UIViewController) {
        let recorder = Recorder.shared
        guard recorder.isEnabled else { return }
        if isContainerController(vc) { return }

        let (name, kind) = resolveScreenName(vc)
        let now = recorder.clock.now

        // Save per-controller state for the disappear pair.
        let state = ScreenState(name: name, kind: kind, appearedAt: now)
        objc_setAssociatedObject(
            vc,
            &screenStateKey,
            state,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        // Build the navigation attribute bag.
        var attrs: [String: AttributeValue] = [
            "navigation.screen": .string(name),
            "navigation.kind": .string(kind),
            "navigation.type": .string("viewDidAppear")
        ]
        if let previous = currentPreviousScreen() {
            attrs["navigation.previous_screen"] = .string(previous)
        }

        recorder.recordEvent(name: "navigation", attributes: attrs)
        setPreviousScreen(name)
    }

    static func handleViewWillDisappear(_ vc: UIViewController) {
        let recorder = Recorder.shared
        guard recorder.isEnabled else { return }
        if isContainerController(vc) { return }

        guard
            let state = objc_getAssociatedObject(vc, &screenStateKey) as? ScreenState
        else {
            // No paired appear — skip silently. Happens when the
            // controller was created before install or its appear
            // path was intercepted by an early-return branch.
            return
        }

        let dwell = recorder.clock.now.timeIntervalSince(state.appearedAt)
        let safeDwell = max(0.0, dwell)
        let ms = Int((safeDwell * 1000.0).rounded())

        let attrs: [String: AttributeValue] = [
            "screen.name": .string(state.name),
            "screen.kind": .string(state.kind),
            "screen.duration_ms": .int(ms),
            "value": .double(safeDwell)
        ]
        recorder.recordPerformance(name: "screen.duration", attributes: attrs)

        // Per-controller state is consumed; clear so a future appear/
        // disappear cycle on the same controller pairs cleanly.
        objc_setAssociatedObject(vc, &screenStateKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    #endif

    // MARK: Test-only helpers

    #if DEBUG
    /// Clear the global `previousScreen` pointer so each test starts
    /// from a known state. The swizzle install itself is intentionally
    /// NOT reset — IMP swaps cannot be safely undone on Objective-C
    /// classes, and a partial undo would deadlock with system frames.
    public static func _resetPreviousScreenForTesting() {
        setPreviousScreen(nil)
    }

    /// Mark the swizzle as "not installed" so tests that want to
    /// verify the opt-out path can drive `EdgeRum.start()` and assert
    /// `isInstalled` stayed `false`. The IMP table is not touched.
    /// Calling `install()` after this will perform the swap (or no-op
    /// if it was already done).
    public static func _resetInstallFlagForTesting() {
        os_unfair_lock_lock(installLock)
        _installed = false
        os_unfair_lock_unlock(installLock)
    }
    #endif
}

// MARK: - UIKit swizzle entry points
//
// Defined as Objective-C-visible methods on `UIViewController` so the
// runtime can resolve them by selector for the IMP exchange. After
// `method_exchangeImplementations` runs, the selector
// `viewDidAppear:` resolves to the body below, and
// `edgerum_swizzled_viewDidAppear:` resolves to UIKit's original
// implementation — that's why each body calls
// `edgerum_swizzled_viewDidAppear(animated)` first.

#if canImport(UIKit) && os(iOS)
internal extension UIViewController {
    @objc
    func edgerum_swizzled_viewDidAppear(_ animated: Bool) {
        // After the IMP swap this calls UIKit's original viewDidAppear.
        edgerum_swizzled_viewDidAppear(animated)
        UIViewControllerCapture.handleViewDidAppear(self)
    }

    @objc
    func edgerum_swizzled_viewWillDisappear(_ animated: Bool) {
        edgerum_swizzled_viewWillDisappear(animated)
        UIViewControllerCapture.handleViewWillDisappear(self)
    }
}
#endif
