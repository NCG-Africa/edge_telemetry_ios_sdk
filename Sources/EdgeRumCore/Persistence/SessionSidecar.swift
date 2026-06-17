// Sources/EdgeRumCore/Persistence/SessionSidecar.swift
//
// Mirrors the active session + identity attributes to
// `Library/Caches/edge-rum/last-session.json` on every `enqueue`. The
// crash backend (F14, `EdgeRumCrash`) reads this file on next launch
// when a crash report is pending, so the replayed `app.crash` event
// carries the *prior* session's identity rather than the freshly
// rotated current session.
//
// F4 ships the **writer** only. The reader + replay path is owned by
// F14 / `EdgeRumCrash` / T14.3 — flagged as carry-over on issue #44.
//
// Atomic write semantics: each write replaces the file via
// `Data.write(to:options:.atomic)` so a crash mid-write cannot leave
// a half-written JSON blob. The directory is created lazily on first
// write.
//
// Refs: CLAUDE.md "Crash sidecar"; PLAN-iOS.md §8.4 / §F4/T4.4.
//

import Foundation
import os.log

public protocol SessionSidecarWriting: Sendable {
    func write(snapshot: AttributeBag)
}

public final class SessionSidecar: SessionSidecarWriting, @unchecked Sendable {

    /// Default path: `<Library>/Caches/edge-rum/last-session.json`.
    public static func defaultURL() -> URL? {
        guard let base = defaultBaseDirectoryURL() else { return nil }
        return base.appendingPathComponent("last-session.json", isDirectory: false)
    }

    /// `<Library>/Caches/edge-rum/` — the SDK's per-app cache root.
    /// F14 places PLCrashReporter's `basePath` alongside the sidecar
    /// (under `plcr/`) so the entire SDK footprint can be wiped by
    /// deleting one directory.
    public static func defaultBaseDirectoryURL() -> URL? {
        let fm = FileManager.default
        guard let caches = try? fm.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return caches.appendingPathComponent("edge-rum", isDirectory: true)
    }

    /// Attribute keys that get mirrored to the sidecar — strictly the
    /// session / user / device identity triple plus the SDK identity
    /// stamp. We intentionally omit transient values (network state,
    /// battery level) because the replayed crash event should carry
    /// the *prior* session's identity, not its network state.
    public static let mirroredKeys: Set<String> = [
        "session.id",
        "session.start_time",
        "session.sequence",
        "user.id",
        "user.name",
        "user.email",
        "user.phone",
        "device.id",
        "sdk.version",
        "sdk.platform"
    ]

    private let url: URL?
    private let fileManager: FileManager
    private let log: OSLog
    private let lock = NSLock()
    private var directoryEnsured: Bool = false

    public init(
        url: URL? = SessionSidecar.defaultURL(),
        fileManager: FileManager = .default,
        log: OSLog = OSLog(subsystem: "com.edge.rum", category: "SessionSidecar")
    ) {
        self.url = url
        self.fileManager = fileManager
        self.log = log
    }

    public func write(snapshot: AttributeBag) {
        guard let url else { return }

        let mirrored = filter(snapshot)
        guard !mirrored.isEmpty else { return }

        do {
            try ensureDirectory(for: url)
            let data = try Self.encoder.encode(mirrored)
            try data.write(to: url, options: .atomic)
        } catch {
            os_log(
                "SessionSidecar write failed: %{public}@",
                log: log,
                type: .info,
                String(describing: error)
            )
        }
    }

    /// Read the persisted sidecar — F14 will call this on next launch
    /// when a crash report is pending. Exposed in F4 so the writer's
    /// round-trip can be tested.
    public func read() -> [String: AttributeValue]? {
        guard let url else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode([String: AttributeValue].self, from: data)
    }

    private func filter(_ bag: AttributeBag) -> [String: AttributeValue] {
        var out: [String: AttributeValue] = [:]
        for key in Self.mirroredKeys {
            if let value = bag[key] {
                out[key] = value
            }
        }
        return out
    }

    private func ensureDirectory(for url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        if directoryEnsured { return }
        let dir = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
        }
        directoryEnsured = true
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder = JSONDecoder()
}
