// Sources/EdgeRumCrash/CrashStackTruncator.swift
//
// T14.4 — top-N frames per thread truncation. Mirrors the UTF-8-safe
// truncation pattern in `Sources/EdgeRumCore/AppErrorBuilder.swift`
// so behaviour is consistent across `cause = "AppError"` and
// `cause = "NativeCrash"` payloads.
//
// Pure function — no I/O, no global state, no PLCR types. The encoder
// hands us already-parsed thread dictionaries (frame strings) so this
// helper is unit-testable without a fixture report.
//
// Refs: PLAN-iOS.md §F14/T14.4 ("Truncate to top-30 frames per
//       thread by default; stringify the rest into
//       `crash.thread.other_stacks` with `…N more…` marker").
//

import Foundation

internal enum CrashStackTruncator {

    /// Marker string appended to the truncated stack so the backend
    /// can detect (and a human reader can see) that more frames were
    /// dropped.
    internal static let omissionPrefix: String = "…"
    internal static let omissionSuffix: String = " more…"

    /// Keep the first `topN` frames of `frames` verbatim. If anything
    /// was dropped, return the omitted suffix as a single string
    /// (`"…N more…"`) so the caller can stash it in
    /// `crash.thread.<n>.other_stacks`. Returns `(kept, omittedMarker)`
    /// where `omittedMarker` is `nil` when nothing was dropped.
    internal static func truncate(
        frames: [String],
        topN: Int
    ) -> (kept: [String], omittedMarker: String?) {
        guard topN > 0 else { return ([], frames.isEmpty ? nil : marker(for: frames.count)) }
        if frames.count <= topN {
            return (frames, nil)
        }
        let kept = Array(frames.prefix(topN))
        let omitted = frames.count - topN
        return (kept, marker(for: omitted))
    }

    internal static func marker(for omittedCount: Int) -> String {
        "\(omissionPrefix)\(omittedCount)\(omissionSuffix)"
    }
}
