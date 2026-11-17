// Tests/EdgeRumCrashTests/CatalogueGoldenTests.swift
//
// Golden batches (#264, processor #40): every catalogue event this SDK
// sends, recorded through the real emitters and encoded by the real
// envelope encoder, one batch per event name in `Tests/golden/`.
// `Tools/conform.sh` runs the processor's `cmd/conform` on that
// directory at the ref pinned in `catalogue.version`.
//
// Values that change per run or per simulator (ids, timestamps,
// durations, stacks) are normalized to a fixed value of the same JSON
// type, so the snapshot pins event names, keys, types and enum values.
//
// iOS only: half the emitters are UIKit. Regenerate on a simulator with
//
//   TEST_RUNNER_UPDATE_GOLDENS=1 xcodebuild test -scheme EdgeRum-Package \
//     -destination 'platform=iOS Simulator,name=iPhone 17' \
//     -only-testing:EdgeRumCrashTests/CatalogueGoldenTests
//

#if os(iOS)
import XCTest
import UIKit
@testable import EdgeRum
@testable import EdgeRumCapture
@testable import EdgeRumCrash
import EdgeRumCore

final class CatalogueGoldenTests: XCTestCase {

    private var previous: Recording?

    override func tearDown() {
        if let previous { Recorder.installShared(previous) }
        EdgeRum._resetStartedConfigForTesting()
        Riders.shared._resetForTesting()
        super.tearDown()
    }

    func testGoldensMatchTheRealWire() throws {
        let events = try recordEveryEvent()
        var want: [String: Data] = [:]
        for (envelope, event) in events {
            let name = (event["eventName"] ?? event["metricName"]) as? String ?? "?"
            let file = name.replacingOccurrences(of: ".", with: "-") + ".json"
            guard want[file] == nil else { continue }  // first of each name
            var batch = envelope
            batch["events"] = [event]
            batch["batch_size"] = 1
            want[file] = try Self.render(Self.normalize(batch))
        }

        let dir = Self.goldenDir()
        if ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] != nil {
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (file, body) in want { try body.write(to: dir.appendingPathComponent(file)) }
        }
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertEqual(want.keys.sorted(), onDisk.filter { $0.hasSuffix(".json") }.sorted())
        for (file, body) in want.sorted(by: { $0.key < $1.key }) {
            let disk = try? Data(contentsOf: dir.appendingPathComponent(file))
            XCTAssertEqual(disk.map { String(decoding: $0, as: UTF8.self) }, String(decoding: body, as: UTF8.self), file)
        }
    }

    // MARK: - Drive every emitter

    /// Every envelope sent, paired with each of its events, in send order.
    private func recordEveryEvent() throws -> [([String: Any], [String: Any])] {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_767_225_600))  // 2026-01-01
        let sink = RecordingTransportSink()
        let recorder = Recorder(
            clock: clock,
            sampler: Sampler(sampleRate: 1.0, entropy: { 0.0 }),
            transport: sink,
            sdkVersion: EdgeRum.sdkVersion,
            health: SdkHealth()
        )
        previous = Recorder.installShared(recorder)
        Riders.shared._resetForTesting()
        Actions.shared.abandonAll(reason: .rotation).forEach { _ in }
        recorder.configure(RecorderConfig(
            apiKey: "edge_golden_key",
            endpoint: URL(string: "https://collect.example.com/telemetry")!,
            appName: "Golden",
            appVersion: "1.0.0",
            appPackage: "com.example.golden",
            appBuild: "1",
            sdkVersion: EdgeRum.sdkVersion
        ))
        Self.freezeContext(recorder.currentContextProvider)
        recorder.setLaunchEvidence(PreviousSession.attributes(prior: ReplayBatch.priorSidecar(), crashed: false))
        recorder.start(apiKey: "edge_golden_key", endpoint: URL(string: "https://collect.example.com/telemetry")!, debug: false)
        EdgeRum._markStartedForTesting()

        // app.start
        PageLoadCapture._resetInstallFlagForTesting()
        PageLoadCapture.emit(durationMs: 420, prewarmed: false, preSdkDurationMs: 180)

        // navigation, screen.duration, screen.load
        let home = UIViewController()
        home.view.accessibilityIdentifier = "Home"
        let detail = UIViewController()
        detail.view.accessibilityIdentifier = "OrderDetail"
        UIViewControllerCapture.handleViewDidAppear(home)
        EdgeRum.markScreenReady()
        UIViewControllerCapture.handleViewDidAppear(detail)

        // ui.interaction
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "pay_button"
        InteractionCapture.emitTap(on: button, captureButtonTitles: false)

        // frame.summary
        var window = FrameWindowAggregator(targetHz: 60, startedAt: clock.now)
        for ms in [16.7, 16.7, 33.4, 750.0] { window.recordDelta(ms, refreshMs: 16.7) }
        FrameSampler.emit(stats: window.flush(now: clock.now.addingTimeInterval(1)), targetHz: 60)

        // memory.usage, perf.cpu_usage, memory.pressure
        let memory = MemorySampler.Driver(debug: false, gate: { true }, cpuSample: { 12.5 })
        memory.tick()
        memory.pressureChanged(.critical)

        // perf.long_task
        RunLoopObserverCapture.emit(durationMs: 120, thresholdMs: 50, stack: [StackFrame(text: "Golden +0x10 main")])

        // http.request, perf.resource_timing
        try recordHTTP(at: clock.now)

        // app.lifecycle, network.change
        LifecycleCapture.emit(state: "background")
        LifecycleCapture.emit(state: "foreground")
        NetworkPathCapture._resetDedupeFingerprintForTesting()
        NetworkPathCapture.emit(
            context: NetworkContext(type: .wifi, effectiveType: "4g", isExpensive: false, isConstrained: false, interface: "wifi"),
            isExpensive: false,
            isConstrained: false,
            unsatisfiedReason: nil
        )

        // custom.event, perf.custom_timer, task.complete, user.profile.update, app.error, perf.launch_interactive
        EdgeRum.track("checkout_started")
        EdgeRum.time("checkout.submit").end()
        EdgeRum.startAction("checkout").complete()
        EdgeRum.identify(UserContext(id: "u-42", name: "Ada", email: "ada@example.com", phone: "+254700000000"))
        EdgeRum.captureError(GoldenError.cardDeclined, type: "payment")
        EdgeRum.markInteractive()

        // app.hang: a live stall, then a stall the process died in
        recorder.recordEvent(name: "app.hang", attributes: HangEventEncoder.encode(
            durationMs: 2_500, thresholdMs: 2_000, cpuUsage: 98.5,
            stackFrames: [StackFrame(text: "Golden +0x10 main")], timestamp: clock.now
        ))
        recorder.flush(reason: .manual)

        // app.crash, replayed from a seeded PLCrashReporter report
        try replayCrash(into: recorder)

        // session.finalized (+ task.complete abandoned, session.started rotation)
        _ = EdgeRum.startAction("left_open")
        clock.advance(by: 31 * 60)
        recorder.touchSession()
        recorder.flush(reason: .manual)

        var out: [([String: Any], [String: Any])] = []
        for envelope in sink.envelopes {
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any]
            )
            for event in (json["events"] as? [[String: Any]]) ?? [] { out.append((json, event)) }
        }
        return out
    }

    private enum GoldenError: Error { case cardDeclined }

    private func recordHTTP(at t0: Date) throws {
        let url = try XCTUnwrap(URL(string: "https://api.example.com/v1/orders/42"))
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/2", headerFields: nil)
        let txn = GoldenTransactionMetrics(
            domainLookupStartDate: t0,
            domainLookupEndDate: t0.addingTimeInterval(0.010),
            connectStartDate: t0.addingTimeInterval(0.010),
            connectEndDate: t0.addingTimeInterval(0.040),
            secureConnectionStartDate: t0.addingTimeInterval(0.020),
            secureConnectionEndDate: t0.addingTimeInterval(0.040),
            requestEndDate: t0.addingTimeInterval(0.050),
            responseStartDate: t0.addingTimeInterval(0.150),
            responseEndDate: t0.addingTimeInterval(0.200),
            fetchStartDate: t0,
            countOfResponseBodyBytesReceived: 1_024,
            negotiatedTLSProtocolVersion: .TLSv13,
            negotiatedTLSCipherSuite: .AES_128_GCM_SHA256,
            networkProtocolName: "h2"
        )
        HTTPCapture.recordOutcomeWithView(
            request: URLRequest(url: url),
            response: response,
            data: Data(count: 1_024),
            view: MetricsView(redirectCount: 0, transactions: [txn]),
            error: nil,
            startedAt: t0,
            finishedAt: t0.addingTimeInterval(0.200),
            taskDescription: nil,
            config: HTTPCaptureConfig()
        )
    }

    private func replayCrash(into recorder: Recorder) throws {
        let bytes = try XCTUnwrap(CrashFixtureGenerator.makeLiveReport(), "PLCrashReporter unavailable")
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edgerum-golden-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let plcr = base.appendingPathComponent("plcr", isDirectory: true)
        try FileManager.default.createDirectory(at: plcr, withIntermediateDirectories: true)
        let path = try XCTUnwrap(CrashFixtureGenerator.pendingReportPath(basePath: plcr))
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
        XCTAssertTrue(PLCrashIntegration.replayIfNeeded(
            recorder: recorder,
            sidecarContents: ReplayBatch.priorSidecar(),
            config: PLCrashIntegrationConfig(basePath: plcr),
            debug: false
        ))
    }

    private static func freezeContext(_ context: ContextProvider) {
        context.refreshDevice(DeviceContext(
            platformVersion: "18.2", model: "iPhone17,3", isVirtual: true,
            screenWidth: 1179, screenHeight: 2556, pixelRatio: 3.0,
            batteryLevel: 0.8, batteryCharging: false,
            locale: "en_KE", timezone: "Africa/Nairobi", timezoneOffsetMin: 180, family: "phone"
        ))
        context.refreshNetwork(NetworkContext(type: .wifi, effectiveType: "4g", isExpensive: false, isConstrained: false, interface: "wifi"))
        context.refreshPower(PowerContext(thermalState: "nominal", lowPowerMode: false))
        context.refreshAccessibility(AccessibilityContext(
            dynamicType: "large", reduceMotion: false, boldText: false, voiceOver: false, increaseContrast: false
        ))
        context.refreshStorage(StorageContext(backgroundRefresh: "available"))
    }

    // MARK: - Normalization

    /// String values that differ per run or per machine; the key stays.
    private static let volatileStrings: Set<String> = [
        "error.stacktrace", "error.breadcrumbs", "error.binary_images", "error.domain", "crash.report_json",
        "crash.binary_uuid", "crash.binary_name", "crash.os_version", "hang.binary_images",
        "long_task.binary_images", "action.id", "action.parent_id", "previous_session.id",
        "session.id", "user.id", "device_id"
    ]

    private static func normalize(_ value: Any, key: String = "") -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.reduce(into: [String: Any]()) { $0[$1.key] = normalize($1.value, key: $1.key) }
        case let array as [Any]:
            return array.map { normalize($0, key: key) }
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            if key == "batch_size" { return number }
            return number.doubleValue.rounded() == number.doubleValue ? 1 : 1.5
        case let string as String:
            if volatileStrings.contains(key) { return "<\(key)>" }
            if WireDateFormatter.date(from: string) != nil { return "2026-01-01T00:00:00.000Z" }
            return string
        default:
            return value
        }
    }

    private static func render(_ json: Any) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        return data
    }

    private static func goldenDir(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()  // Tests/EdgeRumCrashTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("golden", isDirectory: true)
    }
}

private struct GoldenTransactionMetrics: TransactionMetricsLike {
    var domainLookupStartDate: Date?
    var domainLookupEndDate: Date?
    var connectStartDate: Date?
    var connectEndDate: Date?
    var secureConnectionStartDate: Date?
    var secureConnectionEndDate: Date?
    var requestEndDate: Date?
    var responseStartDate: Date?
    var responseEndDate: Date?
    var fetchStartDate: Date?
    var countOfRequestHeaderBytesSent: Int64 = 0
    var countOfRequestBodyBytesSent: Int64 = 0
    var countOfRequestBodyBytesBeforeEncoding: Int64 = 0
    var countOfResponseHeaderBytesReceived: Int64 = 0
    var countOfResponseBodyBytesReceived: Int64 = 0
    var negotiatedTLSProtocolVersion: tls_protocol_version_t?
    var negotiatedTLSCipherSuite: tls_ciphersuite_t?
    var isReusedConnection: Bool = false
    var isProxyConnection: Bool = false
    var networkProtocolName: String?
    var resourceFetchType: URLSessionTaskMetrics.ResourceFetchType = .networkLoad
    var isMultipath: Bool = false
    var isCellular: Bool = false
}
#endif
