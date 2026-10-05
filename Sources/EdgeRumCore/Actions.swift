// Sources/EdgeRumCore/Actions.swift
//
// F36 / #223 — RUM coverage tranche 12 ("Action lifecycle", W5).
//
// The ordered stack of open host actions behind `EdgeRum.startAction`.
// Mutated only on start / end / background transitions (rare), under a
// plain lock; the top's id is published to the `Riders` box, so the
// per-event read never takes this lock.
//
//   - `start` mints `action.id`, notes `action.parent_id` (the top when
//     another action is open) and buckets names past the per-session
//     cap into `_other` (`action.name.dropped` = distinct names lost).
//   - `end` removes by identity, so out-of-order completion lets the
//     rider fall back to whatever remains.
//   - `abandonAll` closes every open action (session rotation).
//   - Backgrounding is recorded (`action.background_count`,
//     `action.background_duration_ms`), never judged.
//
// Durability: the stack is persisted on change (coalesced, best-effort)
// to `Library/Caches/edge-rum/open-actions.json`; the next launch reads
// and deletes it via `takePrior` and closes each as `abandoned` /
// `process_death`. A crash inside the coalescing window loses the
// latest change.
//
// Refs: docs/specs/rum-coverage-roadmap.md § Tranche 12;
//       docs/catalogue/ios-data-catalogue.md §5.2, §5.14; ADR-027.

import Foundation

public final class Actions: @unchecked Sendable {

    public static let shared = Actions()

    /// Distinct `action.name` values kept per session; later names go
    /// to `_other`.
    public static let nameCap = 50
    public static let overflowName = "_other"
    /// Leak-guard ceiling the `RumAction` handle schedules at start.
    public static let ceiling: TimeInterval = 600

    public enum Outcome: String, Sendable {
        case completed, failed, abandoned
    }

    /// `action.abandon_reason` — the only three points `abandoned` fires.
    public enum AbandonReason: String, Sendable {
        case rotation, processDeath = "process_death", timeout
    }

    /// One open action; also the on-disk record.
    struct Open: Codable, Equatable {
        let id: String
        let name: String
        let parentId: String?
        var backgroundCount = 0
        var backgroundMs = 0
        /// Monotonic ns when the current background hop began. Not persisted.
        var backgroundSinceNs: UInt64?

        enum CodingKeys: String, CodingKey {
            case id, name, parentId, backgroundCount, backgroundMs
        }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.edge.rum.actions", qos: .utility)
    private let riders: Riders
    private let monotonicNs: () -> UInt64
    private var stack: [Open] = []
    private var names: Set<String> = []
    // ponytail: remembers every overflowed name for the session so the
    // count stays distinct; unbounded only in a host that mints a fresh
    // name per action for hours. Swap for a counter if that ever matters.
    private var droppedNames: Set<String> = []
    private var backgrounded = false
    private var url: URL?
    private var persistPending = false

    public init(
        riders: Riders = .shared,
        monotonicNs: @escaping () -> UInt64 = { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }
    ) {
        self.riders = riders
        self.monotonicNs = monotonicNs
    }

    /// `<Library>/Caches/edge-rum/open-actions.json`.
    public static func defaultURL() -> URL? {
        SessionSidecar.defaultBaseDirectoryURL()?.appendingPathComponent("open-actions.json")
    }

    /// Route stack snapshots to `url`. Nil (the default) keeps them in memory only.
    public func configure(url: URL?) {
        lock.lock(); defer { lock.unlock() }
        self.url = url
    }

    // MARK: Writers

    /// Open an action. Returns its id and the `action.started` attributes.
    /// The caller touches the session first, so a rotation cannot abandon
    /// the action before `action.started` is recorded.
    public func start(name: String, at date: Date) -> (id: String, attributes: [String: AttributeValue]) {
        let id = Self.newId(at: date)
        lock.lock(); defer { lock.unlock() }
        var wireName = name
        if !names.contains(name) {
            if names.count < Self.nameCap {
                names.insert(name)
            } else {
                droppedNames.insert(name)
                wireName = Self.overflowName
            }
        }
        var open = Open(id: id, name: wireName, parentId: stack.last?.id)
        if backgrounded { open.backgroundSinceNs = monotonicNs() }
        stack.append(open)
        publishLocked()
        return (id, baseAttributesLocked(open))
    }

    /// Close `id`. Nil when it is no longer open (already ended or
    /// abandoned) — the caller then emits nothing.
    public func end(
        id: String,
        outcome: Outcome,
        abandonReason: AbandonReason? = nil,
        errorMessage: String? = nil
    ) -> [String: AttributeValue]? {
        lock.lock(); defer { lock.unlock() }
        guard let index = stack.firstIndex(where: { $0.id == id }) else { return nil }
        var open = stack.remove(at: index)
        publishLocked()
        Self.closeHop(&open, now: monotonicNs())
        var attrs = Self.endedAttributes(open, outcome: outcome, abandonReason: abandonReason, dropped: droppedNames.count)
        if let errorMessage { attrs["action.error_message"] = .string(errorMessage) }
        return attrs
    }

    /// Session rotation: every open action can no longer complete. Returns
    /// one `action.ended` bag per action, oldest first, and resets the
    /// per-session name cap.
    public func abandonAll(reason: AbandonReason) -> [[String: AttributeValue]] {
        lock.lock(); defer { lock.unlock() }
        let now = monotonicNs()
        let closed = stack.map { open -> [String: AttributeValue] in
            var open = open
            Self.closeHop(&open, now: now)
            return Self.endedAttributes(open, outcome: .abandoned, abandonReason: reason, dropped: droppedNames.count)
        }
        stack = []
        names = []
        droppedNames = []
        publishLocked()
        return closed
    }

    /// `app.state` transition. Entering `background` starts a hop on every
    /// open action; leaving it adds the hop's duration.
    public func noteAppState(_ state: String) {
        lock.lock(); defer { lock.unlock() }
        let nowBackground = state == "background"
        guard nowBackground != backgrounded else { return }
        backgrounded = nowBackground
        let now = monotonicNs()
        for i in stack.indices {
            if nowBackground {
                stack[i].backgroundCount += 1
                stack[i].backgroundSinceNs = now
            } else {
                Self.closeHop(&stack[i], now: now)
            }
        }
        schedulePersistLocked()
    }

    // MARK: Next launch

    /// Read and delete the prior launch's open actions, as `action.ended`
    /// `abandoned` / `process_death` bags. Call before this launch's
    /// `configure(url:)`.
    public static func takePrior(url: URL? = defaultURL()) -> [[String: AttributeValue]] {
        guard let url else { return [] }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url),
              let open = try? JSONDecoder().decode([Open].self, from: data) else { return [] }
        // A hop still open at death has no end to time it; only its count is kept.
        return open.map { endedAttributes($0, outcome: .abandoned, abandonReason: .processDeath, dropped: 0) }
    }

    // MARK: Internals

    /// `action_<epochMs>_<16 hex>`.
    static func newId(at date: Date) -> String {
        let epochMs = Int64(date.timeIntervalSince1970 * 1000)
        let hex = SessionManager.secureRandomBytes().prefix(8).map { String(format: "%02x", $0) }.joined()
        return "action_\(epochMs)_\(hex)"
    }

    private static func closeHop(_ open: inout Open, now: UInt64) {
        guard let since = open.backgroundSinceNs else { return }
        open.backgroundSinceNs = nil
        // A clock that cannot be read forward adds nothing, never a negative.
        if now >= since { open.backgroundMs += Int((now - since) / 1_000_000) }
    }

    private static func baseAttributes(_ open: Open, dropped: Int) -> [String: AttributeValue] {
        var attrs: [String: AttributeValue] = [
            "action.id": .string(open.id),
            "action.name": .string(open.name)
        ]
        if let parent = open.parentId { attrs["action.parent_id"] = .string(parent) }
        if dropped > 0 { attrs["action.name.dropped"] = .int(dropped) }
        return attrs
    }

    /// Caller holds `lock`.
    private func baseAttributesLocked(_ open: Open) -> [String: AttributeValue] {
        Self.baseAttributes(open, dropped: droppedNames.count)
    }

    /// The one `action.ended` builder; any open hop is already closed.
    private static func endedAttributes(
        _ open: Open, outcome: Outcome, abandonReason: AbandonReason?, dropped: Int
    ) -> [String: AttributeValue] {
        var attrs = baseAttributes(open, dropped: dropped)
        attrs["action.outcome"] = .string(outcome.rawValue)
        if let abandonReason { attrs["action.abandon_reason"] = .string(abandonReason.rawValue) }
        attrs["action.background_count"] = .int(open.backgroundCount)
        attrs["action.background_duration_ms"] = .int(open.backgroundMs)
        return attrs
    }

    /// Caller holds `lock`. Rider = top of the stack; the file follows.
    /// Lock order: `Actions.lock` → `Riders` lock, never the reverse.
    private func publishLocked() {
        riders.setActionId(stack.last?.id)
        schedulePersistLocked()
    }

    /// Caller holds `lock`. A burst collapses to one write of the latest stack.
    private func schedulePersistLocked() {
        guard url != nil, !persistPending else { return }
        persistPending = true
        queue.async { [self] in
            lock.lock()
            persistPending = false
            let snapshot = stack
            let target = url
            lock.unlock()
            guard let target else { return }
            if snapshot.isEmpty {
                try? FileManager.default.removeItem(at: target)
            } else if let data = try? JSONEncoder().encode(snapshot) {
                try? FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: target, options: .atomic)
            }
        }
    }

    // MARK: Test hooks

    #if DEBUG
    public func _drainForTesting() { queue.sync {} }
    #endif
}
