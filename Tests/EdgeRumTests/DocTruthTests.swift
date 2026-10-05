// Tests/EdgeRumTests/DocTruthTests.swift
//
// F26 (#213) — one test per doc claim made true in tranche 1:
// `flushInterval` timer, `maxQueueSize` in events, whole-process CPU
// reader. Refs: docs/specs/rum-coverage-roadmap.md "Tranche 1".
//

import XCTest
@testable import EdgeRumCore

final class DocTruthTests: XCTestCase {

    private func makeRecorder(flushInterval: TimeInterval) -> (Recorder, RecordingTransportSink) {
        let sink = RecordingTransportSink()
        let recorder = Recorder(
            clock: FixedClock(Date(timeIntervalSince1970: 1_717_234_876)),
            sampler: Sampler(sampleRate: 1.0, entropy: { 0.0 }),
            transport: sink
        )
        recorder.setEnabled(true)
        recorder.configure(RecorderConfig(
            apiKey: "edge_test_abc",
            endpoint: URL(string: "https://collect.example.com")!, // test literal
            flushInterval: flushInterval
        ))
        return (recorder, sink)
    }

    private func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    // MARK: C2 — flushInterval timer

    func testQuietSessionFlushesWithinFlushInterval() {
        let (recorder, sink) = makeRecorder(flushInterval: 0.1)
        recorder.recordEvent(name: "navigation", attributes: [:])
        XCTAssertTrue(waitFor(2) { sink.sends.contains { $0.reason == .timer } })
        XCTAssertEqual(sink.envelopes.first?.events.count, 1)
    }

    func testDisableStopsFlushTimer() {
        let (recorder, sink) = makeRecorder(flushInterval: 0.05)
        recorder.recordEvent(name: "navigation", attributes: [:])
        recorder.setEnabled(false)
        XCTAssertFalse(waitFor(0.3) { !sink.sends.isEmpty })
    }

    // MARK: C3 — maxQueueSize counts events

    func testOfflineQueueTrimsByEventCount() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edge-rum-doctruth-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var epoch: Int64 = 1_717_000_000_000
        let queue = try XCTUnwrap(OfflineQueue(directory: dir, maxQueueSize: 50) {
            defer { epoch += 1 }; return epoch
        })
        queue.enqueue(Data("a".utf8), eventCount: 30)
        queue.enqueue(Data("b".utf8), eventCount: 20)
        XCTAssertEqual(queue.count, 2, "50 events fit a 50-event cap")
        queue.enqueue(Data("c".utf8), eventCount: 10)
        let remaining = try queue.orderedFiles().map { try Data(contentsOf: $0) }
        XCTAssertEqual(remaining, [Data("b".utf8), Data("c".utf8)], "oldest batch trimmed to ≤ cap")
        XCTAssertTrue(queue.orderedFiles().last?.lastPathComponent.hasSuffix("-10.json") ?? false)
    }

    // MARK: C4 — whole-process CPU reader

    func testCPUReaderReportsBusyProcess() throws {
        let reader = ProcessCPUReader()
        let end = Date().addingTimeInterval(0.2)
        var x = 0.0
        while Date() < end { x += sin(x) }  // burn one core
        XCTAssertNotEqual(x, -1)
        let percent = try XCTUnwrap(reader.sample())
        XCTAssertGreaterThan(percent, 20, "a spinning thread is visible as per-core percent")
    }
}
