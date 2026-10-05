// Sources/EdgeRumCore/Breadcrumbs.swift
//
// F31 / #218 — RUM coverage tranche 6 ("Breadcrumbs").
//
// A 100-row in-memory ring fed by `Recorder.recordEvent` ABOVE the
// sampler: every recorded event (never a metric) whose name is not
// forced-emit becomes one `{t, n, l, s}` row. The ring exists to defeat
// the sampler — at `sampleRate = 0.1` nine crashes in ten otherwise
// arrive with no journey.
//
// Durability: W3's volatile contract widened to a latest-wins ring. Each
// crumb schedules — at most one pending — a whole-ring snapshot into
// `Library/Caches/edge-rum/breadcrumbs.json` one window later, so the
// file is rewritten at most once per second and never while idle. The
// file carries its own `session.id` and the monotonic sequence counter.
//
// Attach points:
//   - replayed `app.crash` — the prior launch's file, read and deleted
//     by `EdgeRum.start()`, attached only on a `session.id` match;
//   - live `app.hang` / `app.error` — the in-memory ring, at most once
//     per session.
//
// `breadcrumb.dropped` = rows the reader can prove are missing: ring
// eviction (sequence − rows present), `l` truncations, or the whole
// trail on a `session.id` mismatch.
// ponytail: crumbs inside the last coalescing window are lost AND
// uncounted — a snapshot cannot count rows newer than itself. Upgrade
// path is the mmap ring (fixed-width slots), per the roadmap ceiling.
//
// Refs: docs/specs/rum-coverage-roadmap.md § Tranche 6;
//       docs/catalogue/ios-data-catalogue.md §5.12; W6 (#194).

import Foundation

public final class Breadcrumbs: @unchecked Sendable {

    public static let shared = Breadcrumbs()

    /// Ring capacity in rows.
    public static let capacity = 100
    /// `l` cap in UTF-8 bytes.
    public static let labelCapBytes = 128
    /// Coalescing window for the on-disk snapshot.
    public static let window: TimeInterval = 1.0

    public struct Row: Codable, Equatable, Sendable {
        public let t: Int
        public let n: String
        public let l: String?
        public let s: Int?

        public init(t: Int, n: String, l: String?, s: Int?) {
            self.t = t; self.n = n; self.l = l; self.s = s
        }
    }

    /// The on-disk snapshot.
    public struct File: Codable, Equatable, Sendable {
        public let sessionId: String
        public let seq: Int
        public let truncated: Int
        public let rows: [Row]

        public init(sessionId: String, seq: Int, truncated: Int, rows: [Row]) {
            self.sessionId = sessionId; self.seq = seq; self.truncated = truncated; self.rows = rows
        }

        enum CodingKeys: String, CodingKey {
            case sessionId = "session.id", seq, truncated, rows
        }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.edge.rum.breadcrumbs", qos: .utility)
    // ponytail: array + removeFirst is O(100) per eviction; a ring index
    // is the upgrade if this ever shows in a profile.
    private var rows: [Row] = []
    private var seq = 0
    private var truncated = 0
    private var sessionId = ""
    private var attachedThisSession = false
    private var capturing = false
    private var url: URL?
    private var persistPending = false
    private let persistDelay: TimeInterval

    /// `persistDelay` is a test seam; production uses `window`.
    public init(persistDelay: TimeInterval = Breadcrumbs.window) {
        self.persistDelay = persistDelay
    }

    /// `<Library>/Caches/edge-rum/breadcrumbs.json`.
    public static func defaultURL() -> URL? {
        SessionSidecar.defaultBaseDirectoryURL()?.appendingPathComponent("breadcrumbs.json")
    }

    /// Turn capture on or off and route snapshots to `url`. Off by
    /// default so a bare `Recorder` attaches nothing.
    public func configure(capturing: Bool, url: URL?) {
        lock.lock(); defer { lock.unlock() }
        self.capturing = capturing
        self.url = url
    }

    // MARK: Writers

    /// Project one recorded event into the ring. The caller has already
    /// excluded metrics and forced-emit names.
    public func record(name: String, attributes: [String: AttributeValue], at date: Date, sessionId: String) {
        lock.lock(); let on = capturing; lock.unlock()
        guard on else { return }
        let (label, status) = Self.project(name, attributes)
        var cut = 0
        var l = label
        if let label {
            (l, cut) = capUTF8(label, maxBytes: Self.labelCapBytes)
        }
        let row = Row(t: Int((date.timeIntervalSince1970 * 1000).rounded()), n: name, l: l, s: status)

        lock.lock(); defer { lock.unlock() }
        guard capturing else { return }
        self.sessionId = sessionId
        rows.append(row)
        if rows.count > Self.capacity { rows.removeFirst() }
        seq += 1
        if cut > 0 { truncated += 1 }
        schedulePersistLocked()
    }

    /// Session rotation or identity reset: the ring belongs to one
    /// session. Deletes the file off-thread, so a crash before the next
    /// crumb replays no trail rather than a mismatched one.
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        rows = []
        seq = 0
        truncated = 0
        sessionId = ""
        attachedThisSession = false
        guard let target = url else { return }
        queue.async { try? FileManager.default.removeItem(at: target) }
    }

    // MARK: Readers

    /// The current ring as wire attributes, the first time per session;
    /// empty afterwards (bounds a retry-looping `captureError`).
    public func attachOnce() -> [String: AttributeValue] {
        lock.lock(); defer { lock.unlock() }
        guard capturing, !attachedThisSession, !rows.isEmpty else { return [:] }
        attachedThisSession = true
        return Self.attributes(rows: rows, dropped: seq - rows.count + truncated)
    }

    /// Read and delete the prior launch's snapshot. Call before this
    /// launch records anything.
    public static func takePrior(url: URL? = defaultURL()) -> File? {
        guard let url else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }

    /// Wire attributes for a replayed crash. A `session.id` mismatch
    /// (or no sidecar identity) drops the trail and counts it.
    public static func replayAttributes(_ file: File?, sessionId: String?) -> [String: AttributeValue] {
        guard let file else { return [:] }
        guard file.sessionId == sessionId else {
            return file.seq > 0 ? ["breadcrumb.dropped": .int(file.seq)] : [:]
        }
        return attributes(rows: file.rows, dropped: file.seq - file.rows.count + file.truncated)
    }

    // MARK: Internals

    private static func attributes(rows: [Row], dropped: Int) -> [String: AttributeValue] {
        var out: [String: AttributeValue] = [:]
        if !rows.isEmpty, let data = try? encoder.encode(rows) {
            out["breadcrumbs"] = .string(String(decoding: data, as: UTF8.self))
        }
        if dropped > 0 { out["breadcrumb.dropped"] = .int(dropped) }
        return out
    }

    /// The `l` / `s` projection (catalogue §5.12, post-T4 names).
    private static func project(_ name: String, _ a: [String: AttributeValue]) -> (String?, Int?) {
        func str(_ key: String) -> String? {
            if case let .string(s)? = a[key] { return s }
            return nil
        }
        switch name {
        case "app_lifecycle": return (str("lifecycle.state"), nil)
        case "navigation": return (str("navigation.screen"), nil)
        case "user.interaction": return (str("interaction.name") ?? str("interaction.target"), nil)
        case "custom_event": return (str("event.name"), nil)
        case "http.request":
            var status: Int?
            if case let .int(code)? = a["http.status_code"] { status = code }
            let label = [str("http.method"), str("http.path")].compactMap { $0 }.joined(separator: " ")
            return (label.isEmpty ? nil : label, status)
        default: return (nil, nil)
        }
    }

    /// Caller holds `lock`. One pending write at a time, `window` after
    /// the first dirtying crumb.
    private func schedulePersistLocked() {
        guard url != nil, !persistPending else { return }
        persistPending = true
        queue.asyncAfter(deadline: .now() + persistDelay) { [self] in
            lock.lock()
            persistPending = false
            let file = File(sessionId: sessionId, seq: seq, truncated: truncated, rows: rows)
            let target = url
            lock.unlock()
            guard let target else { return }
            // Cleared since this write was scheduled.
            if file.rows.isEmpty { try? FileManager.default.removeItem(at: target); return }
            guard let data = try? Self.encoder.encode(file) else { return }
            try? FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: target, options: .atomic)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    // MARK: Test hooks

    #if DEBUG
    /// Block until any scheduled snapshot has landed.
    public func _drainForTesting() {
        Thread.sleep(forTimeInterval: persistDelay + 0.05)
        queue.sync {}
    }

    public var _rowsForTesting: [Row] {
        lock.lock(); defer { lock.unlock() }
        return rows
    }
    #endif
}
