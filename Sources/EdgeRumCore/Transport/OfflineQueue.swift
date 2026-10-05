// Sources/EdgeRumCore/Transport/OfflineQueue.swift
//
// File-backed FIFO of encoded envelopes that failed the live retry
// schedule. Each file is one complete payload, ready to POST verbatim.
//
//   Location: Library/Caches/edge-rum/queue/<epochMs>-<seq>-<n>.json
//   Cap:      EdgeRumConfig.maxQueueSize (default 200) events across
//             files. `<n>` is the file's event count, so trimming never
//             reads a payload.
//   Overflow: oldest files deleted first until the total is ≤ cap.
//   Drain:    sequential — success deletes the file, failure leaves it
//             and aborts the drain.
//
// Filename layout is deliberate: the epoch-ms prefix makes
// lexicographic ordering match chronological ordering, so no separate
// index file is needed. The `-<seq>` suffix disambiguates two enqueues
// inside the same millisecond. Pre-F26 `<epochMs>-<seq>.json` files
// have no `<n>` and count as one event.
//
// Concurrency: a single `NSLock` around directory mutation is enough —
// the `HTTPTransportSink` calls `drain` and `enqueue` on its own serial
// `DispatchQueue`. The lock guards external callers (e.g. tests) and
// future call sites.
//
// Refs: PLAN-iOS.md §9.4, §F5/T5.3; CLAUDE.md "Offline queue rules".
//

import Foundation
import os.log

public protocol OfflineQueueing: Sendable {
    /// Atomically append a payload holding `eventCount` events, then
    /// trim oldest-first to ≤ `maxQueueSize` events. Returns the URL of
    /// the written file, or `nil` if the write failed (or it was trimmed).
    @discardableResult
    func enqueue(_ payload: Data, eventCount: Int) -> URL?

    /// Drain the queue sequentially via the supplied closure. The
    /// closure returns `true` to delete the file (success) or `false`
    /// to leave it on disk and abort the drain (failure).
    ///
    /// Returns the count of files successfully drained.
    @discardableResult
    func drain(via: (Data) -> Bool) -> Int

    /// Number of payload files currently on disk.
    var count: Int { get }

    /// Remove every file in the queue directory. Test helper.
    func reset()
}

extension OfflineQueueing {
    /// One-event enqueue — test convenience.
    @discardableResult
    public func enqueue(_ payload: Data) -> URL? { enqueue(payload, eventCount: 1) }
}

public final class OfflineQueue: OfflineQueueing, @unchecked Sendable {

    /// Default queue directory:
    /// `<Library>/Caches/edge-rum/queue/`. Returns `nil` on platforms
    /// or sandboxes where the caches directory can't be resolved.
    public static func defaultDirectory() -> URL? {
        let fm = FileManager.default
        guard let caches = try? fm.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return caches
            .appendingPathComponent("edge-rum", isDirectory: true)
            .appendingPathComponent("queue", isDirectory: true)
    }

    private let directory: URL
    private let fileManager: FileManager
    private let maxQueueSize: Int
    private let log: OSLog
    private let debug: Bool

    private let lock = NSLock()
    private var directoryEnsured: Bool = false
    private var sequence: UInt64 = 0
    private let clockEpochMs: () -> Int64

    public init?(
        directory: URL? = OfflineQueue.defaultDirectory(),
        fileManager: FileManager = .default,
        maxQueueSize: Int = 200,
        debug: Bool = false,
        log: OSLog = OSLog(subsystem: "com.edge.rum", category: "OfflineQueue"),
        clockEpochMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        guard let directory else { return nil }
        self.directory = directory
        self.fileManager = fileManager
        self.maxQueueSize = max(1, maxQueueSize)
        self.debug = debug
        self.log = log
        self.clockEpochMs = clockEpochMs
    }

    @discardableResult
    public func enqueue(_ payload: Data, eventCount: Int) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        do {
            try ensureDirectoryLocked()
        } catch {
            if debug {
                os_log(
                    "OfflineQueue could not create queue directory: %{public}@",
                    log: log,
                    type: .info,
                    String(describing: error)
                )
            }
            return nil
        }

        let now = clockEpochMs()
        sequence &+= 1
        // %013lld + %06llu — `%d` would be a 32-bit `int` per C printf
        // and silently truncate epoch-millisecond values.
        let filename = String(format: "%013lld-%06llu-%ld.json", now, sequence, max(1, eventCount))
        let url = directory.appendingPathComponent(filename, isDirectory: false)

        do {
            try payload.write(to: url, options: .atomic)
        } catch {
            if debug {
                os_log(
                    "OfflineQueue write failed: %{public}@",
                    log: log,
                    type: .info,
                    String(describing: error)
                )
            }
            return nil
        }

        trimToCapLocked()
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    public func drain(via: (Data) -> Bool) -> Int {
        let files = orderedFiles()
        var drained = 0
        for url in files {
            guard let data = try? Data(contentsOf: url) else {
                // Corrupt / unreadable file — remove it so the queue
                // doesn't wedge.
                try? fileManager.removeItem(at: url)
                continue
            }
            let ok = via(data)
            if !ok {
                break
            }
            try? fileManager.removeItem(at: url)
            drained += 1
        }
        return drained
    }

    public var count: Int {
        orderedFiles().count
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        if let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            for url in entries {
                try? fileManager.removeItem(at: url)
            }
        }
        sequence = 0
    }

    // MARK: Internals

    /// List queue files in chronological (= lexicographic) order. The
    /// epoch-ms prefix guarantees the two orderings agree.
    public func orderedFiles() -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return entries
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func ensureDirectoryLocked() throws {
        if directoryEnsured { return }
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        directoryEnsured = true
    }

    private func trimToCapLocked() {
        let entries = orderedFiles()
        var total = entries.reduce(0) { $0 + Self.eventCount(of: $1) }
        for url in entries where total > maxQueueSize {
            try? fileManager.removeItem(at: url)
            total -= Self.eventCount(of: url)
        }
    }

    /// `<n>` from `<epochMs>-<seq>-<n>.json`; legacy two-part names → 1.
    static func eventCount(of url: URL) -> Int {
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
        return parts.count == 3 ? Int(parts[2]) ?? 1 : 1
    }
}
