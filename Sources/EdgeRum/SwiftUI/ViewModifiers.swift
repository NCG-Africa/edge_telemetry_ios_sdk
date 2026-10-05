// Sources/EdgeRum/SwiftUI/ViewModifiers.swift
//
// Refs: PLAN-iOS.md §3.2, §F2/T2.6, §6.2, §F7; CLAUDE.md "SwiftUI conventions".
//
// The two public modifiers emit existing event names (`navigation`,
// `user.interaction`) with a `kind` discriminator so the backend can
// tell SwiftUI traffic apart from UIKit traffic without a new event
// name in the allowlist.
//

#if canImport(SwiftUI)
import SwiftUI
#if canImport(EdgeRumCore)
// SwiftPM: `EdgeRumCore` is a separate internal target. CocoaPods
// rolls every subspec into one `EdgeRum` module — the same types
// are already visible without an import.
import EdgeRumCore
#endif
#if canImport(EdgeRumCapture)
import EdgeRumCapture
#endif

// MARK: - Internals (testable in isolation)

/// Pure closures the modifiers attach to `onAppear`, `onDisappear`,
/// and the simultaneous tap gesture. Factored out so unit tests can
/// invoke them directly without instantiating SwiftUI's rendering
/// machinery.
internal enum SwiftUIEmitter {

    /// `.edgeRumScreen` on-appear → one `navigation` event.
    ///
    /// Attribute precedence: caller-supplied attributes are applied
    /// first (minus reserved SDK prefixes), then SDK-owned keys
    /// (`navigation.screen`, `navigation.kind`) overwrite.
    internal static func emitScreenAppear(
        name: String,
        attributes: [String: AttributeValue]?,
        recorder: Recording = Recorder.shared,
        riders: Riders = .shared
    ) {
        // Box first, so this event's `screen.name` is the screen entered.
        riders.enterScreen(name)
        FrameSampler.noteMotion()  // F30: screen transition
        var payload = HostAttributes.sanitize(attributes, debug: recorder.debug)
        // SDK-owned keys win on conflict — apply last.
        payload["navigation.screen"] = .string(name)
        payload["navigation.kind"] = .string("swiftui")
        recorder.recordEvent(name: "navigation", attributes: payload)
    }

    /// `.edgeRumScreen` on-disappear → no `navigation`. Restores the
    /// presenter in the screen box: sheet dismissal does not re-fire
    /// the presenter's `onAppear`. May emit an `abandoned`
    /// `screen_ready` row (F37).
    internal static func emitScreenDisappear(name: String, riders: Riders = .shared) {
        riders.leaveScreen(name)
    }

    /// `.edgeRumTrackTap` → one `user.interaction` event.
    ///
    /// Attribute precedence is the same as `emitScreenAppear`:
    /// caller-supplied attributes first, SDK-owned `interaction.*`
    /// keys last so the discriminator cannot be overwritten.
    internal static func emitTap(
        name: String,
        attributes: [String: AttributeValue]?,
        recorder: Recording = Recorder.shared
    ) {
        var payload = HostAttributes.sanitize(attributes, debug: recorder.debug)
        // SDK-owned keys win on conflict — apply last.
        payload["interaction.kind"] = .string("tap")
        payload["interaction.name"] = .string(name)
        payload["interaction.name_source"] = .string("host")
        recorder.recordEvent(name: "user.interaction", attributes: payload)
    }
}

// MARK: - Public modifiers

// `@available(macOS 10.15, *)` is only present so `swift test` runs
// on the macOS host (the package's platforms list declares iOS only,
// so the macOS deployment defaults to a version older than SwiftUI).
// iOS consumers see no guard at the iOS 14 floor — SwiftUI is already
// available everywhere this package builds for iOS.
@available(macOS 10.15, *)
public extension View {

    /// Record a screen entry for a SwiftUI view.
    ///
    /// Emits a `navigation` event on `.onAppear`, tagged with
    /// `"swiftui"` so the backend can distinguish SwiftUI traffic from
    /// UIKit. Time on screen is derived from consecutive entries.
    /// Attribute keys under a reserved SDK prefix (such as `device.`
    /// or `user.`) are dropped.
    ///
    /// ```swift
    /// CheckoutView()
    ///     .edgeRumScreen("Checkout", attributes: ["funnel.step": 3])
    /// ```
    func edgeRumScreen(
        _ name: String,
        attributes: [String: AttributeValue]? = nil
    ) -> some View {
        self
            .onAppear {
                SwiftUIEmitter.emitScreenAppear(name: name, attributes: attributes)
            }
            .onDisappear {
                SwiftUIEmitter.emitScreenDisappear(name: name)
            }
    }

    /// Record a tap on a SwiftUI view without intercepting it.
    ///
    /// Attached via `.simultaneousGesture(TapGesture())` so the host
    /// app's own gestures continue to fire normally.
    /// Attribute keys under a reserved SDK prefix are dropped.
    ///
    /// ```swift
    /// Button("Buy", action: buy)
    ///     .edgeRumTrackTap("buy_button", attributes: ["product.id": sku])
    /// ```
    func edgeRumTrackTap(
        _ name: String,
        attributes: [String: AttributeValue]? = nil
    ) -> some View {
        self.simultaneousGesture(
            TapGesture().onEnded {
                SwiftUIEmitter.emitTap(name: name, attributes: attributes)
            }
        )
    }
}

#endif
