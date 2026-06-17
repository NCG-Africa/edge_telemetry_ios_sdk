// Sources/EdgeRumCrash/HangEventEncoder.swift
//
// F15/T15.2 — pure encoder for hang `app.crash` events. Mirrors the
// shape of `CrashReportEncoder` (native crash path) so the backend
// dispatcher routes both flavours through the same `app.crash`
// channel, differentiated by `cause`. Hangs ride with
// `cause = "Hang"`, `runtime = "native"`, `crash.fatal = false`.
//
// Hang-specific attribute keys:
//
//   - `hang.duration_ms`    — observed stall length in ms
//   - `hang.threshold_ms`   — configured `hangTimeout` in ms
//   - `hang.cpu_usage`      — task CPU usage at detection (0.0-1.0)
//   - `crash.thread.main_stack` — best-effort symbolicated stack
//   - `crash.timestamp`     — ISO 8601 time of detection
//
// The `crash.thread.main_stack` key (rather than `hang.stack` from
// PLAN-iOS.md §6.8) is the explicit acceptance criterion in T15.2
// and matches the existing `CrashReportEncoder` namespace so future
// crash + hang dashboards share a single column. ADR-011 pins the
// rationale.
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

    /// Build the flat attribute bag for one hang `app.crash` event.
    /// Pure — no I/O, no globals, safe to call from any thread.
    ///
    /// - Parameters:
    ///   - durationMs: observed stall length in milliseconds.
    ///   - thresholdMs: configured `hangTimeout` in milliseconds.
    ///   - cpuUsage: optional task CPU usage at detection. `nil` if
    ///     the call site could not read `mach_task_basic_info`.
    ///   - stackFrames: ordered main-thread frames captured at
    ///     detection. Empty when the snapshot helper failed; in that
    ///     case we fall back to a single placeholder frame so the
    ///     T15.2 "non-empty `crash.thread.main_stack`" acceptance
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
        attrs["cause"] = .string("Hang")
        attrs["runtime"] = .string("native")
        attrs["crash.fatal"] = .bool(false)
        attrs["hang.duration_ms"] = .double(durationMs)
        attrs["hang.threshold_ms"] = .double(thresholdMs)
        if let cpu = cpuUsage {
            attrs["hang.cpu_usage"] = .double(cpu)
        }
        attrs["crash.timestamp"] = .string(WireDateFormatter.string(from: timestamp))

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
        attrs["crash.thread.main_stack"] = .string(rendered)

        return attrs
    }

    /// Placeholder used when the Mach-based stack walk fails. T15.2
    /// acceptance only requires a non-empty value; the marker tells
    /// the backend triage UI to treat this hang's stack as missing
    /// rather than empty.
    internal static let unavailableFrame: String = "<hang-stack-unavailable>"
}
