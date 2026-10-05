// Tests/EdgeRumTests/BreadcrumbsTests.swift
//
// F31 / #218 — RUM coverage tranche 6 ("Breadcrumbs"). Acceptance:
//
//   - a `sampleRate = 0` session still keeps a trail, on disk, that a
//     replayed crash attaches when `session.id` matches
//   - a `session.id` mismatch drops the trail and counts it
//   - a retry-looping `captureError` attaches the ring once
//   - an idle app writes nothing
//
// Plus the row rule (events only, never metrics or forced-emit), the
// projection, eviction / truncation counting and clear-on-rotation.
//
// Refs: docs/specs/rum-coverage-roadmap.md § Tranche 6.

import XCTest
@testable import EdgeRum
import EdgeRumCore

final class BreadcrumbsTests: XCTestCase {

    // MARK: Helpers

    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edge-rum-crumbs-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private var fileURL: URL { dir.appendingPathComponent("breadcrumbs.json") }

    private func makeRecorder(
        sampleRate: Double = 1.0,
        crumbs: Breadcrumbs,
        clock: FixedClock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.000))
    ) -> (Recorder, RecordingTransportSink) {
        let sink = RecordingTransportSink()
        let recorder = Recorder(
            clock: clock,
            sessionManager: SessionManager(store: InMemorySessionStore(), clock: clock),
            sampler: Sampler(sampleRate: sampleRate, entropy: { 0.5 }),
            transport: sink,
            sdkVersion: "1.0.0",
            riders: Riders(),
            breadcrumbs: crumbs
        )
        recorder.configure(RecorderConfig(
            apiKey: "edge_test_abc",
            endpoint: URL(string: "https://collect.example.com")!,
            sampleRate: sampleRate,
            batchSize: 1_000
        ))
        recorder.setEnabled(true)
        return (recorder, sink)
    }

    private func makeCrumbs() -> Breadcrumbs {
        let crumbs = Breadcrumbs(persistDelay: 0.01)
        crumbs.configure(capturing: true, url: fileURL)
        return crumbs
    }

    private func events(_ sink: RecordingTransportSink, _ name: String) -> [AttributeBag] {
        sink.envelopes.flatMap(\.events).compactMap {
            if case let .event(n, _, attrs) = $0, n == name { return attrs }
            return nil
        }
    }

    private func decodeRows(_ value: AttributeValue?) throws -> [Breadcrumbs.Row] {
        guard case let .string(json)? = value else { throw XCTSkip("no breadcrumbs attribute") }
        return try JSONDecoder().decode([Breadcrumbs.Row].self, from: Data(json.utf8))
    }

    // MARK: Acceptance

    func testUnsampledSessionCrashReplaysWithPriorRing() throws {
        let crumbs = makeCrumbs()
        let (recorder, _) = makeRecorder(sampleRate: 0, crumbs: crumbs)
        recorder.recordEvent(name: "navigation", attributes: ["navigation.screen": .string("Cart")])
        recorder.recordEvent(name: "custom_event", attributes: ["event.name": .string("pay")])
        crumbs._drainForTesting()

        let prior = try XCTUnwrap(Breadcrumbs.takePrior(url: fileURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "deleted on read")
        XCTAssertEqual(prior.sessionId, recorder.currentSessionId)

        let attrs = Breadcrumbs.replayAttributes(prior, sessionId: recorder.currentSessionId)
        let rows = try decodeRows(attrs["breadcrumbs"])
        XCTAssertEqual(rows.map(\.n), ["navigation", "custom_event"], "oldest first")
        XCTAssertEqual(rows.map(\.l), ["Cart", "pay"])
        XCTAssertNil(attrs["breadcrumb.dropped"])
    }

    func testSessionIdMismatchDropsTrailAndCountsIt() {
        let file = Breadcrumbs.File(
            sessionId: "session_1_aaaaaaaaaaaaaaaa_ios", seq: 7, truncated: 0,
            rows: [.init(t: 1, n: "navigation", l: "A", s: nil)]
        )
        let attrs = Breadcrumbs.replayAttributes(file, sessionId: "session_2_bbbbbbbbbbbbbbbb_ios")
        XCTAssertNil(attrs["breadcrumbs"])
        XCTAssertEqual(attrs["breadcrumb.dropped"], .int(7))
        XCTAssertEqual(Breadcrumbs.replayAttributes(file, sessionId: nil)["breadcrumb.dropped"], .int(7))
    }

    func testRetryLoopingCaptureErrorAttachesRingOnce() {
        let (recorder, sink) = makeRecorder(crumbs: makeCrumbs())
        recorder.recordEvent(name: "navigation", attributes: ["navigation.screen": .string("Home")])
        for _ in 0..<3 {
            recorder.recordEvent(name: "app.error", attributes: ["error.message": .string("boom")])
        }
        recorder.recordEvent(name: "app.hang", attributes: [:])
        recorder.flush(reason: .shutdown)

        let errors = events(sink, "app.error")
        XCTAssertEqual(errors.count, 3)
        XCTAssertNotNil(errors[0]["breadcrumbs"])
        XCTAssertNil(errors[1]["breadcrumbs"])
        XCTAssertNil(errors[2]["breadcrumbs"])
        XCTAssertNil(events(sink, "app.hang").first?["breadcrumbs"], "once per session across producers")
    }

    func testIdleAppWritesNothing() throws {
        let crumbs = makeCrumbs()
        _ = makeRecorder(crumbs: crumbs)
        crumbs._drainForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "no crumbs → no write")
    }

    func testBurstCoalescesIntoOneSnapshot() throws {
        let crumbs = Breadcrumbs(persistDelay: 0.2)
        crumbs.configure(capturing: true, url: fileURL)
        let (recorder, _) = makeRecorder(crumbs: crumbs)
        for i in 0..<20 {
            recorder.recordEvent(name: "custom_event", attributes: ["event.name": .string("e\(i)")])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "nothing before the window")
        crumbs._drainForTesting()
        let written = try XCTUnwrap(Breadcrumbs.takePrior(url: fileURL))
        XCTAssertEqual(written.rows.count, 20)
        XCTAssertEqual(written.seq, 20)
        // Nothing new arrived → nothing rewritten.
        crumbs._drainForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: Row rule

    func testMetricsAndForcedEmitNamesAreNotCrumbed() {
        let crumbs = makeCrumbs()
        let (recorder, _) = makeRecorder(crumbs: crumbs)
        recorder.recordPerformance(name: "memory_usage", attributes: ["value": .double(1)])
        recorder.recordEvent(name: "network_change", attributes: [:])
        recorder.recordEvent(name: "page_load", attributes: [:])
        XCTAssertEqual(crumbs._rowsForTesting.map(\.n), ["page_load"])
        XCTAssertNil(crumbs._rowsForTesting.first?.l)
    }

    func testDisabledRecorderOrCaptureOffRecordsNothing() {
        let crumbs = makeCrumbs()
        let (recorder, _) = makeRecorder(crumbs: crumbs)
        recorder.setEnabled(false)
        recorder.recordEvent(name: "page_load", attributes: [:])
        XCTAssertTrue(crumbs._rowsForTesting.isEmpty)

        recorder.setEnabled(true)
        crumbs.configure(capturing: false, url: fileURL)
        recorder.recordEvent(name: "page_load", attributes: [:])
        XCTAssertTrue(crumbs._rowsForTesting.isEmpty)
        XCTAssertTrue(crumbs.attachOnce().isEmpty)
    }

    func testProjection() {
        let crumbs = makeCrumbs()
        let (recorder, _) = makeRecorder(crumbs: crumbs)
        recorder.recordEvent(name: "http.request", attributes: [
            "http.method": .string("GET"), "http.path": .string("/v1/orders"),
            "http.url": .string("https://x/v1/orders?token=secret"), "http.status_code": .int(500)
        ])
        recorder.recordEvent(name: "app_lifecycle", attributes: ["lifecycle.state": .string("backgrounded")])
        recorder.recordEvent(name: "user.interaction", attributes: ["interaction.target": .string("UIButton")])
        recorder.recordEvent(name: "user.interaction", attributes: [
            "interaction.name": .string("pay"), "interaction.target": .string("UIButton")
        ])
        let rows = crumbs._rowsForTesting
        XCTAssertEqual(rows[0], .init(t: 1_717_234_876_000, n: "http.request", l: "GET /v1/orders", s: 500))
        XCTAssertEqual(rows.map(\.l), ["GET /v1/orders", "backgrounded", "UIButton", "pay"])
    }

    /// F33 (ADR-024 #3): a replayed terminated hang gets no live trail;
    /// the next live hang still takes it.
    func testReplayedTerminatedHangDoesNotTakeTheTrail() {
        let crumbs = makeCrumbs()
        let (recorder, sink) = makeRecorder(crumbs: crumbs)
        recorder.recordEvent(name: "custom_event", attributes: ["event.name": .string("pay")])
        recorder.recordEvent(name: "app.hang", attributes: ["hang.terminated": .bool(true)])
        recorder.recordEvent(name: "app.hang", attributes: [:])
        recorder.flush(reason: .manual)
        let hangs = events(sink, "app.hang")
        XCTAssertEqual(hangs.count, 2)
        XCTAssertNil(hangs[0]["breadcrumbs"])
        XCTAssertNotNil(hangs[1]["breadcrumbs"])
    }

    func testEvictionAndTruncationAreCounted() throws {
        let crumbs = makeCrumbs()
        let (recorder, _) = makeRecorder(crumbs: crumbs)
        recorder.recordEvent(name: "custom_event", attributes: ["event.name": .string(String(repeating: "é", count: 100))])
        for i in 0..<(Breadcrumbs.capacity + 4) {
            recorder.recordEvent(name: "custom_event", attributes: ["event.name": .string("e\(i)")])
        }
        let attrs = crumbs.attachOnce()
        let rows = try decodeRows(attrs["breadcrumbs"])
        XCTAssertEqual(rows.count, Breadcrumbs.capacity)
        XCTAssertEqual(rows.last?.l, "e\(Breadcrumbs.capacity + 3)")
        // 105 recorded − 100 present + 1 truncated label.
        XCTAssertEqual(attrs["breadcrumb.dropped"], .int(6))
    }

    func testLabelCappedAt128BytesOnCharacterBoundary() {
        let crumbs = makeCrumbs()
        let (recorder, _) = makeRecorder(crumbs: crumbs)
        recorder.recordEvent(name: "custom_event", attributes: ["event.name": .string(String(repeating: "é", count: 100))])
        let label = crumbs._rowsForTesting.first?.l ?? ""
        XCTAssertEqual(label.utf8.count, Breadcrumbs.labelCapBytes)
        XCTAssertEqual(label, String(repeating: "é", count: 64))
    }

    func testRotationAndResetIdentityDeleteTheFile() {
        let crumbs = makeCrumbs()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.000))
        let (recorder, _) = makeRecorder(crumbs: crumbs, clock: clock)
        recorder.recordEvent(name: "page_load", attributes: [:])
        crumbs._drainForTesting()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        clock.advance(by: 31 * 60)
        recorder.recordPerformance(name: "memory_usage", attributes: ["value": .double(1)])  // rotates, no crumb
        crumbs._drainForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "no stale trail after rotation")

        recorder.recordEvent(name: "page_load", attributes: [:])
        recorder.resetIdentity()
        crumbs._drainForTesting()
        XCTAssertTrue(crumbs._rowsForTesting.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "no pre-erasure trail")
    }

    func testRingClearedOnRotation() {
        let crumbs = makeCrumbs()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.000))
        let (recorder, sink) = makeRecorder(crumbs: crumbs, clock: clock)
        recorder.recordEvent(name: "page_load", attributes: [:])
        recorder.recordEvent(name: "app.error", attributes: [:])  // spends this session's attach
        clock.advance(by: 31 * 60)
        recorder.recordEvent(name: "navigation", attributes: ["navigation.screen": .string("B")])
        XCTAssertEqual(crumbs._rowsForTesting.map(\.n), ["navigation"])
        recorder.recordEvent(name: "app.error", attributes: [:])
        recorder.flush(reason: .shutdown)
        XCTAssertNotNil(events(sink, "app.error").last?["breadcrumbs"], "new session → attach re-armed")
    }
}
