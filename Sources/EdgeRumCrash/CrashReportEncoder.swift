// Sources/EdgeRumCrash/CrashReportEncoder.swift
//
// Pure encoder over a parsed `PLCrashReport`. Builds the flat
// attribute bag for an `app.crash` event with `cause = "NativeCrash"`,
// stamping `crash.report_format_version = "edgerum.crash.v1"` so the
// backend can validate the embedded `crash.report_json` shape.
//
// Why we build `crash.report_json` as a JSON-stringified dictionary
// rather than using PLCR's text formatter: the wire only accepts flat
// primitive attributes, so the full crash report (threads, registers,
// binary images) cannot ride as a nested object. Stringifying via
// `JSONSerialization` gives the backend something it can parse back
// out, and lets us own the size envelope explicitly (T14.4).
//
// Refs: PLAN-iOS.md §6.7, §F14/T14.4; CLAUDE.md "EdgeTelemetry-
// Processor contract" (wire is primitives-only).
//

import Foundation
#if canImport(EdgeRumCore)
import EdgeRumCore
#endif
#if canImport(CrashReporter)
@_implementationOnly import CrashReporter
#endif

internal enum CrashReportEncoder {

    /// Schema discriminator stamped on every emitted event. Bump in
    /// lockstep with `docs/decisions.md` ADR-005 whenever the shape of
    /// `crash.report_json` changes.
    internal static let reportFormatVersion: String = "edgerum.crash.v1"

    /// Encode a raw PLCR report (the bytes returned by
    /// `loadPendingCrashReportData`) into the wire attribute bag for
    /// `app.crash`. Returns `nil` if the bytes do not parse as a
    /// valid PLCR report — the caller should still purge the file to
    /// avoid replaying a poison-pill report forever.
    internal static func encode(
        reportData: Data,
        topFramesPerThread: Int,
        eventSizeCapBytes: Int
    ) -> [String: AttributeValue]? {
        #if canImport(CrashReporter)
        guard let report = try? PLCrashReport(data: reportData) else {
            return nil
        }
        return encode(
            report: report,
            topFramesPerThread: topFramesPerThread,
            eventSizeCapBytes: eventSizeCapBytes
        )
        #else
        _ = reportData
        _ = topFramesPerThread
        _ = eventSizeCapBytes
        return nil
        #endif
    }

    #if canImport(CrashReporter)

    /// Internal entry exposed so unit tests can feed a hand-built
    /// `PLCrashReport` through the encoder. The public PLCR init
    /// accepts a `Data` only, but a fixture report is generated via
    /// `CrashFixtureGenerator.makeLiveReport()`.
    internal static func encode(
        report: PLCrashReport,
        topFramesPerThread: Int,
        eventSizeCapBytes: Int
    ) -> [String: AttributeValue] {

        var attrs: [String: AttributeValue] = [:]
        attrs["cause"] = .string("NativeCrash")
        attrs["runtime"] = .string("native")
        attrs["crash.fatal"] = .bool(true)
        attrs["crash.report_format_version"] = .string(reportFormatVersion)

        if let sigName = report.signalInfo?.name {
            attrs["crash.signal"] = .string(sigName)
        }
        if let sigCode = report.signalInfo?.code {
            attrs["crash.signal_code"] = .string(sigCode)
        }
        if report.hasExceptionInfo, let exc = report.exceptionInfo {
            attrs["crash.exception_name"] = .string(exc.exceptionName)
            attrs["crash.exception_reason"] = .string(exc.exceptionReason)
        }
        if let timestamp = report.systemInfo?.timestamp {
            attrs["crash.timestamp"] = .string(WireDateFormatter.string(from: timestamp))
        }
        if let osVersion = report.systemInfo?.operatingSystemVersion {
            attrs["crash.os_version"] = .string(osVersion)
        }

        // Find the crashed thread and stamp the faulting binary's UUID
        // so the backend can dSYM-symbolicate without walking the full
        // image list. Falls through silently if there's no crashed
        // thread (live reports have none).
        if let threads = report.threads as? [PLCrashReportThreadInfo],
           let crashedThread = threads.first(where: { $0.crashed }),
           let frames = crashedThread.stackFrames as? [PLCrashReportStackFrameInfo],
           let topFrame = frames.first,
           let image = report.image(forAddress: topFrame.instructionPointer) {
            if let uuid = image.imageUUID {
                attrs["crash.binary_uuid"] = .string(uuid)
            }
            if let name = image.imageName {
                attrs["crash.binary_name"] = .string((name as NSString).lastPathComponent)
            }
        }

        // Assemble the full report dict, truncating top-N frames per
        // thread, and stringify it. If the produced event is still
        // over the cap, strip the heaviest optional fields (register
        // dumps, then binary images) until we fit.
        var dict = buildReportDict(report: report, topFramesPerThread: topFramesPerThread)
        var jsonString = serialize(dict)
        if eventSize(attrs: attrs, reportJson: jsonString) > eventSizeCapBytes {
            stripRegisters(in: &dict)
            jsonString = serialize(dict)
        }
        if eventSize(attrs: attrs, reportJson: jsonString) > eventSizeCapBytes {
            dict["binary_images"] = []
            jsonString = serialize(dict)
        }
        attrs["crash.report_json"] = .string(jsonString)

        return attrs
    }

    // MARK: - Report → dictionary

    private static func buildReportDict(
        report: PLCrashReport,
        topFramesPerThread: Int
    ) -> [String: Any] {
        var dict: [String: Any] = [:]
        dict["format_version"] = reportFormatVersion

        if let sys = report.systemInfo {
            dict["system"] = [
                "os_version": sys.operatingSystemVersion ?? "",
                "os_build": sys.operatingSystemBuild ?? "",
                "timestamp": sys.timestamp.map { WireDateFormatter.string(from: $0) } ?? ""
            ]
        }

        if let app = report.applicationInfo {
            dict["application"] = [
                "identifier": app.applicationIdentifier ?? "",
                "version": app.applicationVersion ?? "",
                "marketing_version": app.applicationMarketingVersion ?? ""
            ]
        }

        if let sig = report.signalInfo {
            dict["signal"] = [
                "name": sig.name ?? "",
                "code": sig.code ?? "",
                "address": String(sig.address)
            ]
        }

        if let mach = report.machExceptionInfo {
            dict["mach_exception"] = [
                "type": String(mach.type),
                "codes": (mach.codes as? [NSNumber])?.map { $0.uint64Value.description } ?? []
            ]
        }

        if report.hasExceptionInfo, let exc = report.exceptionInfo {
            dict["exception"] = [
                "name": exc.exceptionName,
                "reason": exc.exceptionReason
            ]
        }

        // Threads — apply T14.4 truncation per-thread.
        var threadDicts: [[String: Any]] = []
        for thread in (report.threads as? [PLCrashReportThreadInfo] ?? []) {
            let frameStrings = (thread.stackFrames as? [PLCrashReportStackFrameInfo] ?? [])
                .map { String(format: "0x%016llx", $0.instructionPointer) }
            let (kept, marker) = CrashStackTruncator.truncate(
                frames: frameStrings,
                topN: topFramesPerThread
            )
            var threadDict: [String: Any] = [
                "number": thread.threadNumber,
                "crashed": thread.crashed,
                "stack": kept
            ]
            if let marker {
                threadDict["other_stacks"] = marker
            }
            if thread.crashed,
               let regs = thread.registers as? [PLCrashReportRegisterInfo],
               !regs.isEmpty {
                var regDict: [String: String] = [:]
                for reg in regs {
                    regDict[reg.registerName] = String(format: "0x%016llx", reg.registerValue)
                }
                threadDict["registers"] = regDict
            }
            threadDicts.append(threadDict)
        }
        dict["threads"] = threadDicts

        // Binary images — keep just what's needed for symbolication.
        var imageDicts: [[String: Any]] = []
        for image in (report.images as? [PLCrashReportBinaryImageInfo] ?? []) {
            var imageDict: [String: Any] = [
                "base_address": String(image.imageBaseAddress),
                "size": String(image.imageSize),
                "name": image.imageName ?? ""
            ]
            if let uuid = image.imageUUID {
                imageDict["uuid"] = uuid
            }
            imageDicts.append(imageDict)
        }
        dict["binary_images"] = imageDicts

        return dict
    }

    private static func stripRegisters(in dict: inout [String: Any]) {
        guard var threads = dict["threads"] as? [[String: Any]] else { return }
        for i in threads.indices {
            threads[i].removeValue(forKey: "registers")
        }
        dict["threads"] = threads
    }

    private static func serialize(_ dict: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(
                withJSONObject: dict,
                options: [.sortedKeys]
              ),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    private static func eventSize(
        attrs: [String: AttributeValue],
        reportJson: String
    ) -> Int {
        // Cheap approximation: sum the UTF-8 byte counts of all string
        // values in `attrs` plus the report JSON itself. Misses int /
        // double / bool sizes, but those are tiny next to the report
        // string and the encoder treats this as a soft cap anyway.
        var total = reportJson.utf8.count
        for (k, v) in attrs {
            total += k.utf8.count
            if case let .string(s) = v {
                total += s.utf8.count
            }
        }
        return total
    }

    #endif
}
