// Sources/EdgeRum/SwiftUI/ViewModifiers.swift
//
// Refs: PLAN-iOS.md §3.2, §F2/T2.6, §6.2; CLAUDE.md "SwiftUI conventions".
//
// The two public modifiers emit existing event names (`navigation`,
// `screen.duration`, `user.interaction`) with a `kind` discriminator
// so the backend can tell SwiftUI traffic apart from UIKit traffic
// without a new event name in the allowlist.
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
    internal static func emitScreenAppear(
        name: String,
        attributes: [String: AttributeValue]?,
        recorder: Recording = Recorder.shared,
        clock: Clock = Recorder.shared.clock,
        startStore: SwiftUIScreenStartStore = .shared
    ) {
        startStore.recordStart(name: name, at: clock.now)
        var payload: [String: AttributeValue] = attributes ?? [:]
        payload["navigation.kind"] = .string("swiftui")
        payload["navigation.name"] = .string(name)
        recorder.recordEvent(name: "navigation", attributes: payload)
    }

    /// `.edgeRumScreen` on-disappear → one `screen.duration` event.
    internal static func emitScreenDisappear(
        name: String,
        attributes: [String: AttributeValue]?,
        recorder: Recording = Recorder.shared,
        clock: Clock = Recorder.shared.clock,
        startStore: SwiftUIScreenStartStore = .shared
    ) {
        let dwellMs = startStore.consumeDwellMs(name: name, now: clock.now)
        var payload: [String: AttributeValue] = attributes ?? [:]
        payload["navigation.kind"] = .string("swiftui")
        payload["navigation.name"] = .string(name)
        if let dwellMs {
            payload["duration_ms"] = .int(dwellMs)
        }
        recorder.recordEvent(name: "screen.duration", attributes: payload)
    }

    /// `.edgeRumTrackTap` → one `user.interaction` event.
    internal static func emitTap(
        name: String,
        attributes: [String: AttributeValue]?,
        recorder: Recording = Recorder.shared
    ) {
        var payload: [String: AttributeValue] = attributes ?? [:]
        payload["interaction.kind"] = .string("tap")
        payload["interaction.name"] = .string(name)
        recorder.recordEvent(name: "user.interaction", attributes: payload)
    }
}

/// Pairs a screen name with its `onAppear` timestamp so the matching
/// `onDisappear` event can carry the dwell in `duration_ms`. Backed
/// by an `NSLock` so concurrent screens don't trip each other.
internal final class SwiftUIScreenStartStore: @unchecked Sendable {
    internal static let shared = SwiftUIScreenStartStore()

    private let lock = NSLock()
    private var starts: [String: Date] = [:]

    internal init() {}

    internal func recordStart(name: String, at date: Date) {
        lock.lock()
        starts[name] = date
        lock.unlock()
    }

    internal func consumeDwellMs(name: String, now: Date) -> Int? {
        lock.lock()
        let start = starts.removeValue(forKey: name)
        lock.unlock()
        guard let start else { return nil }
        return Int((now.timeIntervalSince(start) * 1000.0).rounded())
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

    /// Record screen-enter and screen-exit events for a SwiftUI view.
    ///
    /// Emits `navigation` on `.onAppear` and `screen.duration` on
    /// `.onDisappear`, both tagged with `"navigation.kind": "swiftui"`
    /// so the backend can distinguish SwiftUI traffic from UIKit.
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
