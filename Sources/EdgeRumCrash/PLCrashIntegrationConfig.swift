// Sources/EdgeRumCrash/PLCrashIntegrationConfig.swift
//
// Internal config struct for `PLCrashIntegration`. Constructed inside
// `EdgeRum.start()` from the public `EdgeRumConfig`. Defaults match
// PLAN-iOS.md §6.7 and the size budget negotiated with the backend
// (PLAN-iOS.md §13 "Backend asks" item 6).
//
// Refs: PLAN-iOS.md §6.7, §F14/T14.4.
//

import Foundation
#if canImport(EdgeRumCore)
import EdgeRumCore
#endif

public struct PLCrashIntegrationConfig: Sendable {

    /// Directory PLCrashReporter uses to persist pending reports
    /// between launches. Defaults to `<Library>/Caches/edge-rum/plcr/`
    /// so the whole SDK footprint sits under one root.
    public var basePath: URL?

    /// Hard ceiling PLCrashReporter applies to its own on-disk report
    /// (its `maxReportBytes` init parameter). Independent of the
    /// `crash.report_json` cap we apply at encode time.
    public var maxReportBytes: Int

    /// T14.4 — top-N frames per thread kept verbatim before tail
    /// truncation kicks in. Spec default: 30.
    public var topFramesPerThread: Int

    /// Soft cap on the encoded `app.crash` attribute bag. If the
    /// JSON-string `crash.report_json` would push the event past this,
    /// the encoder strips per-thread registers and binary images (in
    /// that order) until the event fits.
    public var eventSizeCapBytes: Int

    public init(
        basePath: URL? = SessionSidecar.defaultBaseDirectoryURL()?
            .appendingPathComponent("plcr", isDirectory: true),
        maxReportBytes: Int = 256 * 1024,
        topFramesPerThread: Int = 30,
        eventSizeCapBytes: Int = 200 * 1024
    ) {
        self.basePath = basePath
        self.maxReportBytes = maxReportBytes
        self.topFramesPerThread = topFramesPerThread
        self.eventSizeCapBytes = eventSizeCapBytes
    }
}
