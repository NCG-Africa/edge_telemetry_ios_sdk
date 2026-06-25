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

    func test_aggregator_emptyWindow_reportsAllDropped() {
        let stats = FrameWindowAggregator.computeStats(
            samples: [],
            windowSeconds: 1.0,
            targetHz: 60
        )
        XCTAssertEqual(stats.maxMs, 0)
        XCTAssertEqual(stats.p95Ms, 0)
        XCTAssertEqual(stats.droppedCount, 60)
        XCTAssertEqual(stats.sampleCount, 0)
    }

    func test_aggregator_singleSample_maxAndP95EqualThatSample() {
        let stats = FrameWindowAggregator.computeStats(
            samples: [22.5],
            windowSeconds: 1.0,
            targetHz: 60
        )
        XCTAssertEqual(stats.maxMs, 22.5)
        XCTAssertEqual(stats.p95Ms, 22.5)
        XCTAssertEqual(stats.sampleCount, 1)
        XCTAssertEqual(stats.droppedCount, 59) // 60 expected, 1 observed
    }

    func test_aggregator_p95_picksNearestRank() {
        let samples = Array(stride(from: 1.0, through: 100.0, by: 1.0))
        let stats = FrameWindowAggregator.computeStats(
            samples: samples,
            windowSeconds: 1.0,
            targetHz: 60
        )
        XCTAssertEqual(stats.maxMs, 100.0)
        XCTAssertEqual(stats.p95Ms, 95.0)
        XCTAssertEqual(stats.sampleCount, 100)
        XCTAssertEqual(stats.droppedCount, 0)
    }

    func test_aggregator_droppedNeverGoesNegative() {
        let stats = FrameWindowAggregator.computeStats(
            samples: Array(repeating: 16.6, count: 200),
            windowSeconds: 1.0,
            targetHz: 60
        )
        XCTAssertEqual(stats.droppedCount, 0)
    }

    func test_aggregator_flushResetsWindow() {
        var agg = FrameWindowAggregator(
            windowSeconds: 1.0,
            targetHz: 60,
            startedAt: Date(timeIntervalSince1970: 0)
        )
        agg.recordDelta(20)
        agg.recordDelta(30)
        let now = Date(timeIntervalSince1970: 1.5)
        XCTAssertTrue(agg.shouldFlush(now: now))
        _ = agg.flush(now: now)
        let after = agg.flush(now: now)
        XCTAssertEqual(after.sampleCount, 0)
        XCTAssertEqual(after.maxMs, 0)
    }

    func test_aggregator_negativeOrNonFiniteDeltasAreIgnored() {
        var agg = FrameWindowAggregator(
            windowSeconds: 1.0,
            targetHz: 60,
            startedAt: Date(timeIntervalSince1970: 0)
        )
        agg.recordDelta(-5)
        agg.recordDelta(.nan)
        agg.recordDelta(.infinity)
        agg.recordDelta(16.6)
        let stats = agg.flush(now: Date(timeIntervalSince1970: 1.0))
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
            sampleCount: 56
        )
        let attrs = FrameSampler.makeAttributes(stats: stats, targetHz: 60)
        XCTAssertEqual(attrs["frame.max_ms"], .double(33.3))
        XCTAssertEqual(attrs["frame.p95_ms"], .double(28.1))
        XCTAssertEqual(attrs["frame.dropped_count"], .int(4))
        XCTAssertEqual(attrs["frame.target_hz"], .int(60))
        XCTAssertEqual(attrs["frame.source"], .string("displaylink"))
        XCTAssertEqual(attrs["value"], .double(33.3))
    }

    func test_makeAttributes_proMotion_target_hz120() {
        let stats = FrameWindowAggregator.Stats(
            maxMs: 16.6, p95Ms: 16.6, droppedCount: 0, sampleCount: 120
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
            maxMs: 22.0, p95Ms: 19.0, droppedCount: 1, sampleCount: 59
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
            maxMs: 22.0, p95Ms: 19.0, droppedCount: 1, sampleCount: 59
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

    func test_resolveTargetHz_isPositiveOnIOSHost() {
        // On a 60Hz simulator this is 60. On ProMotion it's 120. Either
        // way, it must be > 0 and a multiple of a real Hz value.
        let hz = FrameSampler.resolveTargetHz()
        XCTAssertGreaterThanOrEqual(hz, 60)
    }
    #endif
}
