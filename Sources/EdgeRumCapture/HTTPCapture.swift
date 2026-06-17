// Sources/EdgeRumCapture/HTTPCapture.swift
//
// F8 — HTTP request capture (URLSession).
//
// Layered interception (PLAN-iOS.md §6.3):
//
//   1. `EdgeRumURLProtocol` — a `URLProtocol` subclass registered
//      globally via `URLProtocol.registerClass(_:)` so it intercepts
//      `URLSession.shared` and any session whose configuration's
//      `protocolClasses` includes it.
//   2. Class-method swizzle on `URLSessionConfiguration.default` /
//      `URLSessionConfiguration.ephemeral` so any consumer who
//      creates a custom session (with their own delegate or not)
//      picks up our protocol automatically. `background` configs
//      are not instrumented — they have no in-process delegate
//      window for `URLSessionTaskMetrics`.
//
// Internal session inside the protocol owns a `MetricsDelegate`
// that captures both the response stream and
// `URLSessionTaskMetrics`. That delegate is the "delegate proxy"
// in PLAN-iOS.md §6.3 — the consumer's own delegate never sees
// our internal traffic. After the task completes, we drive the
// recording pipeline through `HTTPCapture.recordOutcome(...)`:
//
//   1. Defense-in-depth filter (internal-header / task-description /
//      endpoint-host) — three independent checks per CLAUDE.md
//      "We do not call our own POST endpoint from instrumented
//      sessions".
//   2. `config.ignoreUrls` regex match → drop.
//   3. `config.sanitizeUrl` callback applied synchronously to the
//      URL before any wire value is built.
//   4. Emit `http.request` event + (when metrics present)
//      `resource_timing` metric.
//
// All wire keys come from PLAN-iOS.md §6.3 verbatim.
// All values flatten to `AttributeValue` primitives (the type
// system enforces it).
//
// Refs: PLAN-iOS.md §F8 (lines 1934-1965), §6.3 (lines 641-667);
//       CLAUDE.md "eventName values" + "When in doubt checklist"
//       items 1, 2, 3, 4, 8.
//

import Foundation
import os.log
import Security
#if canImport(EdgeRumCore)
import EdgeRumCore
#endif

// MARK: - Public configuration carrier

/// Static configuration handed to `HTTPCapture` at install time. Carries
/// the subset of `EdgeRumConfig` that the capture path needs without
/// pulling in the public umbrella module. `EdgeRum.start(_:)` builds one
/// of these and passes it via `HTTPCapture.configure(_:)`.
///
/// `public` here only means "visible to other internal SDK targets and
/// the test target". `EdgeRumCapture` is not a SwiftPM `product`, so
/// consumers who write `import EdgeRum` never see this type.
public struct HTTPCaptureConfig: @unchecked Sendable {

    /// Regular expressions matched against the recorded URL string. A
    /// match drops the event before enqueue (T8.5).
    public let ignoreUrls: [NSRegularExpression]

    /// Synchronous URL sanitiser. Applied on the caller thread before
    /// the URL becomes a wire value (T8.5). The sanitised URL is also
    /// reflected on the companion `resource_timing` metric so query
    /// strings stay redacted across both signals.
    public let sanitizeUrl: (@Sendable (URL) -> URL)?

    /// Host portion of the SDK's collector endpoint, used as the
    /// third defense-in-depth check so a misconfigured custom
    /// session that bypasses our protocol can still be filtered.
    public let endpointHost: String?

    public init(
        ignoreUrls: [NSRegularExpression] = [],
        sanitizeUrl: (@Sendable (URL) -> URL)? = nil,
        endpointHost: String? = nil
    ) {
        self.ignoreUrls = ignoreUrls
        self.sanitizeUrl = sanitizeUrl
        self.endpointHost = endpointHost
    }
}

// MARK: - HTTPCapture installer

/// F8 installer — HTTP request capture via `URLProtocol` registration
/// plus `URLSessionConfiguration` class-method swizzles.
///
/// `public` here only means "visible to other internal SDK targets
/// and the test target". `EdgeRumCapture` is not a SwiftPM `product`,
/// so consumers who write `import EdgeRum` never see this type.
public enum HTTPCapture {

    // MARK: Diagnostics

    internal static let log = OSLog(subsystem: "com.edge.rum", category: "HTTPCapture")

    // MARK: Once token

    nonisolated(unsafe) private static let installLock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()

    nonisolated(unsafe) private static var _installed: Bool = false

    /// `true` once `install(...)` has registered the URLProtocol and
    /// swapped the configuration getters. Module-internal — never used
    /// by consumers.
    public static var isInstalled: Bool {
        os_unfair_lock_lock(installLock)
        defer { os_unfair_lock_unlock(installLock) }
        return _installed
    }

    // MARK: Live config

    nonisolated(unsafe) private static let configLock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()

    nonisolated(unsafe) private static var _config: HTTPCaptureConfig = HTTPCaptureConfig()

    internal static var currentConfig: HTTPCaptureConfig {
        os_unfair_lock_lock(configLock)
        defer { os_unfair_lock_unlock(configLock) }
        return _config
    }

    /// Install the host-supplied config so the capture path can read
    /// `ignoreUrls`, `sanitizeUrl`, and the collector host. Safe to call
    /// repeatedly — the latest value wins. Called from
    /// `EdgeRum.start(_:)` before `install(_:)`.
    public static func configure(_ config: HTTPCaptureConfig) {
        os_unfair_lock_lock(configLock)
        _config = config
        os_unfair_lock_unlock(configLock)
    }

    // MARK: Diagnostics flag

    nonisolated(unsafe) private static var _debug: Bool = false

    internal static var debugEnabled: Bool {
        os_unfair_lock_lock(installLock)
        defer { os_unfair_lock_unlock(installLock) }
        return _debug
    }

    // MARK: Public install

    /// Install the HTTP capture hooks. Idempotent and thread-safe;
    /// only the first call performs the URLProtocol registration and
    /// configuration-getter swizzles. Subsequent calls are silent
    /// no-ops.
    ///
    /// May be called from any thread — `URLProtocol.registerClass(_:)`
    /// and `method_exchangeImplementations` are thread-safe, and the
    /// `installLock` serialises the "have I done this yet?" decision.
    /// Unlike `UIViewControllerCapture`, the HTTP capture layer does
    /// not touch UIKit so there's no main-thread requirement.
    ///
    /// - Parameter debug: when `true`, install diagnostics route to
    ///   `os_log` so the host can confirm the install landed. When
    ///   `false` (production default) the install is silent.
    public static func install(debug: Bool = false) {
        performInstall(debug: debug)
    }

    private static func performInstall(debug: Bool) {
        os_unfair_lock_lock(installLock)
        if _installed {
            _debug = debug || _debug
            os_unfair_lock_unlock(installLock)
            return
        }
        _debug = debug

        // 1. Global registration — covers URLSession.shared.
        URLProtocol.registerClass(EdgeRumURLProtocol.self)

        // 2. Swap the class-method getters on URLSessionConfiguration
        //    so consumer-created `default` / `ephemeral` configs pick
        //    up our protocol automatically.
        URLSessionConfiguration.edgerum_installProtocolClassesSwizzle()

        _installed = true
        os_unfair_lock_unlock(installLock)
        if debug {
            os_log("HTTPCapture installed", log: log, type: .info)
        }
    }

    // MARK: Filtering

    /// Three independent checks. Any match means we ignore the request.
    internal static func shouldCaptureRequest(
        _ request: URLRequest,
        taskDescription: String?,
        config: HTTPCaptureConfig
    ) -> Bool {
        // 1. Internal marker header.
        if let header = request.value(forHTTPHeaderField: "X-Edge-Rum-Internal"),
           !header.isEmpty {
            return false
        }
        // 2. Task description marker (set by BatchTransport on its tasks).
        if taskDescription == "edge-rum-internal" {
            return false
        }
        // 3. Endpoint host prefix — defends against misconfigured custom
        //    sessions that bypass both markers.
        if let collectorHost = config.endpointHost,
           let requestHost = request.url?.host,
           !collectorHost.isEmpty,
           requestHost == collectorHost {
            return false
        }
        return true
    }

    // MARK: ignoreUrls

    internal static func matchesIgnoredUrl(
        _ urlString: String,
        config: HTTPCaptureConfig
    ) -> Bool {
        for regex in config.ignoreUrls {
            let range = NSRange(urlString.startIndex..., in: urlString)
            if regex.firstMatch(in: urlString, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    // MARK: Recording

    /// The single sink driven by `EdgeRumURLProtocol`'s metrics delegate.
    /// Applies the four-step pipeline (filter → ignore → sanitise →
    /// emit) per PLAN-iOS.md §6.3.
    internal static func recordOutcome(
        request: URLRequest,
        response: URLResponse?,
        data: Data?,
        metrics: URLSessionTaskMetrics?,
        error: Error?,
        startedAt: Date,
        finishedAt: Date,
        taskDescription: String?,
        recorder: Recording? = nil,
        config: HTTPCaptureConfig? = nil
    ) {
        let view = metrics.map { MetricsView(from: $0) }
        recordOutcomeWithView(
            request: request,
            response: response,
            data: data,
            view: view,
            error: error,
            startedAt: startedAt,
            finishedAt: finishedAt,
            taskDescription: taskDescription,
            recorder: recorder,
            config: config
        )
    }

    /// Same pipeline as `recordOutcome` but takes the decomposed metrics
    /// view directly. The production path goes via `recordOutcome` (which
    /// wraps `URLSessionTaskMetrics`); tests drive this entry with a
    /// `FakeTransactionMetrics` fixture so they can exercise multi-
    /// transaction / TLS / cellular-fallback code paths without being
    /// able to construct the framework-internal class. See ADR-013.
    internal static func recordOutcomeWithView(
        request: URLRequest,
        response: URLResponse?,
        data: Data?,
        view: MetricsView?,
        error: Error?,
        startedAt: Date,
        finishedAt: Date,
        taskDescription: String?,
        recorder: Recording? = nil,
        config: HTTPCaptureConfig? = nil
    ) {
        let liveRecorder = recorder ?? Recorder.shared
        guard liveRecorder.isEnabled else { return }

        let activeConfig = config ?? currentConfig

        guard shouldCaptureRequest(request, taskDescription: taskDescription, config: activeConfig) else {
            return
        }
        guard let originalUrl = request.url else { return }

        let sanitisedUrl: URL
        if let sanitize = activeConfig.sanitizeUrl {
            sanitisedUrl = sanitize(originalUrl)
        } else {
            sanitisedUrl = originalUrl
        }
        let urlString = sanitisedUrl.absoluteString

        if matchesIgnoredUrl(urlString, config: activeConfig) {
            return
        }

        let durationMs = Int((finishedAt.timeIntervalSince(startedAt) * 1000.0).rounded())
        let method = request.httpMethod ?? "GET"
        let host = sanitisedUrl.host ?? ""
        let path = sanitisedUrl.path

        var statusCode: Int = 0
        var fromCache = false
        if let http = response as? HTTPURLResponse {
            statusCode = http.statusCode
        }
        if let last = view?.transactions.last {
            fromCache = last.resourceFetchType == .localCache
        }

        let requestSize = computeRequestBytes(request, view: view)
        let responseSize = computeResponseBytes(data: data, response: response, view: view)

        var attrs: [String: AttributeValue] = [
            "http.method": .string(method),
            "http.url": .string(urlString),
            "http.host": .string(host),
            "http.path": .string(path),
            "http.status_code": .int(statusCode),
            "http.duration_ms": .int(max(0, durationMs)),
            "http.request_size": .int(Int(max(0, requestSize))),
            "http.response_size": .int(Int(max(0, responseSize))),
            "http.from_cache": .bool(fromCache)
        ]
        if let error {
            attrs["http.error"] = .string(String(describing: error))
        }
        applyHTTPMetricsEnrichment(into: &attrs, view: view)

        liveRecorder.recordEvent(name: "http.request", attributes: attrs)

        if let view, let timing = ResourceTiming.from(view: view) {
            var metricAttrs: [String: AttributeValue] = [
                "resource.url": .string(urlString),
                "resource.host": .string(host),
                "resource.dns_ms": .int(timing.dnsMs),
                "resource.connect_ms": .int(timing.connectMs),
                "resource.tls_ms": .int(timing.tlsMs),
                "resource.ttfb_ms": .int(timing.ttfbMs),
                "resource.download_ms": .int(timing.downloadMs),
                "resource.redirect_count": .int(view.redirectCount),
                "resource.transaction_count": .int(view.transactions.count)
            ]
            if let totalMs = view.fetchStartToResponseEndMs {
                metricAttrs["resource.fetch_start_to_response_end_ms"] = .int(totalMs)
            }
            if let proto = view.transactions.last.flatMap({ networkProtocolNormalised($0.networkProtocolName) }) {
                metricAttrs["resource.protocol"] = .string(proto)
            }
            metricAttrs["value"] = .double(Double(durationMs))
            liveRecorder.recordPerformance(name: "resource_timing", attributes: metricAttrs)
        }
    }

    // MARK: F17 enrichment — http.request

    /// Adds the F17 URLSession-metrics-derived attributes to the
    /// `http.request` event. All TLS / connection fields come from the
    /// LAST transaction (the response-delivering one); body-bytes-before-
    /// encoding sums across all transactions.
    ///
    /// Each attribute is conditional: when the underlying field is nil or
    /// the connection wasn't encrypted (TLS fields), the key is omitted
    /// entirely — matching the pattern used for `http.error`.
    internal static func applyHTTPMetricsEnrichment(
        into attrs: inout [String: AttributeValue],
        view: MetricsView?
    ) {
        guard let view else { return }

        attrs["http.redirect_count"] = .int(view.redirectCount)

        guard let last = view.transactions.last else { return }

        if let tlsProtocol = tlsProtocolName(last.negotiatedTLSProtocolVersion) {
            attrs["http.tls_protocol"] = .string(tlsProtocol)
        }
        if let tlsCipher = tlsCipherName(last.negotiatedTLSCipherSuite) {
            attrs["http.tls_cipher"] = .string(tlsCipher)
        }
        attrs["http.reused_connection"] = .bool(last.isReusedConnection)
        attrs["http.proxy_connection"] = .bool(last.isProxyConnection)
        if let proto = networkProtocolNormalised(last.networkProtocolName) {
            attrs["http.network_protocol"] = .string(proto)
        }

        let bytesBefore = view.transactions.reduce(Int64(0)) { acc, txn in
            acc + max(0, txn.countOfRequestBodyBytesBeforeEncoding)
        }
        attrs["http.request_body_bytes_before_encoding"] = .int(Int(bytesBefore))

        // T17.2: iOS 17+ multipath/cellular fallback. PLAN-iOS.md §16.4
        // pins this to iOS 17+ even though `isMultipath` / `isCellular`
        // exist since iOS 13 — keep the gate per the documented contract.
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
            attrs["http.cellular_fallback"] = .bool(last.isMultipath && last.isCellular)
        }
    }

    // MARK: F17 mapping helpers

    /// Map an Apple `tls_protocol_version_t` raw value to the wire string
    /// shape (`"1.0"`, `"1.1"`, `"1.2"`, `"1.3"`). Returns nil when the
    /// transaction was not encrypted (input nil) or when the value is
    /// unrecognised — keeps the key absent rather than emitting a bogus
    /// value the backend can't filter on.
    internal static func tlsProtocolName(_ value: tls_protocol_version_t?) -> String? {
        guard let value else { return nil }
        switch value.rawValue {
        case 0x0301: return "1.0"
        case 0x0302: return "1.1"
        case 0x0303: return "1.2"
        case 0x0304: return "1.3"
        default: return nil
        }
    }

    /// Map an Apple `tls_ciphersuite_t` raw value to the IANA cipher-suite
    /// name. Covers the suites Apple's TLS stack actually negotiates on
    /// iOS 14+; unknown values fall back to a hex string so the key is
    /// always present when TLS is.
    internal static func tlsCipherName(_ value: tls_ciphersuite_t?) -> String? {
        guard let value else { return nil }
        let raw = value.rawValue
        switch raw {
        // TLS 1.3 suites
        case 0x1301: return "TLS_AES_128_GCM_SHA256"
        case 0x1302: return "TLS_AES_256_GCM_SHA384"
        case 0x1303: return "TLS_CHACHA20_POLY1305_SHA256"
        // TLS 1.2 ECDHE-ECDSA
        case 0xC02B: return "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"
        case 0xC02C: return "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384"
        case 0xCCA9: return "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256"
        case 0xC023: return "TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256"
        case 0xC024: return "TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384"
        case 0xC009: return "TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA"
        case 0xC00A: return "TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA"
        // TLS 1.2 ECDHE-RSA
        case 0xC02F: return "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"
        case 0xC030: return "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"
        case 0xCCA8: return "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256"
        case 0xC027: return "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256"
        case 0xC028: return "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA384"
        case 0xC013: return "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA"
        case 0xC014: return "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA"
        // Static RSA (legacy)
        case 0x009C: return "TLS_RSA_WITH_AES_128_GCM_SHA256"
        case 0x009D: return "TLS_RSA_WITH_AES_256_GCM_SHA384"
        case 0x002F: return "TLS_RSA_WITH_AES_128_CBC_SHA"
        case 0x0035: return "TLS_RSA_WITH_AES_256_CBC_SHA"
        default:
            return String(format: "0x%04x", raw)
        }
    }

    /// Normalise the ALPN protocol identifier to the wire shape used on
    /// `http.network_protocol` / `resource.protocol`. ALPN ids are
    /// lowercase per RFC 7301 (e.g. `h2`, `h3`, `http/1.1`); we collapse
    /// `http/1.1` to `h1.1` for parity with the Android SDK. Returns nil
    /// when no protocol was negotiated (e.g. cached / local resource).
    internal static func networkProtocolNormalised(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let lower = value.lowercased()
        switch lower {
        case "h2", "h3": return lower
        case "http/1.1", "h1.1": return "h1.1"
        case "http/1.0": return "h1.0"
        default: return lower
        }
    }

    // MARK: Byte-count helpers

    private static func computeRequestBytes(
        _ request: URLRequest,
        view: MetricsView?
    ) -> Int64 {
        if let view {
            let total = view.transactions.reduce(Int64(0)) { acc, txn in
                acc + max(0, txn.countOfRequestHeaderBytesSent) + max(0, txn.countOfRequestBodyBytesSent)
            }
            if total > 0 { return total }
        }
        if let body = request.httpBody {
            return Int64(body.count)
        }
        return 0
    }

    private static func computeResponseBytes(
        data: Data?,
        response: URLResponse?,
        view: MetricsView?
    ) -> Int64 {
        if let view {
            let total = view.transactions.reduce(Int64(0)) { acc, txn in
                acc + max(0, txn.countOfResponseHeaderBytesReceived) + max(0, txn.countOfResponseBodyBytesReceived)
            }
            if total > 0 { return total }
        }
        if let data = data, !data.isEmpty {
            return Int64(data.count)
        }
        if let response, response.expectedContentLength > 0 {
            return response.expectedContentLength
        }
        return 0
    }

    // MARK: Test-only helpers

    #if DEBUG
    /// Mark the install as "not done" so tests that want to verify the
    /// opt-out path can drive `EdgeRum.start()` and assert
    /// `isInstalled` stayed `false`. URLProtocol registration is NOT
    /// undone — `URLProtocol.unregisterClass(_:)` is safe but tests
    /// must call it themselves if they want a clean slate.
    public static func _resetInstallFlagForTesting() {
        os_unfair_lock_lock(installLock)
        _installed = false
        _debug = false
        os_unfair_lock_unlock(installLock)
    }

    /// Restore the default empty config so successive tests don't see
    /// each other's `ignoreUrls` / `sanitizeUrl`.
    public static func _resetConfigForTesting() {
        configure(HTTPCaptureConfig())
    }

    /// Hard-unregister the URLProtocol class. Pairs with
    /// `_resetInstallFlagForTesting()` for tests that exercise the
    /// registration directly. No-op when not registered.
    public static func _unregisterURLProtocolForTesting() {
        URLProtocol.unregisterClass(EdgeRumURLProtocol.self)
    }
    #endif
}

// MARK: - Transaction metrics protocol seam (F17)

/// Internal protocol mirroring the subset of
/// `URLSessionTaskTransactionMetrics` fields F17 reads. Apple's class is
/// framework-internal and cannot be subclassed or constructed in tests
/// since iOS 13 deprecated its `init`. Tests substitute a struct
/// (`FakeTransactionMetrics`) conforming to this protocol so the
/// enrichment + derivation logic is exercised without network IO.
///
/// Mirror of the relevant public properties verified against the SDK
/// header (`NSURLSession.h` in the iPhoneOS SDK).
internal protocol TransactionMetricsLike {
    var domainLookupStartDate: Date? { get }
    var domainLookupEndDate: Date? { get }
    var connectStartDate: Date? { get }
    var connectEndDate: Date? { get }
    var secureConnectionStartDate: Date? { get }
    var secureConnectionEndDate: Date? { get }
    var requestEndDate: Date? { get }
    var responseStartDate: Date? { get }
    var responseEndDate: Date? { get }
    var fetchStartDate: Date? { get }

    var countOfRequestHeaderBytesSent: Int64 { get }
    var countOfRequestBodyBytesSent: Int64 { get }
    var countOfRequestBodyBytesBeforeEncoding: Int64 { get }
    var countOfResponseHeaderBytesReceived: Int64 { get }
    var countOfResponseBodyBytesReceived: Int64 { get }

    var negotiatedTLSProtocolVersion: tls_protocol_version_t? { get }
    var negotiatedTLSCipherSuite: tls_ciphersuite_t? { get }
    var isReusedConnection: Bool { get }
    var isProxyConnection: Bool { get }
    var networkProtocolName: String? { get }
    var resourceFetchType: URLSessionTaskMetrics.ResourceFetchType { get }
    var isMultipath: Bool { get }
    var isCellular: Bool { get }
}

// Real Foundation type already exposes every property above with the
// same name + type. Empty conformance is sufficient.
extension URLSessionTaskTransactionMetrics: TransactionMetricsLike {}

/// Aggregated view of `URLSessionTaskMetrics` decomposed into the fields
/// F17 reads. Lets the recording sink + ResourceTiming derivation work
/// against test fixtures and the real Foundation type uniformly.
internal struct MetricsView {
    let redirectCount: Int
    let transactions: [TransactionMetricsLike]

    init(redirectCount: Int, transactions: [TransactionMetricsLike]) {
        self.redirectCount = redirectCount
        self.transactions = transactions
    }

    init(from metrics: URLSessionTaskMetrics) {
        self.redirectCount = metrics.redirectCount
        self.transactions = metrics.transactionMetrics.map { $0 as TransactionMetricsLike }
    }

    /// First-transaction `fetchStartDate` → last-transaction
    /// `responseEndDate`. Drives `resource.fetch_start_to_response_end_ms`
    /// (T17.3 — total wall-clock across the redirect chain). Returns nil
    /// when either bookend date is missing.
    var fetchStartToResponseEndMs: Int? {
        guard
            let first = transactions.first?.fetchStartDate,
            let end = transactions.last?.responseEndDate
        else { return nil }
        let delta = end.timeIntervalSince(first)
        return Int(max(0, (delta * 1000.0).rounded()))
    }
}

// MARK: - ResourceTiming derivation

internal struct ResourceTiming {
    let dnsMs: Int
    let connectMs: Int
    let tlsMs: Int
    let ttfbMs: Int
    let downloadMs: Int

    /// Derive timing from the LAST transaction (the one that actually
    /// delivered the response). Returns nil when no transaction is
    /// present.
    static func from(view: MetricsView) -> ResourceTiming? {
        guard let txn = view.transactions.last else { return nil }
        return ResourceTiming(
            dnsMs: msBetween(txn.domainLookupStartDate, txn.domainLookupEndDate),
            connectMs: msBetween(txn.connectStartDate, txn.connectEndDate),
            tlsMs: msBetween(txn.secureConnectionStartDate, txn.secureConnectionEndDate),
            ttfbMs: msBetween(txn.requestEndDate, txn.responseStartDate),
            downloadMs: msBetween(txn.responseStartDate, txn.responseEndDate)
        )
    }

    internal static func msBetween(_ start: Date?, _ end: Date?) -> Int {
        guard let start, let end else { return 0 }
        let delta = end.timeIntervalSince(start)
        return Int(max(0, (delta * 1000.0).rounded()))
    }
}

// MARK: - URLProtocol subclass

/// Internal `URLProtocol` subclass that observes outgoing
/// `URLSession.shared` traffic (and any custom session whose
/// configuration includes us). Performs the actual URL load through a
/// dedicated internal session so `URLSessionTaskMetrics` are
/// collectable, then proxies the response back to the original client.
///
/// Idempotency is guarded by a per-request property
/// (`processedKey`) set in `canonicalRequest(for:)` so the inner
/// session's task does not get re-intercepted by this same protocol.
internal final class EdgeRumURLProtocol: URLProtocol {

    /// Marker property set on the request handed to the internal
    /// session so `canInit(with:)` rejects the re-entry.
    static let processedKey = "EdgeRumHTTPCaptureProcessed"

    private var dataTask: URLSessionDataTask?
    private var internalSession: URLSession?
    private var receivedData = Data()
    private var startedAt: Date = Date(timeIntervalSince1970: 0)
    private var finishedAt: Date = Date(timeIntervalSince1970: 0)
    private var collectedMetrics: URLSessionTaskMetrics?

    // MARK: URLProtocol overrides

    override class func canInit(with request: URLRequest) -> Bool {
        // 1. Already intercepted — let the system continue normally.
        if URLProtocol.property(forKey: processedKey, in: request) as? Bool == true {
            return false
        }
        // 2. Only intercept HTTP/HTTPS.
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        guard scheme == "http" || scheme == "https" else { return false }
        // 3. Defense-in-depth filter (header + endpoint host).
        //    `taskDescription` is unavailable at this layer; the
        //    metrics-delegate path re-checks it.
        let config = HTTPCapture.currentConfig
        return HTTPCapture.shouldCaptureRequest(request, taskDescription: nil, config: config)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override class func requestIsCacheEquivalent(_ a: URLRequest, to b: URLRequest) -> Bool {
        return super.requestIsCacheEquivalent(a, to: b)
    }

    override func startLoading() {
        // Build a request that won't re-enter our protocol.
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        URLProtocol.setProperty(true, forKey: Self.processedKey, in: mutable)

        let cfg = URLSessionConfiguration.ephemeral
        // Avoid recursion explicitly — strip any of our class from the
        // internal session's protocolClasses array. Belt + braces with
        // the request property above.
        let classes = cfg.protocolClasses ?? []
        cfg.protocolClasses = classes.filter { $0 != EdgeRumURLProtocol.self }
        cfg.urlCache = nil

        let delegate = EdgeRumMetricsDelegate(owner: self)
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        self.internalSession = session
        self.startedAt = Date()
        let task = session.dataTask(with: mutable as URLRequest)
        self.dataTask = task
        task.resume()
    }

    override func stopLoading() {
        dataTask?.cancel()
        internalSession?.invalidateAndCancel()
        dataTask = nil
        internalSession = nil
    }

    // MARK: Metrics delegate callbacks

    fileprivate func didReceiveResponse(_ response: URLResponse) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    fileprivate func didReceiveData(_ data: Data) {
        receivedData.append(data)
        client?.urlProtocol(self, didLoad: data)
    }

    fileprivate func didFinishCollecting(metrics: URLSessionTaskMetrics) {
        self.collectedMetrics = metrics
    }

    fileprivate func didComplete(with error: Error?, response: URLResponse?) {
        self.finishedAt = Date()
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }

        HTTPCapture.recordOutcome(
            request: request,
            response: response,
            data: receivedData,
            metrics: collectedMetrics,
            error: error,
            startedAt: startedAt,
            finishedAt: finishedAt,
            taskDescription: dataTask?.taskDescription
        )

        // Release the internal session so the URLSession owner-graph
        // collapses cleanly.
        internalSession?.finishTasksAndInvalidate()
        internalSession = nil
        dataTask = nil
    }
}

// MARK: - Metrics-collecting delegate

/// Pumps data + response + metrics from the internal session back into
/// the `EdgeRumURLProtocol` instance. Holds a strong reference to the
/// protocol so the protocol stays alive across the async session
/// callbacks; the protocol releases the delegate via
/// `internalSession?.finishTasksAndInvalidate()` on completion.
private final class EdgeRumMetricsDelegate: NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable {

    let owner: EdgeRumURLProtocol
    private var lastResponse: URLResponse?

    init(owner: EdgeRumURLProtocol) {
        self.owner = owner
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        self.lastResponse = response
        owner.didReceiveResponse(response)
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        owner.didReceiveData(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        owner.didFinishCollecting(metrics: metrics)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        owner.didComplete(with: error, response: lastResponse ?? task.response)
    }
}

// MARK: - URLSessionConfiguration swizzle
//
// We swizzle the INSTANCE getter for `protocolClasses`. Class-method
// swizzling on `URLSessionConfiguration` is unreliable on modern
// Foundation (Swift-imported class methods abort with SIGILL when
// IMPs are swapped via `method_exchangeImplementations`). Instance
// getter swizzle is the pattern used by Datadog/Sentry/etc and works
// across iOS 14+ and the macOS test runner.
//
// After swap, any URLSession reading its configuration's
// `protocolClasses` (which is what happens during URL loading
// setup) gets back an array that starts with `EdgeRumURLProtocol`.
// Background configurations (identifier != nil) are returned
// untouched so the host's background uploads don't pass through us.

internal extension URLSessionConfiguration {

    nonisolated(unsafe) private static let swizzleLock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()

    nonisolated(unsafe) private static var _swizzled = false

    static func edgerum_installProtocolClassesSwizzle() {
        os_unfair_lock_lock(swizzleLock)
        defer { os_unfair_lock_unlock(swizzleLock) }
        if _swizzled { return }

        guard
            let original = class_getInstanceMethod(
                URLSessionConfiguration.self,
                #selector(getter: URLSessionConfiguration.protocolClasses)
            ),
            let replacement = class_getInstanceMethod(
                URLSessionConfiguration.self,
                #selector(URLSessionConfiguration.edgerum_swizzled_protocolClasses)
            )
        else {
            os_log(
                "HTTPCapture could not resolve protocolClasses getter on URLSessionConfiguration",
                log: HTTPCapture.log,
                type: .error
            )
            return
        }
        method_exchangeImplementations(original, replacement)
        _swizzled = true
    }

    // After `method_exchangeImplementations` runs, the selector
    // `protocolClasses` resolves to the body below and
    // `edgerum_swizzled_protocolClasses` resolves to Foundation's
    // original — that's why the body calls the swizzled name first.
    @objc
    func edgerum_swizzled_protocolClasses() -> [AnyClass]? {
        let originals = self.edgerum_swizzled_protocolClasses() ?? []
        // Skip background-identified configurations entirely — they
        // have no in-process delegate window for metrics (per
        // PLAN-iOS.md §6.3 edge-case note).
        if identifier != nil { return originals }
        if originals.contains(where: { $0 == EdgeRumURLProtocol.self }) {
            return originals
        }
        var result: [AnyClass] = [EdgeRumURLProtocol.self]
        result.append(contentsOf: originals)
        return result
    }
}
