// Sources/EdgeRumCapture/InteractionCapture.swift
//
// F9 — UIKit tap capture via UIWindow.sendEvent(_:) swizzle.
//
// Installs once from `EdgeRum.start()` when `config.captureTaps` is
// true. Swizzles the base `UIWindow.sendEvent(_:)` so every completed
// tap produces one `user.interaction` event carrying:
//
//   interaction.kind       — always "tap"
//   interaction.target     — reflected class name of the resolved target
//                            (UIControl / cell / hit view), e.g.
//                            "UIKit.UIButton"
//   interaction.target_id  — accessibilityIdentifier, else UIButton
//                            current title; omitted when neither exists
//   interaction.screen     — current navigation screen name (from F6's
//                            UIViewControllerCapture); omitted when no
//                            screen has appeared yet
//
// Privacy carve-out (T9.2): if the hit view's responder chain reaches a
// `UITextField` with `isSecureTextEntry == true`, the tap is silently
// dropped. The capture path never reads `.text` from any view.
//
// Resolution rules (in order, see decideEmission):
//
//   1. Walk responder chain — bail on any secure-entry text field.
//   2. Walk superview chain — prefer UIControl, then UITableViewCell or
//      UICollectionViewCell, else fall back to the hit view itself.
//   3. Build the attribute bag with SDK-owned keys; nil-omit optional
//      identifiers.
//
// Touch handling: we emit on `.ended` only — `.began` would double-fire
// and a `.cancelled` tap (drag-away) shouldn't count as an interaction.
// One event per ended touch. Multi-finger taps therefore produce one
// event per finger, which matches how the SwiftUI `.edgeRumTrackTap`
// modifier handles multi-touch.
//
// Recorder access: the live shared `Recorder` is fetched via
// `Recorder.shared` on each call. Tests swap a probe in via
// `Recorder.installShared(_:)` / `Recorder.resetShared()` — no closure
// injection needed (same convention as F6 / F8).
//
// All UIKit code is gated behind `#if canImport(UIKit) && os(iOS)`
// so `swift test` on the macOS CI host still compiles this file.
//
// Refs: PLAN-iOS.md §F9, §6.5; CLAUDE.md "When in doubt checklist"
//       items 1, 2, 3, 4, 8.
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

/// F9 installer — UIKit tap capture via `UIWindow.sendEvent(_:)`
/// swizzling.
///
/// `public` here only means "visible to other internal SDK targets
/// and the test target". `EdgeRumCapture` is not a SwiftPM `product`,
/// so consumers who write `import EdgeRum` never see this type.
public enum InteractionCapture {

    // MARK: Diagnostics

    private static let log = OSLog(subsystem: "com.edge.rum", category: "InteractionCapture")

    // MARK: Once token

    /// Tiny once-token wrapping an `os_unfair_lock`. Matches the F6
    /// pattern in `UIViewControllerCapture`.
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

    /// Install the UIKit tap capture swizzle. Idempotent and
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
            base: UIWindow.self,
            original: #selector(UIWindow.sendEvent(_:)),
            swizzled: #selector(UIWindow.edgerum_swizzled_sendEvent(_:))
        )
        _installed = true
        os_unfair_lock_unlock(installLock)
        if debug {
            os_log("InteractionCapture installed", log: log, type: .info)
        }
    }

    private static func swizzle(base: AnyClass, original: Selector, swizzled: Selector) {
        guard
            let originalMethod = class_getInstanceMethod(base, original),
            let swizzledMethod = class_getInstanceMethod(base, swizzled)
        else {
            os_log(
                "Could not resolve %{public}@ / %{public}@ on UIWindow — swizzle skipped",
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

    // MARK: Emission entry point

    #if canImport(UIKit) && os(iOS)
    /// Called from the swizzled `UIWindow.sendEvent(_:)` after the
    /// original UIKit implementation has run. Walks the event's
    /// touches and emits at most one `user.interaction` per touch that
    /// has reached `.ended` (a completed tap). Other phases are
    /// ignored — `.began` would double-fire and `.cancelled` /
    /// `.moved` shouldn't count as interactions.
    static func handleSendEvent(_ event: UIEvent) {
        // Non-touch events (motion, remote, presses) are not taps.
        guard event.type == .touches else { return }
        guard let touches = event.allTouches, !touches.isEmpty else { return }

        let screen = UIViewControllerCapture.currentPreviousScreen()
        let recorder = Recorder.shared
        guard recorder.isEnabled else { return }

        for touch in touches where touch.phase == .ended {
            guard let hitView = touch.view else { continue }
            guard let attrs = decideEmission(for: hitView, currentScreen: screen) else {
                continue
            }
            recorder.recordEvent(name: "user.interaction", attributes: attrs)
        }
    }
    #endif

    // MARK: Decision core (pure, testable)

    #if canImport(UIKit) && os(iOS)
    /// Build the `user.interaction` attribute bag for a tap that
    /// landed on `hitView`, or return `nil` when the tap should be
    /// silently dropped (secure-entry field somewhere in the
    /// responder chain).
    ///
    /// This is the single pure entry point the unit tests exercise.
    /// Synthesising a real `UIEvent` / `UITouch` from XCTest is not
    /// possible, so the swizzle wrapper above is intentionally thin
    /// and forwards into this function once a hit view is in hand.
    static func decideEmission(
        for hitView: UIView,
        currentScreen: String?
    ) -> [String: AttributeValue]? {
        // 1. Privacy: any secure-entry field in the responder chain
        //    means we drop the event. Walk every link, not just the
        //    immediate view — subviews and accessory views of a
        //    secure field are also off-limits.
        if responderChainContainsSecureField(startingAt: hitView) {
            return nil
        }

        // 2. Resolve the most meaningful target by walking the
        //    superview chain. Controls and cells beat raw leaf views.
        let target = resolveTarget(from: hitView)

        // 3. Build the bag — SDK-owned keys only.
        var attrs: [String: AttributeValue] = [
            "interaction.kind": .string("tap"),
            "interaction.target": .string(String(reflecting: type(of: target)))
        ]
        if let id = resolveTargetIdentifier(target) {
            attrs["interaction.target_id"] = .string(id)
        }
        if let screen = currentScreen, !screen.isEmpty {
            attrs["interaction.screen"] = .string(screen)
        }
        return attrs
    }

    /// Walk the responder chain from `view` upward. Returns `true`
    /// when any `UITextField` link in the chain has
    /// `isSecureTextEntry == true`. Never reads `.text`.
    static func responderChainContainsSecureField(startingAt view: UIView) -> Bool {
        var responder: UIResponder? = view
        while let current = responder {
            if let textField = current as? UITextField, textField.isSecureTextEntry {
                return true
            }
            responder = current.next
        }
        return false
    }

    /// Walk the superview chain to find the most meaningful target.
    /// Order: `UIControl` (button, switch, slider, segmented control)
    /// → table-view cell → collection-view cell → fall back to the
    /// hit view itself.
    static func resolveTarget(from hitView: UIView) -> UIView {
        var current: UIView? = hitView
        var cellFallback: UIView?
        while let view = current {
            if view is UIControl {
                return view
            }
            if view is UITableViewCell || view is UICollectionViewCell {
                // Remember the cell, but keep walking in case there's
                // a UIControl nested above it (e.g. a swipe-action
                // accessory). Controls still win.
                if cellFallback == nil {
                    cellFallback = view
                }
            }
            current = view.superview
        }
        return cellFallback ?? hitView
    }

    /// Resolve the human-readable identifier for the target view.
    /// Preference order:
    ///
    /// 1. `accessibilityIdentifier` when non-empty — the stable, test-
    ///    friendly identity that survives renames.
    /// 2. `UIButton.currentTitle` (or `title(for: .normal)`) when the
    ///    target is a button without an a11y identifier.
    ///
    /// Returns `nil` when neither is available; the caller omits the
    /// `interaction.target_id` key in that case rather than emitting
    /// an empty string.
    static func resolveTargetIdentifier(_ target: UIView) -> String? {
        if let aid = target.accessibilityIdentifier, !aid.isEmpty {
            return aid
        }
        if let button = target as? UIButton {
            if let current = button.currentTitle, !current.isEmpty {
                return current
            }
            if let normal = button.title(for: .normal), !normal.isEmpty {
                return normal
            }
        }
        return nil
    }
    #endif

    // MARK: Test-only helpers

    #if DEBUG
    /// Mark the swizzle as "not installed" so tests that want to
    /// verify the opt-out path can drive `EdgeRum.start()` and assert
    /// `isInstalled` stayed `false`. The IMP table is not touched —
    /// the swap, once performed, cannot be safely undone.
    public static func _resetInstallFlagForTesting() {
        os_unfair_lock_lock(installLock)
        _installed = false
        os_unfair_lock_unlock(installLock)
    }
    #endif
}

// MARK: - UIKit swizzle entry point
//
// Defined as an Objective-C-visible method on `UIWindow` so the runtime
// can resolve it by selector for the IMP exchange. After
// `method_exchangeImplementations` runs, the selector `sendEvent:`
// resolves to the body below, and `edgerum_swizzled_sendEvent:`
// resolves to UIKit's original implementation — that's why the body
// calls `edgerum_swizzled_sendEvent(event)` first.

#if canImport(UIKit) && os(iOS)
internal extension UIWindow {
    @objc
    func edgerum_swizzled_sendEvent(_ event: UIEvent) {
        // After the IMP swap this calls UIKit's original sendEvent.
        edgerum_swizzled_sendEvent(event)
        InteractionCapture.handleSendEvent(event)
    }
}
#endif
