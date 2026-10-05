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
        XCTAssertNil(attrs["cause"])
        XCTAssertEqual(attrs["runtime"], .string("native"))
        XCTAssertNil(attrs["crash.fatal"])
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
        // Binary images get dropped when over cap — unreferenced first,
        // so whatever survives is an image a kept frame points into.
        let images = parsed?["binary_images"] as? [[String: Any]] ?? []
        let addresses = (parsed?["threads"] as? [[String: Any]] ?? [])
            .flatMap { $0["stack"] as? [String] ?? [] }
            .compactMap { UInt64($0.dropFirst(2), radix: 16) }
        for image in images {
            let base = UInt64(image["base_address"] as? String ?? "") ?? 0
            let size = UInt64(image["size"] as? String ?? "") ?? 0
            XCTAssertTrue(addresses.contains { $0 >= base && $0 - base < size },
                          "surviving image \(image["name"] ?? "?") must be referenced")
        }
        // C10 marker counts what was removed (live report → many images).
        guard case let .int(droppedImages)? = attrs["crash.binary_images.dropped"] else {
            return XCTFail("crash.binary_images.dropped expected under tight cap")
        }
        let roomy = try XCTUnwrap(CrashReportEncoder.encode(
            reportData: data, topFramesPerThread: 5, eventSizeCapBytes: 10_000_000
        ))
        guard case let .string(roomyJson)? = roomy["crash.report_json"] else {
            return XCTFail("crash.report_json missing")
        }
        let roomyParsed = try JSONSerialization.jsonObject(with: Data(roomyJson.utf8)) as? [String: Any]
        let total = (roomyParsed?["binary_images"] as? [Any])?.count ?? 0
        XCTAssertGreaterThan(droppedImages, 0)
        XCTAssertEqual(droppedImages + images.count, total)
        if let regs = attrs["crash.registers.dropped"] {
            XCTAssertNotEqual(regs, .int(0), "omitted when zero, never sent as 0")
        }
    }

    func testRoomyCapOmitsC10Markers() throws {
        guard let data = CrashFixtureGenerator.makeLiveReport() else {
            throw XCTSkip("PLCrashReporter unavailable on this slice")
        }
        let attrs = try XCTUnwrap(CrashReportEncoder.encode(
            reportData: data, topFramesPerThread: 30, eventSizeCapBytes: 10_000_000
        ))
        XCTAssertNil(attrs["crash.registers.dropped"])
        XCTAssertNil(attrs["crash.binary_images.dropped"])
    }

    func testStackFramesUUIDMatchesReportImageUUID() throws {
        // One symbolication key format across `crash.report_json` and
        // the `*.binary_images` siblings of hang / error / long_task.
        guard let data = CrashFixtureGenerator.makeLiveReport() else {
            throw XCTSkip("PLCrashReporter unavailable on this slice")
        }
        let attrs = try XCTUnwrap(CrashReportEncoder.encode(
            reportData: data, topFramesPerThread: 30, eventSizeCapBytes: 10_000_000
        ))
        guard case let .string(json)? = attrs["crash.report_json"] else {
            return XCTFail("crash.report_json missing")
        }
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let reportImages = try XCTUnwrap(parsed["binary_images"] as? [[String: Any]])
        let frame = try XCTUnwrap(StackFrames.symbolicate(Thread.callStackReturnAddresses.map(\.uintValue)).first)
        let image = try XCTUnwrap(frame.image)
        let match = try XCTUnwrap(reportImages.first {
            (($0["name"] as? String ?? "") as NSString).lastPathComponent == image.name
        }, "report must list \(image.name)")
        XCTAssertEqual(match["uuid"] as? String, image.uuid)
    }

    // MARK: - C10 size-cap fallback (pure)

    private func fixtureDict() -> [String: Any] {
        [
            "threads": [
                ["number": 0, "crashed": true, "stack": ["0x0000000000001010"],
                 "registers": ["pc": "0x1010"]],
                ["number": 1, "crashed": false, "stack": ["0x0000000000003008"]]
            ],
            "binary_images": [
                ["name": "/A", "base_address": "4096", "size": "4096"],    // 0x1000 — referenced
                ["name": "/B", "base_address": "8192", "size": "4096"],    // 0x2000 — unreferenced
                ["name": "/C", "base_address": "12288", "size": "4096"],   // 0x3000 — referenced
                ["name": "/D", "base_address": "65536", "size": "4096"]    // unreferenced
            ]
        ]
    }

    private func imageNames(_ dict: [String: Any]) -> [String] {
        (dict["binary_images"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    func testSizeCapFitsUntouchedDropsNothing() {
        var dict = fixtureDict()
        let dropped = CrashReportEncoder.applySizeCap(to: &dict) { _ in true }
        XCTAssertEqual(dropped.registers, 0)
        XCTAssertEqual(dropped.images, 0)
        XCTAssertEqual(imageNames(dict), ["/A", "/B", "/C", "/D"])
    }

    func testSizeCapStripsRegistersFirst() {
        var dict = fixtureDict()
        var calls = 0
        let dropped = CrashReportEncoder.applySizeCap(to: &dict) { _ in calls += 1; return calls > 1 }
        XCTAssertEqual(dropped.registers, 1, "one thread carried registers")
        XCTAssertEqual(dropped.images, 0)
        let threads = dict["threads"] as? [[String: Any]] ?? []
        XCTAssertTrue(threads.allSatisfy { $0["registers"] == nil })
    }

    func testSizeCapDropsUnreferencedImagesBeforeReferenced() {
        var dict = fixtureDict()
        var calls = 0
        let dropped = CrashReportEncoder.applySizeCap(to: &dict) { _ in calls += 1; return calls > 2 }
        XCTAssertEqual(dropped.registers, 1)
        XCTAssertEqual(dropped.images, 2)
        XCTAssertEqual(imageNames(dict), ["/A", "/C"], "images kept frames point into survive")
    }

    func testSizeCapDropsReferencedImagesLast() {
        var dict = fixtureDict()
        let dropped = CrashReportEncoder.applySizeCap(to: &dict) { _ in false }
        XCTAssertEqual(dropped.images, 4)
        XCTAssertEqual(imageNames(dict), [])
    }

    // MARK: - crash.mach_exception (F33)

    func testMachExceptionNamesFromExceptionTypesHeader() {
        XCTAssertEqual(CrashReportEncoder.machExceptionName(1), "EXC_BAD_ACCESS")
        XCTAssertEqual(CrashReportEncoder.machExceptionName(10), "EXC_CRASH")
        XCTAssertEqual(CrashReportEncoder.machExceptionName(12), "EXC_GUARD")
        XCTAssertEqual(CrashReportEncoder.machExceptionName(99), "99")
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
