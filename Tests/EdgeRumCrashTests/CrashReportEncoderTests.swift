// Tests/EdgeRumCrashTests/CrashReportEncoderTests.swift
//
// Drives `CrashReportEncoder` against a live PLCR report generated
// via the in-target `CrashFixtureGenerator`. A live report carries
// real `systemInfo` / `applicationInfo` / `threads` / `binary_images`
// but no `signalInfo` / `exceptionInfo` (no crash actually occurred),
// which is exactly the surface we want to test the "graceful absence"
// path against.
//
// Refs: PLAN-iOS.md §6.7, §F14/T14.1, §F14/T14.4.
//

import XCTest
@testable import EdgeRumCrash
import EdgeRumCore

final class CrashReportEncoderTests: XCTestCase {

    func testEncodesLiveReportIntoFlatPrimitivesOnly() throws {
        guard let data = CrashFixtureGenerator.makeLiveReport() else {
            throw XCTSkip("PLCrashReporter unavailable on this slice")
        }
        let attrs = try XCTUnwrap(CrashReportEncoder.encode(
            reportData: data,
            topFramesPerThread: 30,
            eventSizeCapBytes: 200_000
        ))

        // Required wire fields.
        XCTAssertEqual(attrs["cause"], .string("NativeCrash"))
        XCTAssertEqual(attrs["runtime"], .string("native"))
        XCTAssertEqual(attrs["crash.fatal"], .bool(true))
        XCTAssertEqual(
            attrs["crash.report_format_version"],
            .string("edgerum.crash.v1"),
            "ADR-005 contract — bump in lockstep with the doc"
        )

        // crash.report_json present and parses back to JSON.
        let reportJson = try XCTUnwrap(attrs["crash.report_json"])
        guard case let .string(jsonString) = reportJson else {
            return XCTFail("crash.report_json must be a String")
        }
        let parsed = try JSONSerialization.jsonObject(
            with: Data(jsonString.utf8)
        ) as? [String: Any]
        XCTAssertNotNil(parsed, "crash.report_json must round-trip as a JSON object")
        XCTAssertNotNil(parsed?["threads"], "report dict must include threads")
        XCTAssertNotNil(parsed?["binary_images"], "report dict must include binary_images")
        XCTAssertEqual(
            parsed?["format_version"] as? String,
            "edgerum.crash.v1"
        )

        // Every attribute value is a JSON primitive (CLAUDE.md wire
        // contract). Asserted at the type level by AttributeValue, but
        // re-asserted here so the test fails loud if the enum ever
        // gains another case.
        for (key, value) in attrs {
            switch value {
            case .string, .int, .double, .bool:
                continue
            @unknown default:
                XCTFail("attribute \(key) carried a non-primitive value")
            }
        }
    }

    func testEnforcesEventSizeCap() throws {
        guard let data = CrashFixtureGenerator.makeLiveReport() else {
            throw XCTSkip("PLCrashReporter unavailable on this slice")
        }
        // Tiny cap forces the encoder to strip registers + binary
        // images. We still expect a valid attribute bag (truncation
        // is best-effort, never a drop).
        let attrs = try XCTUnwrap(CrashReportEncoder.encode(
            reportData: data,
            topFramesPerThread: 5,
            eventSizeCapBytes: 4_096
        ))
        let reportJson = try XCTUnwrap(attrs["crash.report_json"])
        guard case let .string(jsonString) = reportJson else {
            return XCTFail("crash.report_json must be a String")
        }
        let parsed = try JSONSerialization.jsonObject(
            with: Data(jsonString.utf8)
        ) as? [String: Any]
        // Binary images get dropped when over cap.
        let images = parsed?["binary_images"] as? [Any]
        XCTAssertTrue(images?.isEmpty ?? true,
                      "binary_images dropped under tight size cap")
    }

    func testBogusReportDataReturnsNil() {
        let attrs = CrashReportEncoder.encode(
            reportData: Data("not a plcr report".utf8),
            topFramesPerThread: 30,
            eventSizeCapBytes: 200_000
        )
        XCTAssertNil(attrs, "garbage in → nil out so the caller can purge")
    }
}
