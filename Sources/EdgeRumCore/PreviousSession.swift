// Sources/EdgeRumCore/PreviousSession.swift
//
// F33 / #220 — RUM coverage tranche 8, previous-session evidence (W11).
//
// The launch `session.started` describes how the previous process
// ended, from the sidecar it left behind: `previous_session.id`,
// `.end` (`clean | crash | unknown`), `.app_state`
// (`foreground | background`), `.app_version`, `.os_version`, plus
// `device.boot_time`. No verdict: `unknown` never means `oom` — the
// backend joins it against `memory_usage`.
//
// Refs: docs/specs/rum-coverage-roadmap.md § Tranche 8;
//       docs/catalogue/ios-data-catalogue.md §0 clause 6.

import Foundation

public enum PreviousSession {

    /// Attributes for the launch `session.started`.
    ///
    /// - Parameters:
    ///   - prior: the previous process's sidecar (`SessionSidecar.read()`
    ///     before this launch's first write); `nil` on first launch.
    ///   - crashed: an `app.crash` was replayed this launch.
    ///   - bootTime: device boot time; `nil` omits `device.boot_time`.
    public static func attributes(
        prior: [String: AttributeValue]?,
        crashed: Bool,
        bootTime: Date? = PreviousSession.bootTime()
    ) -> [String: AttributeValue] {
        var out: [String: AttributeValue] = [:]
        if let bootTime {
            out["device.boot_time"] = .string(WireDateFormatter.string(from: bootTime))
        }
        guard let prior, let id = prior["session.id"] else { return out }
        out["previous_session.id"] = id
        // Exception wins: a crash report outranks a clean-exit marker.
        let end = crashed ? "crash"
            : prior[SessionSidecar.cleanExitKey] == .bool(true) ? "clean" : "unknown"
        out["previous_session.end"] = .string(end)
        if case let .string(state)? = prior["app.state"] {
            out["previous_session.app_state"] = .string(state == "background" ? "background" : "foreground")
        }
        out["previous_session.app_version"] = prior["app.version"]
        out["previous_session.os_version"] = prior["device.platform_version"]
        return out
    }

    /// One `sysctl KERN_BOOTTIME` read. `nil` if the call fails.
    public static func bootTime() -> Date? {
        var mib = [CTL_KERN, KERN_BOOTTIME]
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }
}
