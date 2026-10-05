// Tests/EdgeRumCrashTests/HangEventEncoderTests.swift
//
// Pure-function coverage for the hang `app.crash` encoder. The
// encoder is the single seam between the watchdog's detection event
// and the wire — every attribute the backend dispatches on is set
// here, so the unit tests pin down all of them.
//
// Refs: PLAN-iOS.md §6.8, §F15/T15.2.
//

import XCTest
@testable import EdgeRumCrash
import EdgeRumCore

final class HangEventEncoderTests: XCTestCase {

    private let referenceTimestamp = Date(timeIntervalSince1970: 1_717_234_876.512)

    func testEncodeStampsCanonicalDiscriminators() {
        let attrs = HangEventEncoder.encode(
            durationMs: 5_240,
            thresholdMs: 5_000,
            cpuUsage: nil,
            stackFrames: [StackFrame(text: "frameA"), StackFrame(text: "frameB")],
            timestamp: referenceTimestamp
        )

        XCTAssertNil(attrs["cause"])
        XCTAssertEqual(attrs["runtime"], .string("native"))
        XCTAssertNil(attrs["crash.fatal"])
        XCTAssertEqual(attrs["hang.duration_ms"], .double(5_240))
        XCTAssertEqual(attrs["hang.threshold_ms"], .double(5_000))
        XCTAssertEqual(
            attrs["hang.timestamp"],
            .string(WireDateFormatter.string(from: referenceTimestamp))
        )
    }

    func testEncodeIncludesCpuUsageWhenProvided() {
        let attrs = HangEventEncoder.encode(
            durationMs: 5_240,
            thresholdMs: 5_000,
            cpuUsage: 83.0,
            stackFrames: [StackFrame(text: "frame")],
            timestamp: referenceTimestamp
        )
        XCTAssertEqual(attrs["hang.cpu_usage"], .double(83.0))
    }

    func testEncodeOmitsCpuUsageWhenUnavailable() {
        let attrs = HangEventEncoder.encode(
            durationMs: 5_240,
            thresholdMs: 5_000,
            cpuUsage: nil,
            stackFrames: [StackFrame(text: "frame")],
            timestamp: referenceTimestamp
        )
        XCTAssertNil(attrs["hang.cpu_usage"])
    }

    func testStackFallsBackToPlaceholderWhenSnapshotIsEmpty() {
        // T15.2 acceptance — `hang.stack` must always be
        // non-empty. When the Mach snapshot fails (empty array), the
        // encoder substitutes a placeholder so the wire still carries
        // a value.
        let attrs = HangEventEncoder.encode(
            durationMs: 5_240,
            thresholdMs: 5_000,
            cpuUsage: nil,
            stackFrames: [],
            timestamp: referenceTimestamp
        )
        guard case let .string(stack) = attrs["hang.stack"] else {
            return XCTFail("hang.stack must be set with a string value")
        }
        XCTAssertEqual(stack, HangEventEncoder.unavailableFrame)
        XCTAssertFalse(stack.isEmpty)
    }

    func testStackTruncatesAtTopFramesAndCountsDroppedFrames() {
        let early = StackImage(name: "App", uuid: "aa")
        let late = StackImage(name: "Late", uuid: "bb")
        let bigStack = (0..<60).map {
            StackFrame(text: "frame#\($0)", image: $0 < HangEventEncoder.topFrames ? early : late)
        }
        let attrs = HangEventEncoder.encode(
            durationMs: 5_240,
            thresholdMs: 5_000,
            cpuUsage: nil,
            stackFrames: bigStack,
            timestamp: referenceTimestamp
        )
        guard case let .string(stack) = attrs["hang.stack"] else {
            return XCTFail("hang.stack must be set with a string value")
        }
        let lines = stack.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, HangEventEncoder.topFrames,
                       "no in-string omission marker on hang.stack")
        XCTAssertEqual(lines.first, "frame#0")
        XCTAssertEqual(lines[HangEventEncoder.topFrames - 1],
                       "frame#\(HangEventEncoder.topFrames - 1)")
        XCTAssertFalse(stack.contains(CrashStackTruncator.omissionSuffix))
        XCTAssertEqual(attrs["hang.stack.truncated"], .int(60 - HangEventEncoder.topFrames))
        // Only images referenced by KEPT frames are listed.
        XCTAssertEqual(attrs["hang.binary_images"], .string(#"[{"name":"App","uuid":"aa"}]"#))
    }

    func testShortStackOmitsTruncatedAndImagelessOmitsBinaryImages() {
        let attrs = HangEventEncoder.encode(
            durationMs: 5_240,
            thresholdMs: 5_000,
            cpuUsage: nil,
            stackFrames: [StackFrame(text: "0x1234")],
            timestamp: referenceTimestamp
        )
        XCTAssertEqual(attrs["hang.stack"], .string("0x1234"))
        XCTAssertNil(attrs["hang.stack.truncated"])
        XCTAssertNil(attrs["hang.binary_images"])
    }

    func testAllAttributeValuesAreWirePrimitives() {
        // Wire contract: every attribute is a String / Int / Double /
        // Bool. The `AttributeValue` enum makes this checkable at the
        // type level, but pin it explicitly so a future encoder
        // tweak that breaks the invariant fails here.
        let attrs = HangEventEncoder.encode(
            durationMs: 5_240,
            thresholdMs: 5_000,
            cpuUsage: 0.5,
            stackFrames: [StackFrame(text: "frame")],
            timestamp: referenceTimestamp
        )
        for (_, value) in attrs {
            switch value {
            case .string, .int, .double, .bool:
                continue
            }
        }
    }
}
