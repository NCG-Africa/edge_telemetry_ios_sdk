// Tests/EdgeRumTests/Transport/OfflineQueueTests.swift
//
// PLAN-iOS.md §F5/T5.3 acceptance:
//
//   - Filling past `maxQueueSize` drops the OLDEST file first.
//   - Drain reads files in chronological order, deletes on success,
//     leaves on failure (and aborts further drain on failure).
//   - Filename layout `<epochMs>-<seq>-<n>.json` keeps lexicographic order
//     matching chronological order.
//

import XCTest
@testable import EdgeRumCore

final class OfflineQueueTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edge-rum-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testEnqueueWritesAtomicAndIsListable() throws {
        let queue = makeQueue(maxQueueSize: 10)
        XCTAssertNotNil(queue.enqueue(Data("first".utf8), eventCount: 1))
        XCTAssertNotNil(queue.enqueue(Data("second".utf8), eventCount: 1))
        let files = queue.orderedFiles()
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].pathExtension, "json")
    }

    func testOrderingIsChronological() throws {
        var epoch: Int64 = 1_717_000_000_000
        let queue = makeQueue(maxQueueSize: 10) { defer { epoch += 1 }; return epoch }

        XCTAssertNotNil(queue.enqueue(Data("a".utf8), eventCount: 1))
        XCTAssertNotNil(queue.enqueue(Data("b".utf8), eventCount: 1))
        XCTAssertNotNil(queue.enqueue(Data("c".utf8), eventCount: 1))

        let files = queue.orderedFiles()
        let payloads = try files.map { try Data(contentsOf: $0) }
        XCTAssertEqual(payloads, [Data("a".utf8), Data("b".utf8), Data("c".utf8)])
    }

    func testOverflowDropsOldestFirst() throws {
        var epoch: Int64 = 1_717_000_000_000
        let queue = makeQueue(maxQueueSize: 2) { defer { epoch += 1 }; return epoch }

        XCTAssertNotNil(queue.enqueue(Data("first".utf8), eventCount: 1))
        XCTAssertNotNil(queue.enqueue(Data("second".utf8), eventCount: 1))
        XCTAssertNotNil(queue.enqueue(Data("third".utf8), eventCount: 1))

        // After overflow trim we expect "second" and "third" only.
        let payloads = try queue.orderedFiles().map { try Data(contentsOf: $0) }
        XCTAssertEqual(payloads, [Data("second".utf8), Data("third".utf8)])
    }

    func testDrainSuccessRemovesFiles() throws {
        let queue = makeQueue(maxQueueSize: 10)
        XCTAssertNotNil(queue.enqueue(Data("a".utf8), eventCount: 1))
        XCTAssertNotNil(queue.enqueue(Data("b".utf8), eventCount: 1))

        let drained = queue.drain { _, _ in true }
        XCTAssertEqual(drained, 2)
        XCTAssertEqual(queue.count, 0)
    }

    func testDrainFailureStopsAndKeepsRemainingFiles() throws {
        var epoch: Int64 = 1_717_000_000_000
        let queue = makeQueue(maxQueueSize: 10) { defer { epoch += 1 }; return epoch }

        XCTAssertNotNil(queue.enqueue(Data("a".utf8), eventCount: 1))
        XCTAssertNotNil(queue.enqueue(Data("b".utf8), eventCount: 1))
        XCTAssertNotNil(queue.enqueue(Data("c".utf8), eventCount: 1))

        var seen: [Data] = []
        let drained = queue.drain { payload, _ in
            seen.append(payload)
            // Succeed on the first two, fail on the third.
            return seen.count < 3
        }
        XCTAssertEqual(drained, 2)
        XCTAssertEqual(seen, [Data("a".utf8), Data("b".utf8), Data("c".utf8)])
        // "c" remains on disk because its drain returned false.
        let remaining = try queue.orderedFiles().map { try Data(contentsOf: $0) }
        XCTAssertEqual(remaining, [Data("c".utf8)])
    }

    func testReset() throws {
        let queue = makeQueue(maxQueueSize: 10)
        XCTAssertNotNil(queue.enqueue(Data("payload".utf8), eventCount: 1))
        XCTAssertEqual(queue.count, 1)
        queue.reset()
        XCTAssertEqual(queue.count, 0)
    }

    func testInitReturnsNilWhenDirectoryUnresolvable() {
        // OfflineQueue(directory: nil, ...) is filtered through the
        // failable init; we pass nil explicitly.
        let q = OfflineQueue(directory: nil)
        XCTAssertNil(q)
    }

    // MARK: Helpers

    private func makeQueue(
        maxQueueSize: Int,
        clockEpochMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        health: SdkHealth = SdkHealth()
    ) -> OfflineQueue {
        OfflineQueue(
            directory: tempDir,
            maxQueueSize: maxQueueSize,
            clockEpochMs: clockEpochMs,
            health: health
        )!
    }

    // MARK: F32 health

    func testOverflowCountsEventsNotFiles() {
        var epoch: Int64 = 1_717_000_000_000
        let health = SdkHealth()
        let queue = makeQueue(maxQueueSize: 50, clockEpochMs: { defer { epoch += 1 }; return epoch }, health: health)

        queue.enqueue(Data(repeating: 0x61, count: 100), eventCount: 30)
        queue.enqueue(Data(repeating: 0x62, count: 100), eventCount: 30)  // trims the first

        let snap = health.snapshot()
        XCTAssertEqual(snap["sdk.events_dropped.queue_overflow"], .int(30), "one file overflow = its events")
        XCTAssertEqual(snap["sdk.queue_depth_max"], .int(30))
        XCTAssertEqual(snap["sdk.storage_bytes_max"], .int(100))
    }

    func testDrainHandsEachFilesEventCountAndRecordsHighWater() {
        let health = SdkHealth()
        let queue = makeQueue(maxQueueSize: 200, health: health)
        queue.enqueue(Data("x".utf8), eventCount: 7)

        var counts: [Int] = []
        queue.drain { _, n in counts.append(n); return true }

        XCTAssertEqual(counts, [7])
        XCTAssertEqual(health.snapshot()["sdk.queue_depth_max"], .int(7))
    }
}
