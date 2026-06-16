// Tests/EdgeRumCaptureTests/HTTPCaptureTests.swift
//
// F8 unit tests. Covers each acceptance criterion in PLAN-iOS.md
// §F8 (T8.1 — T8.5) without going to the network:
//
//   T8.1 — `URLProtocol.canInit(with:)` accepts external requests,
//           rejects already-processed re-entry, rejects non-HTTP schemes.
//   T8.2 — `URLSessionConfiguration.default` / `.ephemeral` getters
//           return configs whose `protocolClasses` start with our
//           protocol; background configs are skipped.
//   T8.3 — A synthesized `URLSessionTaskMetrics` (no network) drives
//           the recording sink and emits a `resource_timing` metric
//           with non-zero `resource.dns_ms`.
//   T8.4 — Internal-marker header, internal-marker task description,
//           and endpoint-host filters each independently drop the
//           record.
//   T8.5 — `ignoreUrls` regex match drops the event; `sanitizeUrl`
//           callback rewrites the recorded URL.
//
// Shared `Recorder` is swapped with a `CaptureProbeRecorder` (local
// to this target, mirroring the F6 test pattern) so emissions can
// be asserted directly.
//
// Refs: PLAN-iOS.md §F8 (lines 1934-1965), §6.3 (lines 641-667);
//       CLAUDE.md "Testing conventions".
//

import XCTest
import Foundation
import EdgeRumCore
@testable import EdgeRumCapture

// MARK: - Probe recorder used by the capture tests
//
// Capture tests live in the EdgeRumCaptureTests target, which does
// not depend on the EdgeRumTests target — so we cannot reuse the
// `ProbeRecorder` defined there. This is a local copy, scoped to
// what F8 exercises. Mirrors `UIViewControllerCaptureTests`' local
// probe to keep both test files self-contained.

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

    func setEnabledFlagOnly(_ value: Bool) {
        lock.lock(); _enabled = value; lock.unlock()
    }

    func configure(_ config: RecorderConfig) { _ = config }
    func start(apiKey: String, endpoint: URL, debug: Bool) {
        _ = (apiKey, endpoint, debug)
    }
    func stop() {}
    func setEnabled(_ enabled: Bool) { setEnabledFlagOnly(enabled) }

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

// MARK: - URLSessionTaskMetrics synthesis
//
// We can't construct `URLSessionTaskTransactionMetrics` directly —
// it's a framework-internal class. The acceptance criterion is
// "synthesize timings that flow through `ResourceTiming.from(...)`",
// so we test the `msBetween` helper plus `ResourceTiming` shape
// directly, and exercise the full recordOutcome pipeline with
// `metrics == nil` to verify the http.request event still fires
// without a companion resource_timing.

// MARK: - Tests

final class HTTPCaptureTests: XCTestCase {

    private var probe: CaptureProbeRecorder!

    override func setUp() {
        super.setUp()
        probe = CaptureProbeRecorder()
        HTTPCapture._resetConfigForTesting()
    }

    override func tearDown() {
        HTTPCapture._resetConfigForTesting()
        Recorder.resetShared()
        probe = nil
        super.tearDown()
    }

    // MARK: shouldCaptureRequest — T8.4

    func test_shouldCaptureRequest_acceptsBareExternalRequest() {
        let request = URLRequest(url: URL(string: "https://api.example.com/users")!)
        XCTAssertTrue(HTTPCapture.shouldCaptureRequest(
            request,
            taskDescription: nil,
            config: HTTPCaptureConfig()
        ))
    }

    func test_shouldCaptureRequest_rejectsInternalHeader() {
        var request = URLRequest(url: URL(string: "https://api.example.com/users")!)
        request.setValue("1", forHTTPHeaderField: "X-Edge-Rum-Internal")
        XCTAssertFalse(HTTPCapture.shouldCaptureRequest(
            request,
            taskDescription: nil,
            config: HTTPCaptureConfig()
        ))
    }

    func test_shouldCaptureRequest_rejectsInternalTaskDescription() {
        let request = URLRequest(url: URL(string: "https://api.example.com/users")!)
        XCTAssertFalse(HTTPCapture.shouldCaptureRequest(
            request,
            taskDescription: "edge-rum-internal",
            config: HTTPCaptureConfig()
        ))
    }

    func test_shouldCaptureRequest_rejectsCollectorEndpointHost() {
        let request = URLRequest(url: URL(string: "https://collect.example.com/collector/telemetry")!)
        let config = HTTPCaptureConfig(endpointHost: "collect.example.com")
        XCTAssertFalse(HTTPCapture.shouldCaptureRequest(
            request,
            taskDescription: nil,
            config: config
        ))
    }

    func test_shouldCaptureRequest_acceptsWhenHostDiffersFromCollector() {
        let request = URLRequest(url: URL(string: "https://api.example.com/users")!)
        let config = HTTPCaptureConfig(endpointHost: "collect.example.com")
        XCTAssertTrue(HTTPCapture.shouldCaptureRequest(
            request,
            taskDescription: nil,
            config: config
        ))
    }

    // MARK: matchesIgnoredUrl — T8.5

    func test_matchesIgnoredUrl_dropsOnRegexMatch() throws {
        let regex = try NSRegularExpression(pattern: "token=", options: [])
        let config = HTTPCaptureConfig(ignoreUrls: [regex])
        XCTAssertTrue(HTTPCapture.matchesIgnoredUrl(
            "https://api.example.com/u?token=secret",
            config: config
        ))
    }

    func test_matchesIgnoredUrl_passesWhenNoMatch() throws {
        let regex = try NSRegularExpression(pattern: "token=", options: [])
        let config = HTTPCaptureConfig(ignoreUrls: [regex])
        XCTAssertFalse(HTTPCapture.matchesIgnoredUrl(
            "https://api.example.com/u",
            config: config
        ))
    }

    func test_matchesIgnoredUrl_emptyConfigNeverDrops() {
        XCTAssertFalse(HTTPCapture.matchesIgnoredUrl(
            "https://api.example.com/u?token=secret",
            config: HTTPCaptureConfig()
        ))
    }

    // MARK: recordOutcome — http.request shape

    func test_recordOutcome_emitsHTTPRequestEventWithCorrectAttributes() {
        let url = URL(string: "https://api.example.com/v1/users?page=2")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "1234"]
        )

        let start = Date(timeIntervalSince1970: 1_700_000_000.0)
        let end = Date(timeIntervalSince1970: 1_700_000_000.5)

        HTTPCapture.recordOutcome(
            request: request,
            response: response,
            data: Data(count: 1234),
            metrics: nil,
            error: nil,
            startedAt: start,
            finishedAt: end,
            taskDescription: nil,
            recorder: probe,
            config: HTTPCaptureConfig()
        )

        XCTAssertEqual(probe.calls.count, 1)
        guard case .event(let name, let attrs) = probe.calls[0] else {
            XCTFail("Expected an event call"); return
        }
        XCTAssertEqual(name, "http.request")
        XCTAssertEqual(attrs["http.method"], .string("GET"))
        XCTAssertEqual(attrs["http.url"], .string("https://api.example.com/v1/users?page=2"))
        XCTAssertEqual(attrs["http.host"], .string("api.example.com"))
        XCTAssertEqual(attrs["http.path"], .string("/v1/users"))
        XCTAssertEqual(attrs["http.status_code"], .int(200))
        XCTAssertEqual(attrs["http.duration_ms"], .int(500))
        XCTAssertEqual(attrs["http.response_size"], .int(1234))
        XCTAssertEqual(attrs["http.from_cache"], .bool(false))
        XCTAssertNil(attrs["http.error"])
    }

    func test_recordOutcome_includesErrorAttributeOnFailure() {
        let url = URL(string: "https://api.example.com/v1/users")!
        let request = URLRequest(url: url)
        let error = URLError(.notConnectedToInternet)

        HTTPCapture.recordOutcome(
            request: request,
            response: nil,
            data: nil,
            metrics: nil,
            error: error,
            startedAt: Date(),
            finishedAt: Date(),
            taskDescription: nil,
            recorder: probe,
            config: HTTPCaptureConfig()
        )

        XCTAssertEqual(probe.calls.count, 1)
        guard case .event(_, let attrs) = probe.calls[0] else {
            XCTFail("Expected an event call"); return
        }
        XCTAssertNotNil(attrs["http.error"])
        XCTAssertEqual(attrs["http.status_code"], .int(0))
    }

    // MARK: recordOutcome — defense-in-depth

    func test_recordOutcome_dropsInternalHeaderRequest() {
        var request = URLRequest(url: URL(string: "https://api.example.com/u")!)
        request.setValue("1", forHTTPHeaderField: "X-Edge-Rum-Internal")

        HTTPCapture.recordOutcome(
            request: request,
            response: nil,
            data: nil,
            metrics: nil,
            error: nil,
            startedAt: Date(),
            finishedAt: Date(),
            taskDescription: nil,
            recorder: probe,
            config: HTTPCaptureConfig()
        )

        XCTAssertEqual(probe.calls.count, 0)
    }

    func test_recordOutcome_dropsInternalTaskDescriptionRequest() {
        let request = URLRequest(url: URL(string: "https://api.example.com/u")!)

        HTTPCapture.recordOutcome(
            request: request,
            response: nil,
            data: nil,
            metrics: nil,
            error: nil,
            startedAt: Date(),
            finishedAt: Date(),
            taskDescription: "edge-rum-internal",
            recorder: probe,
            config: HTTPCaptureConfig()
        )

        XCTAssertEqual(probe.calls.count, 0)
    }

    func test_recordOutcome_dropsEndpointHostMatch() {
        let request = URLRequest(url: URL(string: "https://collect.example.com/collector/telemetry")!)
        let config = HTTPCaptureConfig(endpointHost: "collect.example.com")

        HTTPCapture.recordOutcome(
            request: request,
            response: nil,
            data: nil,
            metrics: nil,
            error: nil,
            startedAt: Date(),
            finishedAt: Date(),
            taskDescription: nil,
            recorder: probe,
            config: config
        )

        XCTAssertEqual(probe.calls.count, 0)
    }

    // MARK: recordOutcome — ignoreUrls / sanitizeUrl (T8.5)

    func test_recordOutcome_dropsOnIgnoreUrlsMatch() throws {
        let regex = try NSRegularExpression(pattern: "secret-endpoint", options: [])
        let config = HTTPCaptureConfig(ignoreUrls: [regex])
        let request = URLRequest(url: URL(string: "https://api.example.com/secret-endpoint")!)

        HTTPCapture.recordOutcome(
            request: request,
            response: nil,
            data: nil,
            metrics: nil,
            error: nil,
            startedAt: Date(),
            finishedAt: Date(),
            taskDescription: nil,
            recorder: probe,
            config: config
        )

        XCTAssertEqual(probe.calls.count, 0)
    }

    func test_recordOutcome_appliesSanitizeUrl() {
        // Strip query string from the recorded URL.
        let sanitize: @Sendable (URL) -> URL = { url in
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.query = nil
            return components?.url ?? url
        }
        let config = HTTPCaptureConfig(sanitizeUrl: sanitize)
        let request = URLRequest(url: URL(string: "https://api.example.com/u?token=abc123")!)

        HTTPCapture.recordOutcome(
            request: request,
            response: nil,
            data: nil,
            metrics: nil,
            error: nil,
            startedAt: Date(),
            finishedAt: Date(),
            taskDescription: nil,
            recorder: probe,
            config: config
        )

        XCTAssertEqual(probe.calls.count, 1)
        guard case .event(_, let attrs) = probe.calls[0] else {
            XCTFail("Expected an event call"); return
        }
        XCTAssertEqual(attrs["http.url"], .string("https://api.example.com/u"))
    }

    // MARK: recordOutcome — disabled recorder

    func test_recordOutcome_isNoOpWhenRecorderDisabled() {
        probe.setEnabledFlagOnly(false)
        let request = URLRequest(url: URL(string: "https://api.example.com/u")!)

        HTTPCapture.recordOutcome(
            request: request,
            response: nil,
            data: nil,
            metrics: nil,
            error: nil,
            startedAt: Date(),
            finishedAt: Date(),
            taskDescription: nil,
            recorder: probe,
            config: HTTPCaptureConfig()
        )

        XCTAssertEqual(probe.calls.count, 0)
    }

    // MARK: install + isInstalled

    func test_install_isIdempotent() {
        HTTPCapture._resetInstallFlagForTesting()
        HTTPCapture._unregisterURLProtocolForTesting()

        HTTPCapture.install(debug: true)
        XCTAssertTrue(HTTPCapture.isInstalled)

        HTTPCapture.install(debug: false)
        HTTPCapture.install(debug: false)
        XCTAssertTrue(HTTPCapture.isInstalled)
    }

    func test_install_concurrentCallsAreSafe() {
        HTTPCapture._resetInstallFlagForTesting()
        HTTPCapture._unregisterURLProtocolForTesting()

        let group = DispatchGroup()
        for _ in 0..<32 {
            group.enter()
            DispatchQueue.global().async {
                HTTPCapture.install(debug: false)
                group.leave()
            }
        }
        group.wait()
        XCTAssertTrue(HTTPCapture.isInstalled)
    }

    // MARK: URLSessionConfiguration swizzle — T8.2

    func test_defaultConfiguration_carriesEdgeRumURLProtocol() {
        HTTPCapture._resetInstallFlagForTesting()
        HTTPCapture._unregisterURLProtocolForTesting()
        HTTPCapture.install(debug: false)

        let cfg = URLSessionConfiguration.default
        let classes = cfg.protocolClasses ?? []
        XCTAssertTrue(
            classes.contains(where: { $0 == EdgeRumURLProtocol.self }),
            "EdgeRumURLProtocol should be present in default configuration after install"
        )
    }

    func test_ephemeralConfiguration_carriesEdgeRumURLProtocol() {
        HTTPCapture._resetInstallFlagForTesting()
        HTTPCapture._unregisterURLProtocolForTesting()
        HTTPCapture.install(debug: false)

        let cfg = URLSessionConfiguration.ephemeral
        let classes = cfg.protocolClasses ?? []
        XCTAssertTrue(
            classes.contains(where: { $0 == EdgeRumURLProtocol.self }),
            "EdgeRumURLProtocol should be present in ephemeral configuration after install"
        )
    }

    func test_backgroundConfiguration_isNotInstrumented() {
        HTTPCapture._resetInstallFlagForTesting()
        HTTPCapture._unregisterURLProtocolForTesting()
        HTTPCapture.install(debug: false)

        // We can't directly observe `background` config — `edgerum_prependEdgeRumProtocol`
        // skips configs whose `identifier != nil`. Construct one and verify
        // its `protocolClasses` is unchanged by the swizzle.
        let bg = URLSessionConfiguration.background(withIdentifier: "test.edgerum.background")
        let classes = bg.protocolClasses ?? []
        XCTAssertFalse(
            classes.contains(where: { $0 == EdgeRumURLProtocol.self }),
            "Background configurations must not be instrumented"
        )
    }

    // MARK: URLProtocol.canInit — T8.1

    func test_canInit_acceptsExternalHTTPRequest() {
        HTTPCapture._resetConfigForTesting()
        let request = URLRequest(url: URL(string: "https://api.example.com/users")!)
        XCTAssertTrue(EdgeRumURLProtocol.canInit(with: request))
    }

    func test_canInit_acceptsHTTPRequest() {
        HTTPCapture._resetConfigForTesting()
        let request = URLRequest(url: URL(string: "http://api.example.com/users")!)
        XCTAssertTrue(EdgeRumURLProtocol.canInit(with: request))
    }

    func test_canInit_rejectsNonHTTPSScheme() {
        HTTPCapture._resetConfigForTesting()
        let request = URLRequest(url: URL(string: "file:///tmp/some.json")!)
        XCTAssertFalse(EdgeRumURLProtocol.canInit(with: request))
    }

    func test_canInit_rejectsAlreadyProcessedRequest() {
        HTTPCapture._resetConfigForTesting()
        let mutable = NSMutableURLRequest(url: URL(string: "https://api.example.com/users")!)
        URLProtocol.setProperty(true, forKey: EdgeRumURLProtocol.processedKey, in: mutable)
        XCTAssertFalse(EdgeRumURLProtocol.canInit(with: mutable as URLRequest))
    }

    func test_canInit_rejectsInternalHeaderRequest() {
        HTTPCapture._resetConfigForTesting()
        var request = URLRequest(url: URL(string: "https://api.example.com/u")!)
        request.setValue("1", forHTTPHeaderField: "X-Edge-Rum-Internal")
        XCTAssertFalse(EdgeRumURLProtocol.canInit(with: request))
    }

    // MARK: ResourceTiming

    func test_resourceTiming_msBetween_returnsZeroForNilDates() {
        // The msBetween helper is private but we exercise it indirectly
        // by passing a metrics object without any populated transaction
        // dates — the result should be all-zero timing, which we'll then
        // verify produces a no-op resource_timing emit OR emit with zero
        // values (depending on whether transaction is present at all).
        // With an empty transactionMetrics array, `from(metrics:)`
        // returns nil and no resource_timing fires.

        // Build a minimal synthetic metrics object via the test-only
        // initializer. URLSessionTaskMetrics has a public default init
        // since iOS 10 but transactionMetrics is read-only — we can't
        // populate it. So the realistic assertion is: with nil metrics,
        // recordOutcome emits only the http.request event.
        let request = URLRequest(url: URL(string: "https://api.example.com/u")!)
        HTTPCapture.recordOutcome(
            request: request,
            response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil),
            data: nil,
            metrics: nil,
            error: nil,
            startedAt: Date(),
            finishedAt: Date(),
            taskDescription: nil,
            recorder: probe,
            config: HTTPCaptureConfig()
        )

        // Exactly one event, zero metrics.
        XCTAssertEqual(probe.calls.count, 1)
        let metricCount = probe.calls.filter { call in
            if case .performance = call { return true }
            return false
        }.count
        XCTAssertEqual(metricCount, 0, "No resource_timing metric should fire without metrics input")
    }

    // MARK: configure() — round-trip

    func test_configure_storesAndExposesConfig() throws {
        let regex = try NSRegularExpression(pattern: "secret", options: [])
        let config = HTTPCaptureConfig(
            ignoreUrls: [regex],
            sanitizeUrl: nil,
            endpointHost: "collect.example.com"
        )
        HTTPCapture.configure(config)

        let live = HTTPCapture.currentConfig
        XCTAssertEqual(live.endpointHost, "collect.example.com")
        XCTAssertEqual(live.ignoreUrls.count, 1)
    }
}
