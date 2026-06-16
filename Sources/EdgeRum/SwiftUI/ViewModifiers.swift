// Sources/EdgeRum/SwiftUI/ViewModifiers.swift
//
// Refs: PLAN-iOS.md §3.2, §F2/T2.6, §6.2, §F7; CLAUDE.md "SwiftUI conventions".
//
// The two public modifiers emit existing event names (`navigation`,
// `screen.duration`, `user.interaction`) with a `kind` discriminator
// so the backend can tell SwiftUI traffic apart from UIKit traffic
// without a new event name in the allowlist.
//
// The disappear path routes through `recordPerformance` and the
// attribute schema mirrors the F6 UIKit emitter (`screen.name`,
// `screen.kind`, `screen.duration_ms`, `value`) so the backend's
// `screen.duration` metric dispatcher sees an identical shape for
// UIKit and SwiftUI screens.
//

#if canImport(SwiftUI)
import SwiftUI
#if canImport(EdgeRumCore)
// SwiftPM: `EdgeRumCore` is a separate internal target. CocoaPods
// rolls every subspec into one `EdgeRum` module — the same types
// are already visible without an import.
import EdgeRumCore
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
    /// first, then SDK-owned keys (`navigation.screen`,
    /// `navigation.kind`, `navigation.type`) overwrite. A host
    /// passing `"navigation.kind": "host-supplied"` therefore cannot
    /// hide the discriminator from the backend.
    internal static func emitScreenAppear(
        name: String,
        attributes: [String: AttributeValue]?,
        recorder: Recording = Recorder.shared,
        clock: Clock = Recorder.shared.clock,
        startStore: SwiftUIScreenStartStore = .shared
    ) {
        startStore.recordStart(name: name, at: clock.now)
        var payload: [String: AttributeValue] = attributes ?? [:]
        // SDK-owned keys win on conflict — apply last.
        payload["navigation.screen"] = .string(name)
        payload["navigation.kind"] = .string("swiftui")
        payload["navigation.type"] = .string("viewDidAppear")
        recorder.recordEvent(name: "navigation", attributes: payload)
    }

    /// `.edgeRumScreen` on-disappear → one `screen.duration` metric.
    ///
    /// Routed through `recordPerformance` (metric, not event) with
    /// the F6 UIKit attribute schema so the backend's
    /// `screen.duration` dispatcher handles UIKit and SwiftUI rows
    /// identically. If no matching `emitScreenAppear` was seen for
    /// `name`, the call is a silent no-op — matches the UIKit
    /// "no paired appear → skip" behaviour.
    internal static func emitScreenDisappear(
        name: String,
        attributes: [String: AttributeValue]?,
        recorder: Recording = Recorder.shared,
        clock: Clock = Recorder.shared.clock,
        startStore: SwiftUIScreenStartStore = .shared
    ) {
        guard let dwell = startStore.consumeDwell(name: name, now: clock.now) else {
            return
        }
        var payload: [String: AttributeValue] = attributes ?? [:]
        // SDK-owned keys win on conflict — apply last.
        payload["screen.name"] = .string(name)
        payload["screen.kind"] = .string("swiftui")
        payload["screen.duration_ms"] = .int(dwell.ms)
        payload["value"] = .double(dwell.seconds)
        recorder.recordPerformance(name: "screen.duration", attributes: payload)
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
        var payload: [String: AttributeValue] = attributes ?? [:]
        // SDK-owned keys win on conflict — apply last.
        payload["interaction.kind"] = .string("tap")
        payload["interaction.name"] = .string(name)
        recorder.recordEvent(name: "user.interaction", attributes: payload)
    }
}

/// Pairs a screen name with its `onAppear` timestamp so the matching
/// `onDisappear` emit can carry the dwell as both an `Int` ms count
/// and a `Double` seconds count (mirrors F6 UIKit). Backed by an
/// `NSLock` so concurrent screens don't trip each other.
internal final class SwiftUIScreenStartStore: @unchecked Sendable {
    internal static let shared = SwiftUIScreenStartStore()

    /// Result of `consumeDwell` — both representations the wire
    /// schema needs, computed from the same `timeIntervalSince`
    /// call so they cannot disagree.
    internal struct Dwell: Equatable {
        internal let seconds: Double
        internal let ms: Int
    }

    private let lock = NSLock()
    private var starts: [String: Date] = [:]

    internal init() {}

    internal func recordStart(name: String, at date: Date) {
        lock.lock()
        starts[name] = date
        lock.unlock()
    }

    /// Pop the start timestamp for `name` and return the dwell. Returns
    /// `nil` when no paired `recordStart` is present — the caller is
    /// expected to skip the emit in that case.
    internal func consumeDwell(name: String, now: Date) -> Dwell? {
        lock.lock()
        let start = starts.removeValue(forKey: name)
        lock.unlock()
        guard let start else { return nil }
        let raw = now.timeIntervalSince(start)
        let safe = max(0.0, raw)
        return Dwell(seconds: safe, ms: Int((safe * 1000.0).rounded()))
    }

    /// Backwards-compatible helper for callers that only need ms.
    internal func consumeDwellMs(name: String, now: Date) -> Int? {
        consumeDwell(name: name, now: now)?.ms
    }

    internal func reset() {
        lock.lock()
        starts.removeAll()
        lock.unlock()
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

    /// Record screen-enter and screen-exit performance data for a
    /// SwiftUI view.
    ///
    /// Emits a `navigation` event on `.onAppear` and a
    /// `screen.duration` performance entry on `.onDisappear`, both
    /// tagged with `"swiftui"` so the backend can distinguish
    /// SwiftUI traffic from UIKit.
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
                SwiftUIEmitter.emitScreenDisappear(name: name, attributes: attributes)
            }
    }

    /// Record a tap on a SwiftUI view without intercepting it.
    ///
    /// Attached via `.simultaneousGesture(TapGesture())` so the host
    /// app's own gestures continue to fire normally.
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
