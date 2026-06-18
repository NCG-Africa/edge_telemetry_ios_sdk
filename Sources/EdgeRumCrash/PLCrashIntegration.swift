// Sources/EdgeRumCrash/PLCrashIntegration.swift
//
// F14 façade — install + replay. Two static entry points called from
// `EdgeRum.start()`:
//
//   - `replayIfNeeded(...)` runs FIRST, BEFORE `Recorder.shared.start`.
//     If PLCrashReporter has a pending report on disk (i.e. the prior
//     launch crashed), parse it, fold in the crashed session's
//     identity from `SessionSidecar`, push a single `app.crash` event
//     through the Recorder (which immediately flushes on `app.crash`
//     per `Recorder.recordEvent`), then purge the on-disk report.
//
//   - `install(...)` runs LAST, AFTER every capture is wired. It
//     constructs a `PLCrashReporter` with `signalHandlerType = .mach`
//     and `shouldRegisterUncaughtExceptionHandler = true`, points it
//     at `<Library>/Caches/edge-rum/plcr/`, and registers the signal
//     / Mach exception handlers. Re-entrant: a second `EdgeRum.start`
//     is a no-op (single-shot via the `installed` flag).
//
// Type-level firewall: `import EdgeRumCrash` is OK from inside the
// public `EdgeRum` target (its symbols are `internal`), but no
// PLCrashReporter type ever crosses out — `@_implementationOnly`
// keeps `CrashReporter` invisible to consumers.
//
// Refs: PLAN-iOS.md §6.7, §F14/T14.1, §F14/T14.3; CLAUDE.md
//       "Touching crash code?" checklist item.
//

import Foundation
import os.log
#if canImport(EdgeRumCore)
import EdgeRumCore
#endif
#if canImport(CrashReporter)
@_implementationOnly import CrashReporter
#endif

public enum PLCrashIntegration {

    /// Single-shot guard so a host calling `EdgeRum.start()` twice
    /// doesn't end up with two registered Mach exception servers.
    private static let installLock = NSLock()
    nonisolated(unsafe) private static var installed: Bool = false

    /// Test hook — let `PLCrashIntegrationInstallTests` reset the
    /// guard between cases. Marked `internal` so it can't be reached
    /// from outside the target.
    internal static func _resetForTests() {
        installLock.lock(); defer { installLock.unlock() }
        installed = false
    }

    private static let log = OSLog(subsystem: "com.edge.rum", category: "edge.rum.crash")

    // MARK: - Install (T14.1)

    /// Construct + enable the underlying `PLCrashReporter`. Safe to
    /// call multiple times (subsequent calls are no-ops). Errors are
    /// caught and logged in debug only; the SDK must not crash the
    /// host because crash capture failed to register.
    public static func install(
        config: PLCrashIntegrationConfig,
        debug: Bool
    ) {
        _install(config: config, debug: debug, enable: defaultEnable)
    }

    /// Internal seam: same idempotency guard as the public entry
    /// point, but lets tests inject a no-op `enable` so they can
    /// verify the single-shot behaviour without registering Mach
    /// exception handlers (which hangs under XCTest on CI runners).
    internal static func _install(
        config: PLCrashIntegrationConfig,
        debug: Bool,
        enable: (PLCrashIntegrationConfig, Bool) -> Void
    ) {
        installLock.lock()
        if installed {
            installLock.unlock()
            return
        }
        installed = true
        installLock.unlock()
        enable(config, debug)
    }

    private static let defaultEnable: (PLCrashIntegrationConfig, Bool) -> Void = { config, debug in
        #if canImport(CrashReporter)
        guard let reporter = makeReporter(config: config) else {
            if debug {
                os_log("PLCrashReporter init failed", log: log, type: .info)
            }
            return
        }
        if !reporter.enable() {
            if debug {
                os_log("PLCrashReporter enable returned false", log: log, type: .info)
            }
        }
        #else
        _ = config
        _ = debug
        #endif
    }

    // MARK: - Replay (T14.3)

    /// Replay any pending PLCR report from the prior launch as one
    /// `app.crash` event, attribute it to the *crashed* session via
    /// the sidecar, then purge the report. No-op if nothing is
    /// pending or PLCR is unavailable.
    public static func replayIfNeeded(
        recorder: Recording,
        sidecar: SessionSidecar,
        config: PLCrashIntegrationConfig = PLCrashIntegrationConfig(),
        debug: Bool
    ) {
        #if canImport(CrashReporter)
        guard let reporter = makeReporter(config: config) else {
            if debug {
                os_log("PLCrashReporter init failed during replay", log: log, type: .info)
            }
            return
        }
        guard reporter.hasPendingCrashReport() else { return }

        guard let data = reporter.loadPendingCrashReportData() else {
            if debug {
                os_log("PLCrashReporter load returned nil — purging", log: log, type: .info)
            }
            _ = reporter.purgePendingCrashReport()
            return
        }

        guard var attrs = CrashReportEncoder.encode(
            reportData: data,
            topFramesPerThread: config.topFramesPerThread,
            eventSizeCapBytes: config.eventSizeCapBytes
        ) else {
            if debug {
                os_log("PLCrashReporter report did not parse — purging", log: log, type: .info)
            }
            _ = reporter.purgePendingCrashReport()
            return
        }

        // Fold in the crashed session's identity so the wire event
        // lands under the *prior* session's id, not the freshly
        // started one. PayloadBuilder merges event attrs with
        // event-wins semantics so these override the live context.
        if let snapshot = CrashSidecarReader.read(sidecar) {
            attrs["session.id"] = .string(snapshot.sessionId)
            if let start = snapshot.sessionStartTime {
                attrs["session.start_time"] = .string(start)
            }
            if let seq = snapshot.sessionSequence {
                attrs["session.sequence"] = .int(seq)
            }
            attrs["device.id"] = .string(snapshot.deviceId)
            if let userId = snapshot.userId {
                attrs["user.id"] = .string(userId)
            }
            for (key, value) in snapshot.extras where attrs[key] == nil {
                attrs[key] = value
            }
        } else if debug {
            os_log(
                "PLCrashReporter replay: sidecar missing or malformed — using live identity",
                log: log,
                type: .info
            )
        }

        recorder.recordEvent(name: "app.crash", attributes: attrs)
        // `Recorder.recordEvent("app.crash", ...)` triggers an
        // immediate flush internally (Recorder.swift), so no explicit
        // `flush(reason:)` call is needed here.

        if !reporter.purgePendingCrashReport(), debug {
            os_log("PLCrashReporter purge returned false", log: log, type: .info)
        }
        #else
        _ = recorder
        _ = sidecar
        _ = config
        _ = debug
        #endif
    }

    // MARK: - Helpers

    #if canImport(CrashReporter)
    private static func makeReporter(config: PLCrashIntegrationConfig) -> PLCrashReporter? {
        let plcrConfig = PLCrashReporterConfig(
            signalHandlerType: .mach,
            symbolicationStrategy: .all,
            shouldRegisterUncaughtExceptionHandler: true,
            basePath: config.basePath?.path,
            maxReportBytes: UInt(config.maxReportBytes)
        )
        return PLCrashReporter(configuration: plcrConfig)
    }
    #endif
}
