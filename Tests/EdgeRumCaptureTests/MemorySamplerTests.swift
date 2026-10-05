// Tests/EdgeRumCaptureTests/MemorySamplerTests.swift
//
// F10 / T10.2 unit tests. Covers:
//
//   - makeAttributes: kB conversion, primitives-only shape, every
//     PLAN-§6.11 key present, `value` mirrors resident_kb.
//   - pressureLevel mapping for each DispatchSource event mask.
//   - emit() routes through Recorder.shared.recordPerformance with
//     metricName = "memory_usage".
//   - Recorder.isEnabled = false halts emission.
//   - readMachStats returns a plausible (non-zero) RSS on real iOS /
//     macOS hosts.
//   - install() idempotent + concurrent-safe.
//
// Refs: PLAN-iOS.md §F10/T10.2 acceptance; CLAUDE.md
//       "Testing conventions".
//

import XCTest
import Foundation
import Dispatch
import EdgeRumCore
@testable import EdgeRumCapture

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

final class MemorySamplerTests: XCTestCase {

    override func tearDown() {
        Recorder.resetShared()
        MemorySampler._resetInstallFlagForTesting()
        super.tearDown()
    }

    // MARK: makeAttributes — kB conversion + shape

    func test_makeAttributes_carriesAllPlanKeys_inKb() {
        let attrs = MemorySampler.makeAttributes(
            rssBytes: 200 * 1024,
            vszBytes: 800 * 1024,
            footprintBytes: 250 * 1024,
            pressure: .normal
        )
        XCTAssertEqual(attrs["memory.resident_kb"], .int(200))
        XCTAssertEqual(attrs["memory.virtual_kb"], .int(800))
        XCTAssertEqual(attrs["memory.footprint_kb"], .int(250))
        XCTAssertEqual(attrs["memory.pressure"], .string("normal"))
        XCTAssertEqual(attrs["value"], .double(200.0 / 1024.0), "F29: value is MB")
    }

    func test_makeAttributes_pressureLevelStringMatchesWireSpec() {
        let warn = MemorySampler.makeAttributes(
            rssBytes: 0, vszBytes: 0, footprintBytes: 0, pressure: .warning
        )
        XCTAssertEqual(warn["memory.pressure"], .string("warning"))

        let crit = MemorySampler.makeAttributes(
            rssBytes: 0, vszBytes: 0, footprintBytes: 0, pressure: .critical
        )
        XCTAssertEqual(crit["memory.pressure"], .string("critical"))
    }

    // MARK: pressureLevel mapping

    func test_pressureLevel_critical_takesPrecedenceOverWarning() {
        let mask: DispatchSource.MemoryPressureEvent = [.warning, .critical]
        XCTAssertEqual(MemorySampler.pressureLevel(for: mask), .critical)
    }

    func test_pressureLevel_warning_isReportedAlone() {
        XCTAssertEqual(MemorySampler.pressureLevel(for: .warning), .warning)
    }

    func test_pressureLevel_normal_isReportedForEmptyMaskAndNormal() {
        XCTAssertEqual(MemorySampler.pressureLevel(for: .normal), .normal)
        XCTAssertEqual(MemorySampler.pressureLevel(for: []), .normal)
    }

    // MARK: emit() routing

    func test_emit_routesToRecordPerformance() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)
        MemorySampler.emit(
            rssBytes: 1024,
            vszBytes: 2048,
            footprintBytes: 4096,
            pressure: .warning
        )
        XCTAssertEqual(probe.calls.count, 1)
        guard case let .performance(name, attrs) = probe.calls[0] else {
            return XCTFail("Expected a .performance call, got \(probe.calls)")
        }
        XCTAssertEqual(name, "memory_usage")
        XCTAssertEqual(attrs["memory.pressure"], .string("warning"))
    }

    func test_emit_haltedWhenRecorderDisabled() {
        let probe = CaptureProbeRecorder(enabled: false)
        Recorder.installShared(probe)
        MemorySampler.emit(
            rssBytes: 1024, vszBytes: 0, footprintBytes: 0, pressure: .normal
        )
        XCTAssertEqual(probe.calls.count, 0)
    }

    // MARK: F30 — omit on failed read

    func test_makeAttributes_failedReadOmitsKeys_neverZero() {
        let attrs = MemorySampler.makeAttributes(
            rssBytes: nil, vszBytes: nil, footprintBytes: 100 * 1024, pressure: .normal
        )
        XCTAssertNil(attrs["memory.resident_kb"])
        XCTAssertNil(attrs["memory.virtual_kb"])
        XCTAssertNil(attrs["value"])
        XCTAssertEqual(attrs["memory.footprint_kb"], .int(100))
    }

    // MARK: F30 — driver tick: last pressure, gate, cpu_usage

    func test_tickSeconds_is30() {
        XCTAssertEqual(MemorySampler.tickSeconds, 30)
    }

    func test_tick_carriesLastObservedPressure_onEverySample() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)
        let driver = MemorySampler.Driver(debug: false, gate: { true })
        driver.pressureChanged(.warning)
        driver.tick()
        driver.tick()
        let pressures = probe.calls.compactMap { call -> AttributeValue? in
            guard case let .performance("memory_usage", attrs) = call else { return nil }
            return attrs["memory.pressure"]
        }
        XCTAssertEqual(pressures, [.string("warning"), .string("warning"), .string("warning")])
    }

    func test_tick_emitsCpuUsagePercent() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)
        let driver = MemorySampler.Driver(debug: false, gate: { true })
        var x = 0.0
        for i in 0..<200_000 { x += Double(i).squareRoot() }  // burn a little CPU
        XCTAssertGreaterThan(x, 0)
        driver.tick()
        let cpu = probe.calls.compactMap { call -> [String: AttributeValue]? in
            guard case let .performance("cpu_usage", attrs) = call else { return nil }
            return attrs
        }
        XCTAssertEqual(cpu.count, 1)
        guard case let .double(percent)? = cpu.first?["value"] else {
            return XCTFail("cpu_usage value missing: \(cpu)")
        }
        XCTAssertGreaterThanOrEqual(percent, 0)
    }

    func test_tick_gateClosed_stillReadsCpu_soNextSampleCoversOnlyItsTick() {
        Recorder.installShared(CaptureProbeRecorder())
        var reads = 0
        let driver = MemorySampler.Driver(debug: false, gate: { false }, cpuSample: { reads += 1; return 5 })
        driver.tick()
        XCTAssertEqual(reads, 1)
    }

    func test_tick_gateClosed_emitsNothing_butPressureStillEmits() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)
        let driver = MemorySampler.Driver(debug: false, gate: { false })
        driver.tick()
        XCTAssertEqual(probe.calls.count, 0)
        driver.pressureChanged(.critical)
        XCTAssertEqual(probe.calls.count, 1, "pressure events are exempt from the gate")
    }

    // MARK: Live mach read

    func test_readMachStats_returnsPlausibleResidentSize() {
        let stats = MemorySampler.readMachStats()
        // The unit-test process always has > 1 MiB resident on Darwin.
        // Allowing zero would silently mask a busted task_info call.
        #if canImport(Darwin)
        XCTAssertGreaterThan(stats.rss ?? 0, 1024 * 1024,
                             "expected > 1 MiB resident on the test host, got \(stats.rss)")
        #else
        XCTAssertNil(stats.rss)
        #endif
    }

    // MARK: install()

    func test_install_isIdempotent() {
        MemorySampler.install(debug: false)
        XCTAssertTrue(MemorySampler.isInstalled)
        MemorySampler.install(debug: false)
        MemorySampler.install(debug: false)
        XCTAssertTrue(MemorySampler.isInstalled)
    }

    func test_install_concurrentCallsAreSafe() {
        // Pump the main runloop while waiting — `install()` does a
        // `DispatchQueue.main.sync` hop on background callers; blocking
        // main with `DispatchGroup.wait` would deadlock.
        let exp = expectation(description: "16 concurrent installs converge")
        exp.expectedFulfillmentCount = 16
        for _ in 0..<16 {
            DispatchQueue.global().async {
                MemorySampler.install(debug: false)
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 120)
        XCTAssertTrue(MemorySampler.isInstalled)
    }
}
