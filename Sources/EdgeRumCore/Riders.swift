// Sources/EdgeRumCore/Riders.swift
//
// F28 / #215 — RUM coverage tranche 3 ("Riders + screen attribution").
//
// The latest-wins box behind the per-event riders (W3 mechanism, W10 /
// W17 consumers):
//
//   screen.name (+ .truncated)  — written by UIKit `viewDidAppear`,
//                                 `.edgeRumScreen` and `trackScreen`
//   device.orientation          — interface orientation, ContextObservers
//   app.state                   — UIApplication.State, ContextObservers
//   action.id                   — top of the open-action stack (F36),
//                                 written by `Actions` on start / end
//
// Writers set a value on change; `Recorder.enqueue` stamps the current
// values into each event's own attributes (absent keys only, so an
// event's own value wins). Each change also schedules — at most one
// pending at a time — a write of the whole box into the sidecar's
// volatile zone on a serial queue, so a replayed native crash carries
// the crash-time values. Best-effort: a crash inside that drain window
// lands without them. `enqueue` never writes the sidecar (O1).
//
// F37 — beside the box sits the screen-ready token (screen + appear
// time): set on each appear, consumed by the first `markScreenReady()`
// (`screen_ready`, `ready`). `disappearScreen` drops a pending token of
// that screen — as `abandoned` if it was marked earlier in this process
// (ADR-028). Another screen's appear replaces it silently.
//
// Refs: docs/specs/rum-coverage-roadmap.md § Tranche 3;
//       docs/catalogue/ios-data-catalogue.md §5.2, §5.16.

import Foundation

public final class Riders: @unchecked Sendable {

    public static let shared = Riders()

    /// `screen.name` cap in UTF-8 bytes (W6's label constant).
    public static let screenNameCapBytes = 128

    private struct Screen: Equatable {
        let name: String
        let truncated: Int
    }

    // ponytail: one os_unfair_lock read per enqueue (W17's costing), not a
    // true lock-free atomic — Swift's `Atomic` needs iOS 18. Revisit if
    // the read ever shows up in a profile.
    private let lockPtr: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()
    private let queue = DispatchQueue(label: "com.edge.rum.riders", qos: .utility)
    private var current: Screen?
    // ponytail: one-level restore — sheet-on-sheet goes stale. Upgrade to
    // an ordered stack (W5) if nested modals turn out to matter.
    private var replaced: Screen?
    /// Last screen passed to `enterScreen` — the `navigation` from-edge,
    /// untouched by restores.
    private var lastEntered: String?
    private var orientation: String?
    private var appState: String?
    private var actionId: String?
    private var sidecar: SessionSidecarWriting?
    private var persistPending = false
    private var pending: (screen: Screen, at: Date)?
    // ponytail: grows with distinct screen names this process — the
    // 128 B-capped names a host's screens produce, not user input.
    private var marked: Set<String> = []
    private let clock: Clock
    private let emitReady: @Sendable ([String: AttributeValue]) -> Void

    /// `emitReady` receives each `screen_ready` row, outside the lock.
    public init(
        clock: Clock = SystemClock(),
        emitReady: @escaping @Sendable ([String: AttributeValue]) -> Void = {
            Recorder.shared.recordPerformance(name: "screen_ready", attributes: $0)
        }
    ) {
        self.clock = clock
        self.emitReady = emitReady
    }

    deinit { lockPtr.deallocate() }

    private func lock() { os_unfair_lock_lock(lockPtr) }
    private func unlock() { os_unfair_lock_unlock(lockPtr) }

    // MARK: Writers

    /// The screen now showing. Ignored when empty; the screen it replaces
    /// is kept for one-level `leaveScreen` restore. Returns the screen
    /// last entered before this one (the `navigation` from-edge).
    @discardableResult
    public func enterScreen(_ name: String) -> String? {
        guard !name.isEmpty else { return nil }
        let screen = Self.cap(name)
        lock(); defer { unlock() }
        // A re-fired appear of the same screen keeps its anchor.
        if pending?.screen != screen { pending = (screen, clock.now) }
        let previous = lastEntered
        lastEntered = screen.name
        guard screen != current else { return previous }
        replaced = current
        current = screen
        schedulePersistLocked()
        return previous
    }

    /// `name` is going away (sheet dismissed, view popped). Restores the
    /// screen it replaced, if it is still the current one.
    public func leaveScreen(_ name: String) {
        let screen = Self.cap(name)
        lock(); defer { unlock() }
        guard screen == current, let restored = replaced else { return }
        current = restored
        replaced = nil
        schedulePersistLocked()
    }

    public func setOrientation(_ value: String?) {
        lock(); defer { unlock() }
        guard value != orientation else { return }
        orientation = value
        schedulePersistLocked()
    }

    public func setAppState(_ value: String?) {
        lock(); defer { unlock() }
        guard value != appState else { return }
        appState = value
        schedulePersistLocked()
    }

    /// Top of the open-action stack (F36); nil when none is open.
    public func setActionId(_ value: String?) {
        lock(); defer { unlock() }
        guard value != actionId else { return }
        actionId = value
        schedulePersistLocked()
    }

    /// Route volatile writes to `sidecar` and persist the current box.
    public func attach(sidecar: SessionSidecarWriting?) {
        lock(); defer { unlock() }
        self.sidecar = sidecar
        schedulePersistLocked()
    }

    /// The host says the current screen is ready. Consumes the appear
    /// token; `false` (nothing emitted) once it is consumed or gone.
    @discardableResult
    public func markScreenReady() -> Bool {
        lock()
        guard let token = pending else { unlock(); return false }
        pending = nil
        marked.insert(token.screen.name)
        let now = clock.now
        unlock()
        emitReady(Self.readyRow(token.screen, from: token.at, to: now, outcome: "ready"))
        return true
    }

    /// `name` is disappearing (every UIKit `viewWillDisappear`, SwiftUI
    /// `onDisappear`). Drops its pending token; a screen marked before
    /// gets an `abandoned` row with the censored time-to-leave. Call
    /// before `leaveScreen`, so the row's riders are still this screen's.
    public func disappearScreen(_ name: String) {
        let screen = Self.cap(name)
        lock()
        guard let token = pending, token.screen == screen else { unlock(); return }
        pending = nil
        let wasMarkedBefore = marked.contains(token.screen.name)
        let now = clock.now
        unlock()
        // Outside the lock: the Recorder's enqueue reads this box.
        if wasMarkedBefore {
            emitReady(Self.readyRow(token.screen, from: token.at, to: now, outcome: "abandoned"))
        }
    }

    private static func readyRow(_ screen: Screen, from: Date, to: Date, outcome: String) -> [String: AttributeValue] {
        var row: [String: AttributeValue] = [
            "screen.name": .string(screen.name),
            "screen.ready_outcome": .string(outcome),
            "value": .double((to.timeIntervalSince(from) * 1000).rounded())
        ]
        if screen.truncated > 0 { row["screen.name.truncated"] = .int(screen.truncated) }
        return row
    }

    // MARK: Readers

    public var currentScreen: String? {
        lock(); defer { unlock() }
        return current?.name
    }

    /// Current `app.state` (`SamplingGate` input).
    public var currentAppState: String? {
        lock(); defer { unlock() }
        return appState
    }

    /// The rider attributes as of now. Absent keys are never sent empty.
    public func values() -> [String: AttributeValue] {
        lock(); defer { unlock() }
        return valuesLocked()
    }

    /// `bag` plus every rider it does not already carry.
    public func stamp(_ bag: AttributeBag) -> AttributeBag {
        var out = bag
        for (key, value) in values() where out[key] == nil {
            out.set(key, value)
        }
        return out
    }

    // MARK: Internals

    private func valuesLocked() -> [String: AttributeValue] {
        var out: [String: AttributeValue] = [:]
        if let current {
            out["screen.name"] = .string(current.name)
            if current.truncated > 0 { out["screen.name.truncated"] = .int(current.truncated) }
        }
        if let orientation { out["device.orientation"] = .string(orientation) }
        if let appState { out["app.state"] = .string(appState) }
        if let actionId { out["action.id"] = .string(actionId) }
        return out
    }

    /// Caller holds `lock`. A burst of changes collapses to one write of
    /// the latest box — no timer, no idle wakeups.
    private func schedulePersistLocked() {
        guard sidecar != nil, !persistPending else { return }
        persistPending = true
        queue.async { [self] in
            lock()
            persistPending = false
            let snapshot = valuesLocked()
            let sink = sidecar
            unlock()
            sink?.writeVolatile(snapshot)
        }
    }

    private static func cap(_ name: String) -> Screen {
        let (out, cut) = capUTF8(name, maxBytes: screenNameCapBytes)
        return Screen(name: out, truncated: cut)
    }

    // MARK: Test hooks

    #if DEBUG
    /// Block until any scheduled volatile write has landed.
    public func _drainForTesting() {
        queue.sync {}
    }

    public func _resetForTesting() {
        lock(); defer { unlock() }
        current = nil
        replaced = nil
        lastEntered = nil
        orientation = nil
        appState = nil
        actionId = nil
        sidecar = nil
        pending = nil
        marked = []
    }
    #endif
}

/// Cap `s` at `maxBytes` UTF-8 bytes on a character boundary; returns
/// the kept prefix and the number of bytes removed.
func capUTF8(_ s: String, maxBytes: Int) -> (String, Int) {
    guard s.utf8.count > maxBytes else { return (s, 0) }
    var out = ""
    var bytes = 0
    for ch in s {
        let n = ch.utf8.count
        if bytes + n > maxBytes { break }
        out.append(ch)
        bytes += n
    }
    return (out, s.utf8.count - bytes)
}
