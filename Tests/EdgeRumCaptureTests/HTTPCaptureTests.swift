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
import Security
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

// MARK: - URLSessionTaskMetrics synthesis (F17 — ADR-013)
//
// `URLSessionTaskTransactionMetrics` is framework-internal and has had
// a deprecated `init` since iOS 13 — we cannot construct or subclass
// it. F17 introduces the `TransactionMetricsLike` protocol in
// `HTTPCapture.swift` precisely to make the enrichment + timing logic
// testable: production code passes a real `URLSessionTaskMetrics`,
// tests pass a `FakeTransactionMetrics` array wrapped in
// `MetricsView`.
//
// Both paths funnel into the same internal entry,
// `HTTPCapture.recordOutcomeWithView(...)`, so test coverage of the
// enrichment is structurally identical to the production code path.

struct FakeTransactionMetrics: TransactionMetricsLike {
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

    // MARK: F17 — TLS protocol mapping (T17.1)

    func test_tlsProtocolName_mapsAllRecognisedVersions() {
        XCTAssertEqual(
            HTTPCapture.tlsProtocolName(tls_protocol_version_t(rawValue: 0x0301)),
            "1.0"
        )
        XCTAssertEqual(
            HTTPCapture.tlsProtocolName(tls_protocol_version_t(rawValue: 0x0302)),
            "1.1"
        )
        XCTAssertEqual(
            HTTPCapture.tlsProtocolName(tls_protocol_version_t(rawValue: 0x0303)),
            "1.2"
        )
        XCTAssertEqual(
            HTTPCapture.tlsProtocolName(tls_protocol_version_t(rawValue: 0x0304)),
            "1.3"
        )
    }

    func test_tlsProtocolName_returnsNilForNil() {
        XCTAssertNil(HTTPCapture.tlsProtocolName(nil))
    }

    func test_tlsProtocolName_returnsNilForUnrecognisedRawValue() {
        XCTAssertNil(
            HTTPCapture.tlsProtocolName(tls_protocol_version_t(rawValue: 0xFFFF))
        )
    }

    // MARK: F17 — TLS cipher suite mapping (T17.1)

    func test_tlsCipherName_mapsTLS13Suites() {
        XCTAssertEqual(
            HTTPCapture.tlsCipherName(tls_ciphersuite_t(rawValue: 0x1301)),
            "TLS_AES_128_GCM_SHA256"
        )
        XCTAssertEqual(
            HTTPCapture.tlsCipherName(tls_ciphersuite_t(rawValue: 0x1302)),
            "TLS_AES_256_GCM_SHA384"
        )
        XCTAssertEqual(
            HTTPCapture.tlsCipherName(tls_ciphersuite_t(rawValue: 0x1303)),
            "TLS_CHACHA20_POLY1305_SHA256"
        )
    }

    func test_tlsCipherName_mapsCommonTLS12Suites() {
        XCTAssertEqual(
            HTTPCapture.tlsCipherName(tls_ciphersuite_t(rawValue: 0xC02F)),
            "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"
        )
        XCTAssertEqual(
            HTTPCapture.tlsCipherName(tls_ciphersuite_t(rawValue: 0xC02B)),
            "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"
        )
        XCTAssertEqual(
            HTTPCapture.tlsCipherName(tls_ciphersuite_t(rawValue: 0xCCA8)),
            "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256"
        )
    }

    func test_tlsCipherName_fallsBackToHexForUnknown() {
        XCTAssertEqual(
            HTTPCapture.tlsCipherName(tls_ciphersuite_t(rawValue: 0xABCD)),
            "0xabcd"
        )
    }

    func test_tlsCipherName_returnsNilForNil() {
        XCTAssertNil(HTTPCapture.tlsCipherName(nil))
    }

    // MARK: F17 — networkProtocolNormalised (T17.1 + T17.3)

    func test_networkProtocolNormalised_passesThroughH2H3() {
        XCTAssertEqual(HTTPCapture.networkProtocolNormalised("h2"), "h2")
        XCTAssertEqual(HTTPCapture.networkProtocolNormalised("h3"), "h3")
    }

    func test_networkProtocolNormalised_collapsesHTTP11() {
        XCTAssertEqual(HTTPCapture.networkProtocolNormalised("http/1.1"), "h1.1")
        XCTAssertEqual(HTTPCapture.networkProtocolNormalised("HTTP/1.1"), "h1.1")
    }

    func test_networkProtocolNormalised_collapsesHTTP10() {
        XCTAssertEqual(HTTPCapture.networkProtocolNormalised("http/1.0"), "h1.0")
    }

    func test_networkProtocolNormalised_returnsNilForNilOrEmpty() {
        XCTAssertNil(HTTPCapture.networkProtocolNormalised(nil))
        XCTAssertNil(HTTPCapture.networkProtocolNormalised(""))
    }

    func test_networkProtocolNormalised_lowercasesUnknownToken() {
        XCTAssertEqual(HTTPCapture.networkProtocolNormalised("SPDY/3"), "spdy/3")
    }

    // MARK: F17 — MetricsView.fetchStartToResponseEndMs (T17.3)

    func test_metricsView_fetchStartToResponseEndMs_spansRedirectChain() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000.0)
        let txnA = FakeTransactionMetrics(
            responseEndDate: t0.addingTimeInterval(0.150),
            fetchStartDate: t0
        )
        let txnB = FakeTransactionMetrics(
            responseEndDate: t0.addingTimeInterval(0.392),
            fetchStartDate: t0.addingTimeInterval(0.160)
        )
        let view = MetricsView(redirectCount: 1, transactions: [txnA, txnB])
        XCTAssertEqual(view.fetchStartToResponseEndMs, 392)
    }

    func test_metricsView_fetchStartToResponseEndMs_returnsNilWithoutBookends() {
        let txn = FakeTransactionMetrics()
        let view = MetricsView(redirectCount: 0, transactions: [txn])
        XCTAssertNil(view.fetchStartToResponseEndMs)
    }

    func test_metricsView_fetchStartToResponseEndMs_clampsNegativeToZero() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000.0)
        let txn = FakeTransactionMetrics(
            responseEndDate: t0,
            fetchStartDate: t0.addingTimeInterval(0.5)
        )
        let view = MetricsView(redirectCount: 0, transactions: [txn])
        XCTAssertEqual(view.fetchStartToResponseEndMs, 0)
    }

    // MARK: F17 — ResourceTiming.from(view:) (T17.3)

    func test_resourceTiming_derivesAllFieldsFromLastTransaction() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000.0)
        let txn = FakeTransactionMetrics(
            domainLookupStartDate: t0,
            domainLookupEndDate: t0.addingTimeInterval(0.012),
            connectStartDate: t0.addingTimeInterval(0.012),
            connectEndDate: t0.addingTimeInterval(0.043),
            secureConnectionStartDate: t0.addingTimeInterval(0.045),
            secureConnectionEndDate: t0.addingTimeInterval(0.090),
            requestEndDate: t0.addingTimeInterval(0.095),
            responseStartDate: t0.addingTimeInterval(0.149),
            responseEndDate: t0.addingTimeInterval(0.150)
        )
        let view = MetricsView(redirectCount: 0, transactions: [txn])
        let timing = ResourceTiming.from(view: view)
        XCTAssertNotNil(timing)
        XCTAssertEqual(timing?.dnsMs, 12)
        XCTAssertEqual(timing?.connectMs, 31)
        XCTAssertEqual(timing?.tlsMs, 45)
        XCTAssertEqual(timing?.ttfbMs, 54)
        XCTAssertEqual(timing?.downloadMs, 1)
    }

    func test_resourceTiming_returnsNilForEmptyTransactions() {
        let view = MetricsView(redirectCount: 0, transactions: [])
        XCTAssertNil(ResourceTiming.from(view: view))
    }

    // MARK: F17 — recordOutcomeWithView end-to-end (T17.1 + T17.3)

    func test_recordOutcomeWithView_emitsAllF17AttributesOnHTTPRequest() {
        let url = URL(string: "https://api.example.com/v1/users")!
        let request = URLRequest(url: url)
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
        )
        let t0 = Date(timeIntervalSince1970: 1_700_000_000.0)
        let txn = FakeTransactionMetrics(
            domainLookupStartDate: t0,
            domainLookupEndDate: t0.addingTimeInterval(0.011),
            connectStartDate: t0.addingTimeInterval(0.011),
            connectEndDate: t0.addingTimeInterval(0.049),
            secureConnectionStartDate: t0.addingTimeInterval(0.050),
            secureConnectionEndDate: t0.addingTimeInterval(0.097),
            requestEndDate: t0.addingTimeInterval(0.100),
            responseStartDate: t0.addingTimeInterval(0.296),
            responseEndDate: t0.addingTimeInterval(0.346),
            fetchStartDate: t0,
            countOfRequestBodyBytesBeforeEncoding: 128,
            negotiatedTLSProtocolVersion: tls_protocol_version_t(rawValue: 0x0304),
            negotiatedTLSCipherSuite: tls_ciphersuite_t(rawValue: 0x1301),
            isReusedConnection: true,
            isProxyConnection: false,
            networkProtocolName: "h2"
        )
        let view = MetricsView(redirectCount: 0, transactions: [txn])

        HTTPCapture.recordOutcomeWithView(
            request: request,
            response: response,
            data: Data(count: 1234),
            view: view,
            error: nil,
            startedAt: t0,
            finishedAt: t0.addingTimeInterval(0.346),
            taskDescription: nil,
            recorder: probe,
            config: HTTPCaptureConfig()
        )

        XCTAssertEqual(probe.calls.count, 2)
        guard case .event(let evName, let evAttrs) = probe.calls[0] else {
            XCTFail("Expected event"); return
        }
        XCTAssertEqual(evName, "http.request")
        XCTAssertEqual(evAttrs["http.redirect_count"], .int(0))
        XCTAssertEqual(evAttrs["http.tls_protocol"], .string("1.3"))
        XCTAssertEqual(evAttrs["http.tls_cipher"], .string("TLS_AES_128_GCM_SHA256"))
        XCTAssertEqual(evAttrs["http.reused_connection"], .bool(true))
        XCTAssertEqual(evAttrs["http.proxy_connection"], .bool(false))
        XCTAssertEqual(evAttrs["http.network_protocol"], .string("h2"))
        XCTAssertEqual(evAttrs["http.request_body_bytes_before_encoding"], .int(128))

        guard case .performance(let metricName, let metricAttrs) = probe.calls[1] else {
            XCTFail("Expected performance"); return
        }
        XCTAssertEqual(metricName, "resource_timing")
        XCTAssertEqual(metricAttrs["resource.dns_ms"], .int(11))
        XCTAssertEqual(metricAttrs["resource.download_ms"], .int(50))
        XCTAssertEqual(metricAttrs["resource.redirect_count"], .int(0))
        XCTAssertEqual(metricAttrs["resource.transaction_count"], .int(1))
        XCTAssertEqual(metricAttrs["resource.fetch_start_to_response_end_ms"], .int(346))
        XCTAssertEqual(metricAttrs["resource.protocol"], .string("h2"))
        XCTAssertNil(metricAttrs["resource.response_ms"], "F17 renamed response_ms → download_ms")
    }

    func test_recordOutcomeWithView_emitsMultiTransactionCountsForRedirectChain() {
        let url = URL(string: "https://api.example.com/u")!
        let request = URLRequest(url: url)
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
        )
        let t0 = Date(timeIntervalSince1970: 1_700_000_000.0)
        let redirect = FakeTransactionMetrics(
            domainLookupStartDate: t0,
            domainLookupEndDate: t0.addingTimeInterval(0.005),
            responseEndDate: t0.addingTimeInterval(0.080),
            fetchStartDate: t0,
            countOfRequestBodyBytesBeforeEncoding: 32,
            networkProtocolName: "http/1.1"
        )
        let final = FakeTransactionMetrics(
            domainLookupStartDate: t0.addingTimeInterval(0.080),
            domainLookupEndDate: t0.addingTimeInterval(0.090),
            requestEndDate: t0.addingTimeInterval(0.100),
            responseStartDate: t0.addingTimeInterval(0.250),
            responseEndDate: t0.addingTimeInterval(0.300),
            fetchStartDate: t0.addingTimeInterval(0.080),
            countOfRequestBodyBytesBeforeEncoding: 32,
            isReusedConnection: false,
            networkProtocolName: "h2"
        )
        let view = MetricsView(redirectCount: 1, transactions: [redirect, final])

        HTTPCapture.recordOutcomeWithView(
            request: request,
            response: response,
            data: nil,
            view: view,
            error: nil,
            startedAt: t0,
            finishedAt: t0.addingTimeInterval(0.300),
            taskDescription: nil,
            recorder: probe,
            config: HTTPCaptureConfig()
        )

        guard case .event(_, let evAttrs) = probe.calls[0] else {
            XCTFail("Expected event"); return
        }
        XCTAssertEqual(evAttrs["http.redirect_count"], .int(1))
        XCTAssertEqual(
            evAttrs["http.request_body_bytes_before_encoding"], .int(64),
            "Summed across both transactions"
        )
        // Final transaction wins for TLS/connection state.
        XCTAssertEqual(evAttrs["http.network_protocol"], .string("h2"))

        guard case .performance(_, let metricAttrs) = probe.calls[1] else {
            XCTFail("Expected performance"); return
        }
        XCTAssertEqual(metricAttrs["resource.redirect_count"], .int(1))
        XCTAssertEqual(metricAttrs["resource.transaction_count"], .int(2))
        XCTAssertEqual(metricAttrs["resource.fetch_start_to_response_end_ms"], .int(300))
    }

    func test_recordOutcomeWithView_omitsTLSAttributesForCleartextConnection() {
        let url = URL(string: "http://internal.example.com/u")!
        let request = URLRequest(url: url)
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
        )
        let t0 = Date(timeIntervalSince1970: 1_700_000_000.0)
        let txn = FakeTransactionMetrics(
            requestEndDate: t0.addingTimeInterval(0.05),
            responseStartDate: t0.addingTimeInterval(0.15),
            responseEndDate: t0.addingTimeInterval(0.16),
            fetchStartDate: t0,
            networkProtocolName: "http/1.1"
        )
        let view = MetricsView(redirectCount: 0, transactions: [txn])

        HTTPCapture.recordOutcomeWithView(
            request: request,
            response: response,
            data: nil,
            view: view,
            error: nil,
            startedAt: t0,
            finishedAt: t0.addingTimeInterval(0.16),
            taskDescription: nil,
            recorder: probe,
            config: HTTPCaptureConfig()
        )

        guard case .event(_, let evAttrs) = probe.calls[0] else {
            XCTFail("Expected event"); return
        }
        XCTAssertNil(evAttrs["http.tls_protocol"], "TLS fields omitted for cleartext HTTP")
        XCTAssertNil(evAttrs["http.tls_cipher"])
        // But network_protocol still present.
        XCTAssertEqual(evAttrs["http.network_protocol"], .string("h1.1"))
    }

    // MARK: F17 — T17.2 cellular_fallback (iOS 17+)

    func test_recordOutcomeWithView_cellularFallbackPresentOnIOS17OrLater() {
        let url = URL(string: "https://api.example.com/u")!
        let request = URLRequest(url: url)
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
        )
        let t0 = Date(timeIntervalSince1970: 1_700_000_000.0)
        let txn = FakeTransactionMetrics(
            fetchStartDate: t0,
            negotiatedTLSProtocolVersion: tls_protocol_version_t(rawValue: 0x0304),
            networkProtocolName: "h2",
            isMultipath: true,
            isCellular: true
        )
        let view = MetricsView(redirectCount: 0, transactions: [txn])

        HTTPCapture.recordOutcomeWithView(
            request: request,
            response: response,
            data: nil,
            view: view,
            error: nil,
            startedAt: t0,
            finishedAt: t0.addingTimeInterval(0.1),
            taskDescription: nil,
            recorder: probe,
            config: HTTPCaptureConfig()
        )

        guard case .event(_, let evAttrs) = probe.calls[0] else {
            XCTFail("Expected event"); return
        }
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
            XCTAssertEqual(evAttrs["http.cellular_fallback"], .bool(true))
        } else {
            XCTAssertNil(evAttrs["http.cellular_fallback"])
        }
    }

    func test_recordOutcomeWithView_cellularFallbackFalseWhenNotMultipathAndCellular() {
        let url = URL(string: "https://api.example.com/u")!
        let request = URLRequest(url: url)
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
        )
        let t0 = Date(timeIntervalSince1970: 1_700_000_000.0)
        let txn = FakeTransactionMetrics(
            fetchStartDate: t0,
            isMultipath: false,
            isCellular: true
        )
        let view = MetricsView(redirectCount: 0, transactions: [txn])

        HTTPCapture.recordOutcomeWithView(
            request: request,
            response: response,
            data: nil,
            view: view,
            error: nil,
            startedAt: t0,
            finishedAt: t0.addingTimeInterval(0.1),
            taskDescription: nil,
            recorder: probe,
            config: HTTPCaptureConfig()
        )

        guard case .event(_, let evAttrs) = probe.calls[0] else {
            XCTFail("Expected event"); return
        }
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
            XCTAssertEqual(
                evAttrs["http.cellular_fallback"], .bool(false),
                "False when not both multipath and cellular"
            )
        }
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
