// Sources/EdgeRumCrash/HangEventEncoder.swift
//
// F15/T15.2 — pure encoder for `app.hang` events (F29 split them off
// `app.crash`). Hangs ride with `runtime = "native"`.
//
// Hang-specific attribute keys:
//
//   - `hang.duration_ms`    — observed stall length in ms
//   - `hang.threshold_ms`   — configured `hangTimeout` in ms
//   - `hang.cpu_usage`      — whole-process CPU over the stall window,
//                             per-core percent (may exceed 100)
//   - `hang.stack`          — best-effort symbolicated stack
//   - `hang.timestamp`      — ISO 8601 time of detection
//
// F29 renamed `crash.thread.main_stack` / `crash.timestamp` to the
// `hang.` keys (roadmap §10 row 11), superseding ADR-011's namespace.
//
// Refs: PLAN-iOS.md §6.8, §F15/T15.2; docs/decisions.md ADR-011;
//       CLAUDE.md "EdgeTelemetryProcessor contract".
//

import Foundation
#if canImport(EdgeRumCore)
import EdgeRumCore
#endif

internal enum HangEventEncoder {

    /// Cap the encoded stack at 30 frames (mirrors `CrashReportEncoder`
    /// per-thread budget). Any further frames are summarised with a
    /// `…N more…` marker via `CrashStackTruncator`.
    internal static let topFrames: Int = 30

    /// Build the flat attribute bag for one `app.hang` event.
    /// Pure — no I/O, no globals, safe to call from any thread.
    ///
    /// - Parameters:
    ///   - durationMs: observed stall length in milliseconds.
    ///   - thresholdMs: configured `hangTimeout` in milliseconds.
    ///   - cpuUsage: whole-process CPU over the stall window, per-core
    ///     percent (may exceed 100), from `ProcessCPUReader`. `nil` if the Mach
    ///     read failed.
    ///   - stackFrames: ordered main-thread frames captured at
    ///     detection. Empty when the snapshot helper failed; in that
    ///     case we fall back to a single placeholder frame so the
    ///     T15.2 "non-empty `hang.stack`" acceptance
    ///     criterion holds.
    ///   - timestamp: detection wall-clock time, in ISO 8601 form.
    internal static func encode(
        durationMs: Double,
        thresholdMs: Double,
        cpuUsage: Double?,
        stackFrames: [String],
        timestamp: Date
    ) -> [String: AttributeValue] {

        var attrs: [String: AttributeValue] = [:]
        attrs["runtime"] = .string("native")
        attrs["hang.duration_ms"] = .double(durationMs)
        attrs["hang.threshold_ms"] = .double(thresholdMs)
        if let cpu = cpuUsage {
            attrs["hang.cpu_usage"] = .double(cpu)
        }
        attrs["hang.timestamp"] = .string(WireDateFormatter.string(from: timestamp))

        let safeFrames = stackFrames.isEmpty
            ? [Self.unavailableFrame]
            : stackFrames
        let (kept, omitted) = CrashStackTruncator.truncate(
            frames: safeFrames,
            topN: topFrames
        )
        var rendered = kept.joined(separator: "\n")
        if let marker = omitted {
            rendered += "\n" + marker
        }
        attrs["hang.stack"] = .string(rendered)

        return attrs
    }

    /// Placeholder used when the Mach-based stack walk fails. T15.2
    /// acceptance only requires a non-empty value; the marker tells
    /// the backend triage UI to treat this hang's stack as missing
    /// rather than empty.
    internal static let unavailableFrame: String = "<hang-stack-unavailable>"
}
