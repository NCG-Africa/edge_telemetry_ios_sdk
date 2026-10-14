// Sources/EdgeRumCore/PreviousSession.swift
//
// F33 / #220 — RUM coverage tranche 8, previous-session evidence (W11).
//
// The launch `session.started` describes how the previous process
// ended, from the sidecar it left behind: `previous_session.id`,
// `.end` (`clean | crash | unknown`), `.app_state`
// (`foreground | background`), `.app_version`, `.os_version`. No
// `device.boot_time`: `35F9.1` keeps boot-time-derived values on the
// device (#254, SDK-008). No verdict: `unknown` never means `oom` — the
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
    public static func attributes(
        prior: [String: AttributeValue]?,
        crashed: Bool
    ) -> [String: AttributeValue] {
        var out: [String: AttributeValue] = [:]
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

}
