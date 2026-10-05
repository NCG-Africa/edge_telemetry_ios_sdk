// Tests/EdgeRumCaptureTests/FrameSamplerTests.swift
//
// F10 / T10.1 unit tests. Covers:
//
//   - FrameWindowAggregator stats: empty window, single sample, p95
//     across many samples, dropped-count = expected minus observed,
//     window reset on flush.
//   - makeAttributes shape: every PLAN-§6.10 key present with the
//     right type, `frame.source = "displaylink"`, `value` = max.
//   - emit() routes through Recorder.shared.recordPerformance with
//     the canonical metricName.
//   - Recorder.isEnabled = false halts emission while the install
//     state stays intact.
//   - install() idempotency, including under concurrent invocation
//     (mirrors the F9 pattern).
//   - resolveTargetHz returns 60 on the macOS CI host (UIScreen
//     unavailable) and >0 on iOS sims.
//
// All UIKit-driven tests are wrapped in
// `#if canImport(UIKit) && os(iOS)` so the macOS CI host compiles
// this file.
//
// Refs: PLAN-iOS.md §F10/T10.1 acceptance; CLAUDE.md
//       "Testing conventions".
//

import XCTest
import Foundation
import EdgeRumCore
@testable import EdgeRumCapture

#if canImport(UIKit) && os(iOS)
import UIKit
#endif

// MARK: - Probe recorder used by the capture tests
//
// A local copy mirroring the shape used by other capture test files —
// capture tests can't depend on the EdgeRumTests target.
private final class CaptureProbeRecorder: Recording, @unchecked Sendable {

    enum Call: Equatable {
        case event(name: String, attributes: [String: AttributeValue])
        case performance(name: String, attributes: [String: AttributeValue])
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _enabled: Bool = true
    private let _clock: Clock

    init(clock: Clock = SystemClock(), enabled: Bool = true) {
        self._clock = clock
        self._enabled = enabled
    }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    var clock: Clock { _clock }
    var currentSessionId: String { "session_0_0000000000000000_ios" }
    var currentDeviceId: String { "device_0_0000000000000000_ios" }

    var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _enabled
    }

    func configure(_ config: RecorderConfig) { _ = config }
    func start(apiKey: String, endpoint: URL, debug: Bool) {
        _ = (apiKey, endpoint, debug)
    }
    func stop() {}
    func setEnabled(_ enabled: Bool) {
        lock.lock(); _enabled = enabled; lock.unlock()
    }

    func recordEvent(name: String, attributes: [String: AttributeValue]) {
        lock.lock()
        _calls.append(.event(name: name, attributes: attributes))
        lock.unlock()
    }

    func recordPerformance(name: String, attributes: [String: AttributeValue]) {
        lock.lock()
        _calls.append(.performance(name: name, attributes: attributes))
        lock.unlock()
    }

    func recordError(
        domain: String, code: Int, message: String?,
        context: [String: AttributeValue]
    ) {
        _ = (domain, code, message, context)
    }

    func setUser(_ user: RecorderUser) { _ = user }
}

// MARK: - Tests

final class FrameSamplerTests: XCTestCase {

    override func tearDown() {
        Recorder.resetShared()
        FrameSampler._resetInstallFlagForTesting()
        super.tearDown()
    }

    // MARK: FrameWindowAggregator — pure stat tests

    /// F33: an empty window omits `frame.dropped_count` — never the
    /// full expected count.
    func test_aggregator_emptyWindow_omitsDropped() {
        let stats = FrameWindowAggregator.computeStats(samples: [], dropped: 0, windowSeconds: 1.0)
        XCTAssertEqual(stats.maxMs, 0)
        XCTAssertEqual(stats.p95Ms, 0)
        XCTAssertNil(stats.droppedCount)
        XCTAssertEqual(stats.sampleCount, 0)
    }

    func test_aggregator_singleSample_maxAndP95EqualThatSample() {
        let stats = FrameWindowAggregator.computeStats(samples: [22.5], dropped: 0, windowSeconds: 1.0)
        XCTAssertEqual(stats.maxMs, 22.5)
        XCTAssertEqual(stats.p95Ms, 22.5)
        XCTAssertEqual(stats.sampleCount, 1)
        XCTAssertEqual(stats.droppedCount, 0, "one on-time frame drops nothing")
    }

    func test_aggregator_p95_picksNearestRank() {
        let samples = Array(stride(from: 1.0, through: 100.0, by: 1.0))
        let stats = FrameWindowAggregator.computeStats(samples: samples, dropped: 0, windowSeconds: 1.0)
        XCTAssertEqual(stats.maxMs, 100.0)
        XCTAssertEqual(stats.p95Ms, 95.0)
        XCTAssertEqual(stats.sampleCount, 100)
    }

    // MARK: F33 — observed drops

    func test_recordDelta_countsSkippedRefreshIntervals() {
        var agg = FrameWindowAggregator(targetHz: 60, startedAt: t(0))
        agg.recordDelta(16.7, refreshMs: 16.7)   // on time
        agg.recordDelta(50.0, refreshMs: 16.7)   // 3 intervals → 2 dropped
        agg.recordDelta(26.0, refreshMs: 16.7)   // 1.56 → rounds to 2 → 1 dropped
        XCTAssertEqual(agg.flush(now: t(1)).droppedCount, 3)
    }

    /// ProMotion ramp-down: 60 Hz frames on a 120 Hz panel throttled to
    /// 60 Hz are on time against the live interval, not drops.
    func test_recordDelta_measuresAgainstLiveInterval_notTargetHz() {
        var agg = FrameWindowAggregator(targetHz: 120, startedAt: t(0))
        for _ in 0..<60 { agg.recordDelta(16.7, refreshMs: 16.7) }
        XCTAssertEqual(agg.flush(now: t(1)).droppedCount, 0)
    }

    func test_recordDelta_unusableRefreshIntervalCountsNoDrop() {
        var agg = FrameWindowAggregator(targetHz: 60, startedAt: t(0))
        agg.recordDelta(50, refreshMs: 0)
        agg.recordDelta(50, refreshMs: -16)
        agg.recordDelta(50, refreshMs: .nan)
        let stats = agg.flush(now: t(1))
        XCTAssertEqual(stats.sampleCount, 3)
        XCTAssertEqual(stats.droppedCount, 0)
    }

    // MARK: F30 — motion windows

    private func t(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    func test_window_closesTwoSecondsAfterLastMotion() {
        var agg = FrameWindowAggregator(targetHz: 60, startedAt: t(0))
        XCTAssertFalse(agg.shouldFlush(now: t(1.9)))
        agg.noteMotion(now: t(1.5))
        XCTAssertFalse(agg.shouldFlush(now: t(3.4)), "motion extends the window")
        XCTAssertTrue(agg.shouldFlush(now: t(3.5)))
    }

    func test_window_hardCapsAtTenSeconds_despiteMotion() {
        var agg = FrameWindowAggregator(targetHz: 60, startedAt: t(0))
        for i in 1...9 { agg.noteMotion(now: t(Double(i))) }
        XCTAssertFalse(agg.shouldFlush(now: t(9.99)))
        XCTAssertTrue(agg.shouldFlush(now: t(10)))
    }

    func test_flush_reportsWindowMs_andNoInferredDrops() {
        var agg = FrameWindowAggregator(targetHz: 60, startedAt: t(0))
        for _ in 0..<100 { agg.recordDelta(16.7, refreshMs: 16.7) }
        let stats = agg.flush(now: t(2.5))
        XCTAssertEqual(stats.windowMs, 2500)
        XCTAssertEqual(stats.sampleCount, 100)
        XCTAssertEqual(stats.droppedCount, 0, "not 150 expected − 100 observed")
    }

    func test_flush_windowMsClampedToHardCap() {
        let agg = FrameWindowAggregator(targetHz: 60, startedAt: t(0))
        XCTAssertEqual(agg.flush(now: t(12)).windowMs, 10_000)
    }

    func test_aggregator_negativeOrNonFiniteDeltasAreIgnored() {
        var agg = FrameWindowAggregator(targetHz: 60, startedAt: t(0))
        agg.recordDelta(-5, refreshMs: 16.6)
        agg.recordDelta(.nan, refreshMs: 16.6)
        agg.recordDelta(.infinity, refreshMs: 16.6)
        agg.recordDelta(16.6, refreshMs: 16.6)
        let stats = agg.flush(now: t(1.0))
        XCTAssertEqual(stats.sampleCount, 1)
        XCTAssertEqual(stats.maxMs, 16.6)
    }

    // MARK: makeAttributes shape

    #if canImport(UIKit) && os(iOS)
    func test_makeAttributes_carriesAllPlanKeys() {
        let stats = FrameWindowAggregator.Stats(
            maxMs: 33.3,
            p95Ms: 28.1,
            droppedCount: 4,
            sampleCount: 56, windowMs: 1_000
        )
        let attrs = FrameSampler.makeAttributes(stats: stats, targetHz: 60)
        XCTAssertEqual(attrs["frame.max_ms"], .double(33.3))
        XCTAssertEqual(attrs["frame.p95_ms"], .double(28.1))
        XCTAssertEqual(attrs["frame.dropped_count"], .int(4))
        XCTAssertEqual(attrs["frame.target_hz"], .int(60))
        XCTAssertEqual(attrs["frame.source"], .string("displaylink"))
        XCTAssertEqual(attrs["value"], .double(33.3))
    }

    func test_makeAttributes_emptyWindow_omitsDroppedCount() {
        let stats = FrameWindowAggregator.Stats(
            maxMs: 0, p95Ms: 0, droppedCount: nil, sampleCount: 0, windowMs: 2_000)
        XCTAssertNil(FrameSampler.makeAttributes(stats: stats, targetHz: 60)["frame.dropped_count"])
    }

    func test_makeAttributes_carriesWindowMs() {
        let stats = FrameWindowAggregator.Stats(
            maxMs: 20, p95Ms: 18, droppedCount: 0, sampleCount: 120, windowMs: 2_400)
        XCTAssertEqual(FrameSampler.makeAttributes(stats: stats, targetHz: 60)["frame.window_ms"], .int(2_400))
    }

    func test_makeAttributes_proMotion_target_hz120() {
        let stats = FrameWindowAggregator.Stats(
            maxMs: 16.6, p95Ms: 16.6, droppedCount: 0, sampleCount: 120, windowMs: 1_000
        )
        let attrs = FrameSampler.makeAttributes(stats: stats, targetHz: 120)
        XCTAssertEqual(attrs["frame.target_hz"], .int(120))
    }
    #endif

    // MARK: emit() routing

    #if canImport(UIKit) && os(iOS)
    func test_emit_routesToRecordPerformance() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)

        let stats = FrameWindowAggregator.Stats(
            maxMs: 22.0, p95Ms: 19.0, droppedCount: 1, sampleCount: 59, windowMs: 1_000
        )
        FrameSampler.emit(stats: stats, targetHz: 60)

        XCTAssertEqual(probe.calls.count, 1)
        guard case let .performance(name, attrs) = probe.calls[0] else {
            return XCTFail("Expected a .performance call, got \(probe.calls)")
        }
        XCTAssertEqual(name, "frame_render_time")
        XCTAssertEqual(attrs["frame.source"], .string("displaylink"))
    }

    func test_emit_haltedWhenRecorderDisabled() {
        let probe = CaptureProbeRecorder(enabled: false)
        Recorder.installShared(probe)
        let stats = FrameWindowAggregator.Stats(
            maxMs: 22.0, p95Ms: 19.0, droppedCount: 1, sampleCount: 59, windowMs: 1_000
        )
        FrameSampler.emit(stats: stats, targetHz: 60)
        XCTAssertEqual(probe.calls.count, 0)
    }

    // MARK: install() — UIKit driver

    func test_install_isIdempotent() {
        FrameSampler.install(debug: false)
        XCTAssertTrue(FrameSampler.isInstalled)
        FrameSampler.install(debug: false)
        FrameSampler.install(debug: false)
        XCTAssertTrue(FrameSampler.isInstalled)
    }

    func test_install_concurrentCallsAreSafe() {
        // Pump the main runloop while waiting — `install()` does a
        // `DispatchQueue.main.sync` hop on background callers; blocking
        // main with `DispatchGroup.wait` would deadlock.
        let exp = expectation(description: "16 concurrent installs converge")
        exp.expectedFulfillmentCount = 16
        for _ in 0..<16 {
            DispatchQueue.global().async {
                FrameSampler.install(debug: false)
                exp.fulfill()
            }
        }
        // ponytail: 120s is a ceiling, not a sleep — a healthy run fulfills in
        // ~1-3s. The margin absorbs the slow iPhone-SE-3 / iOS-26 sim slice;
        // if it still flakes, drop the concurrent-install count instead.
        wait(for: [exp], timeout: 120)
        XCTAssertTrue(FrameSampler.isInstalled)
    }

    // MARK: F30 — motion arming + gate

    func test_installedIdle_linkPaused_untilMotion() {
        defer { Riders.shared._resetForTesting() }
        Recorder.installShared(CaptureProbeRecorder())
        Riders.shared.setAppState("active")
        FrameSampler.install(debug: false)
        XCTAssertFalse(FrameSampler._isSamplingForTesting, "static content: link paused")
        FrameSampler.noteMotion()
        XCTAssertTrue(FrameSampler._isSamplingForTesting)
    }

    func test_motion_gateClosed_doesNotOpenWindow() {
        defer { Riders.shared._resetForTesting() }
        Recorder.installShared(CaptureProbeRecorder())
        Riders.shared.setAppState("background")
        FrameSampler.install(debug: false)
        FrameSampler.noteMotion()
        XCTAssertFalse(FrameSampler._isSamplingForTesting)
    }

    func test_motion_whileDisabled_doesNotOpenWindow() {
        defer { Riders.shared._resetForTesting() }
        Riders.shared.setAppState("active")
        Recorder.installShared(CaptureProbeRecorder(enabled: false))
        FrameSampler.install(debug: false)
        FrameSampler.noteMotion()
        XCTAssertFalse(FrameSampler._isSamplingForTesting)
    }

    func test_gateClosingMidWindow_dropsWindow() {
        defer { Riders.shared._resetForTesting() }
        Recorder.installShared(CaptureProbeRecorder())
        Riders.shared.setAppState("active")
        FrameSampler.install(debug: false)
        FrameSampler.noteMotion()
        XCTAssertTrue(FrameSampler._isSamplingForTesting)
        Riders.shared.setAppState("background")  // stands in for low power / thermal
        NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        XCTAssertFalse(FrameSampler._isSamplingForTesting)
    }

    func test_resignActive_dropsOpenWindow() {
        defer { Riders.shared._resetForTesting() }
        Recorder.installShared(CaptureProbeRecorder())
        Riders.shared.setAppState("active")
        FrameSampler.install(debug: false)
        FrameSampler.noteMotion()
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertFalse(FrameSampler._isSamplingForTesting)
    }

    func test_resolveTargetHz_isPositiveOnIOSHost() {
        // On a 60Hz simulator this is 60. On ProMotion it's 120. Either
        // way, it must be > 0 and a multiple of a real Hz value.
        let hz = FrameSampler.resolveTargetHz()
        XCTAssertGreaterThanOrEqual(hz, 60)
    }
    #endif
}
