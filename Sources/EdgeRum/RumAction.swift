// Sources/EdgeRum/RumAction.swift
//
// F36 / #223 — the handle `EdgeRum.startAction(_:)` returns. The
// `settled`-lock idempotency is `RumTimer`'s, verbatim; the stack,
// rider and persistence live in `EdgeRumCore.Actions`.
//
// Refs: docs/specs/rum-coverage-roadmap.md § Tranche 12; ADR-027.
//

import Foundation
#if canImport(EdgeRumCore)
// SwiftPM: `EdgeRumCore` is a separate internal target. CocoaPods
// rolls every subspec into one `EdgeRum` module — the same types
// are already visible without an import.
import EdgeRumCore
#endif

/// Something the user is trying to do — a checkout, a sign-in — from
/// start to finish, across screens and app switches.
///
/// Obtain one with `EdgeRum.startAction(_:)`, then call `complete()` or
/// `fail(reason:)` exactly once; second calls are no-ops. While the
/// action is open, every event recorded carries its id. An action still
/// open when its session ends, when the app process dies, or ten
/// minutes after it started is recorded as abandoned.
///
/// ```swift
/// let checkout = EdgeRum.startAction("checkout")
/// submitOrder { result in
///     switch result {
///     case .success: checkout.complete()
///     case .failure(let error): checkout.fail(reason: error.localizedDescription)
///     }
/// }
/// ```
public final class RumAction: @unchecked Sendable {

    private let id: String?
    private let recorder: Recording
    private let actions: Actions

    private let lock = NSLock()
    private var settled: Bool = false

    internal init(
        name: String,
        recorder: Recording,
        actions: Actions,
        live: Bool,
        ceiling: TimeInterval = Actions.ceiling
    ) {
        self.recorder = recorder
        self.actions = actions
        guard live else {
            self.id = nil
            self.settled = true
            return
        }
        // A rotation due now abandons the open stack before this action joins it.
        recorder.touchSession()
        let started = actions.start(name: name, at: recorder.clock.now)
        self.id = started.id
        recorder.recordEvent(name: "action.started", attributes: started.attributes)
        // Leak guard; holds the handle until it fires, a no-op once settled.
        DispatchQueue.global(qos: .utility).asyncAfter(wallDeadline: .now() + ceiling) { [self] in
            expire()
        }
    }

    /// Record the action as completed. Second and subsequent calls are no-ops.
    public func complete() {
        finish(.completed)
    }

    /// Record the action as failed. `reason` is sent as free text —
    /// keep personal data out of it. Second and subsequent calls are
    /// no-ops.
    public func fail(reason: String? = nil) {
        finish(.failed, errorMessage: reason)
    }

    /// The ten-minute ceiling.
    internal func expire() {
        finish(.abandoned, abandonReason: .timeout)
    }

    private func finish(
        _ outcome: Actions.Outcome,
        abandonReason: Actions.AbandonReason? = nil,
        errorMessage: String? = nil
    ) {
        lock.lock()
        guard !settled else {
            lock.unlock()
            return
        }
        settled = true
        lock.unlock()

        // A rotation due now closes it as `rotation` first; then `end` is nil.
        recorder.touchSession()
        guard let id, let attrs = actions.end(
            id: id, outcome: outcome, abandonReason: abandonReason, errorMessage: errorMessage
        ) else { return }
        recorder.recordEvent(name: "action.ended", attributes: attrs)
    }
}
