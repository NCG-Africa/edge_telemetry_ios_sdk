// Tests/EdgeRumCrashTests/CrashStackTruncatorTests.swift
//
// T14.4 coverage. Pure unit tests over `CrashStackTruncator`; no
// PLCR fixture required.
//
// Refs: PLAN-iOS.md §F14/T14.4.
//

import XCTest
@testable import EdgeRumCrash

final class CrashStackTruncatorTests: XCTestCase {

    func testEmptyFramesProduceNoMarker() {
        let (kept, marker) = CrashStackTruncator.truncate(frames: [], topN: 30)
        XCTAssertTrue(kept.isEmpty)
        XCTAssertNil(marker)
    }

    func testFewerThanTopNPassesThrough() {
        let frames = (0..<5).map { "0x\($0)" }
        let (kept, marker) = CrashStackTruncator.truncate(frames: frames, topN: 30)
        XCTAssertEqual(kept, frames)
        XCTAssertNil(marker)
    }

    func testExactlyTopNPassesThrough() {
        let frames = (0..<30).map { "0x\($0)" }
        let (kept, marker) = CrashStackTruncator.truncate(frames: frames, topN: 30)
        XCTAssertEqual(kept.count, 30)
        XCTAssertNil(marker)
    }

    func testTwoHundredFramesTruncatedToTopThirtyPlusMarker() {
        let frames = (0..<200).map { "0x\(String($0, radix: 16))" }
        let (kept, marker) = CrashStackTruncator.truncate(frames: frames, topN: 30)
        XCTAssertEqual(kept.count, 30, "top-30 frames kept verbatim")
        XCTAssertEqual(kept, Array(frames.prefix(30)),
                       "kept frames are the first 30 from the stack")
        XCTAssertEqual(marker, "…170 more…",
                       "marker reports the count of dropped frames")
    }

    func testTopNOfZeroDropsEverythingAndMarksTotal() {
        let frames = (0..<10).map { "0x\($0)" }
        let (kept, marker) = CrashStackTruncator.truncate(frames: frames, topN: 0)
        XCTAssertEqual(kept, [])
        XCTAssertEqual(marker, "…10 more…")
    }

    func testMarkerFormatMatchesSpec() {
        // PLAN-iOS.md §F14/T14.4 — "…N more…" marker shape.
        XCTAssertEqual(CrashStackTruncator.marker(for: 42), "…42 more…")
        XCTAssertEqual(CrashStackTruncator.marker(for: 1), "…1 more…")
    }
}
