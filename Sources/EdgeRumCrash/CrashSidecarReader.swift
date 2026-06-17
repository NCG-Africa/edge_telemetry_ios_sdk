// Sources/EdgeRumCrash/CrashSidecarReader.swift
//
// Thin wrapper around `SessionSidecar.read()` that pulls the mirrored
// identity keys, validates `session.id` / `device.id` against the
// regex format helpers in `EdgeRumCore.IdentityFormat`, and surfaces
// a single typed snapshot the replay path can splat onto the
// `app.crash` attribute bag.
//
// On rejection (missing file, malformed identity), returns `nil` —
// the caller falls back to the *current* recorder identity. Better to
// ship the crash with partial identity than to drop it.
//
// Refs: PLAN-iOS.md §6.7, §8.4, §F14/T14.3; CLAUDE.md
//       "Session and ID rules".
//

import Foundation
#if canImport(EdgeRumCore)
import EdgeRumCore
#endif

internal struct CrashSidecarSnapshot: Equatable {

    /// The session that was live at the moment of crash. Always
    /// matches the `session_…_ios` regex.
    internal let sessionId: String

    /// Wire-format ISO 8601 string. May be `nil` on older sidecars
    /// that were missing the field.
    internal let sessionStartTime: String?

    /// Last successfully ACKed batch sequence for the crashed session.
    /// May be `0` if the crash happened before the first ACK.
    internal let sessionSequence: Int?

    /// The device identity at the time of crash. Always matches the
    /// `device_…_ios` regex.
    internal let deviceId: String

    /// SDK-owned anonymous user id. May be `nil` on early launches.
    internal let userId: String?

    /// All other mirrored attributes passed through verbatim (e.g.
    /// `user.name`, `user.email`, `user.phone`, `sdk.version`,
    /// `sdk.platform`). Stashed so the caller can merge them into the
    /// emitted event without re-walking the sidecar's key list.
    internal let extras: [String: AttributeValue]
}

internal enum CrashSidecarReader {

    /// Read the sidecar via `SessionSidecar.read()` and validate the
    /// two mandatory identifiers. Returns `nil` if either is missing
    /// or malformed.
    internal static func read(_ sidecar: SessionSidecar) -> CrashSidecarSnapshot? {
        guard let raw = sidecar.read() else { return nil }
        return parse(raw)
    }

    /// Pure path — separated from `read(_:)` so the unit tests can feed
    /// the raw decoded dictionary directly without seeding a file.
    internal static func parse(_ raw: [String: AttributeValue]) -> CrashSidecarSnapshot? {
        guard let sessionId = string(raw["session.id"]),
              IdentityFormat.isValid(sessionId, kind: .session) else {
            return nil
        }
        guard let deviceId = string(raw["device.id"]),
              IdentityFormat.isValid(deviceId, kind: .device) else {
            return nil
        }

        let userId = string(raw["user.id"]).flatMap { id in
            IdentityFormat.isValid(id, kind: .user) ? id : nil
        }
        let startTime = string(raw["session.start_time"])
        let sequence = int(raw["session.sequence"])

        var extras: [String: AttributeValue] = [:]
        let consumed: Set<String> = [
            "session.id", "session.start_time", "session.sequence",
            "device.id", "user.id"
        ]
        for (key, value) in raw where !consumed.contains(key) {
            extras[key] = value
        }

        return CrashSidecarSnapshot(
            sessionId: sessionId,
            sessionStartTime: startTime,
            sessionSequence: sequence,
            deviceId: deviceId,
            userId: userId,
            extras: extras
        )
    }

    // MARK: - Helpers

    private static func string(_ value: AttributeValue?) -> String? {
        guard case let .string(s) = value else { return nil }
        return s
    }

    private static func int(_ value: AttributeValue?) -> Int? {
        switch value {
        case .int(let i)?: return i
        case .double(let d)?: return Int(d)
        default: return nil
        }
    }
}
