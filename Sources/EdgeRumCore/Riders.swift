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
//
// Writers set a value on change; `Recorder.enqueue` stamps the current
// values into each event's own attributes (absent keys only, so an
// event's own value wins). Each change also schedules — at most one
// pending at a time — a write of the whole box into the sidecar's
// volatile zone on a serial queue, so a replayed native crash carries
// the crash-time values. Best-effort: a crash inside that drain window
// lands without them. `enqueue` never writes the sidecar (O1).
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

    // ponytail: one NSLock around a few words; swap for an atomic if the
    // enqueue read ever shows up in a profile.
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.edge.rum.riders", qos: .utility)
    private var current: Screen?
    // ponytail: one-level restore — sheet-on-sheet goes stale. Upgrade to
    // an ordered stack (W5) if nested modals turn out to matter.
    private var replaced: Screen?
    private var orientation: String?
    private var appState: String?
    private var sidecar: SessionSidecarWriting?
    private var persistPending = false

    public init() {}

    // MARK: Writers

    /// The screen now showing. Ignored when empty or unchanged; the
    /// screen it replaces is kept for one-level `leaveScreen` restore.
    public func enterScreen(_ name: String) {
        guard !name.isEmpty else { return }
        let screen = Self.cap(name)
        lock.lock(); defer { lock.unlock() }
        guard screen != current else { return }
        replaced = current
        current = screen
        schedulePersistLocked()
    }

    /// `name` is going away (sheet dismissed, view popped). Restores the
    /// screen it replaced, if it is still the current one.
    public func leaveScreen(_ name: String) {
        let screen = Self.cap(name)
        lock.lock(); defer { lock.unlock() }
        guard screen == current, let restored = replaced else { return }
        current = restored
        replaced = nil
        schedulePersistLocked()
    }

    public func setOrientation(_ value: String?) {
        lock.lock(); defer { lock.unlock() }
        guard value != orientation else { return }
        orientation = value
        schedulePersistLocked()
    }

    public func setAppState(_ value: String?) {
        lock.lock(); defer { lock.unlock() }
        guard value != appState else { return }
        appState = value
        schedulePersistLocked()
    }

    /// Route volatile writes to `sidecar` and persist the current box.
    public func attach(sidecar: SessionSidecarWriting?) {
        lock.lock(); defer { lock.unlock() }
        self.sidecar = sidecar
        schedulePersistLocked()
    }

    // MARK: Readers

    public var currentScreen: String? {
        lock.lock(); defer { lock.unlock() }
        return current?.name
    }

    /// The rider attributes as of now. Absent keys are never sent empty.
    public func values() -> [String: AttributeValue] {
        lock.lock(); defer { lock.unlock() }
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
        return out
    }

    /// Caller holds `lock`. A burst of changes collapses to one write of
    /// the latest box — no timer, no idle wakeups.
    private func schedulePersistLocked() {
        guard sidecar != nil, !persistPending else { return }
        persistPending = true
        queue.async { [self] in
            lock.lock()
            persistPending = false
            let snapshot = valuesLocked()
            let sink = sidecar
            lock.unlock()
            sink?.writeVolatile(snapshot)
        }
    }

    /// Cap at `screenNameCapBytes` on a character boundary; `truncated`
    /// is the number of bytes removed.
    private static func cap(_ name: String) -> Screen {
        guard name.utf8.count > screenNameCapBytes else { return Screen(name: name, truncated: 0) }
        var out = ""
        var bytes = 0
        for ch in name {
            let n = ch.utf8.count
            if bytes + n > screenNameCapBytes { break }
            out.append(ch)
            bytes += n
        }
        return Screen(name: out, truncated: name.utf8.count - bytes)
    }

    // MARK: Test hooks

    /// Block until any scheduled volatile write has landed.
    public func _drainForTesting() {
        queue.sync {}
    }

    public func _resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        current = nil
        replaced = nil
        orientation = nil
        appState = nil
        sidecar = nil
    }
}
