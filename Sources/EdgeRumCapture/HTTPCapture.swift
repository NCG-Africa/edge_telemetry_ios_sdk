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

    private static let installLock: UnsafeMutablePointer<os_unfair_lock> = {
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

    private static let configLock: UnsafeMutablePointer<os_unfair_lock> = {
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
        if let metrics, let last = metrics.transactionMetrics.last {
            fromCache = last.resourceFetchType == .localCache
        }

        let requestSize = computeRequestBytes(request, metrics: metrics)
        let responseSize = computeResponseBytes(data: data, response: response, metrics: metrics)

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

        liveRecorder.recordEvent(name: "http.request", attributes: attrs)

        if let metrics, let timing = ResourceTiming.from(metrics: metrics) {
            var metricAttrs: [String: AttributeValue] = [
                "resource.url": .string(urlString),
                "resource.host": .string(host),
                "resource.dns_ms": .int(timing.dnsMs),
                "resource.connect_ms": .int(timing.connectMs),
                "resource.tls_ms": .int(timing.tlsMs),
                "resource.ttfb_ms": .int(timing.ttfbMs),
                "resource.response_ms": .int(timing.responseMs)
            ]
            metricAttrs["value"] = .double(Double(durationMs))
            liveRecorder.recordPerformance(name: "resource_timing", attributes: metricAttrs)
        }
    }

    // MARK: Byte-count helpers

    private static func computeRequestBytes(
        _ request: URLRequest,
        metrics: URLSessionTaskMetrics?
    ) -> Int64 {
        if let metrics {
            let total = metrics.transactionMetrics.reduce(Int64(0)) { acc, txn in
                acc + Int64(txn.countOfRequestHeaderBytesSent) + Int64(txn.countOfRequestBodyBytesSent)
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
        metrics: URLSessionTaskMetrics?
    ) -> Int64 {
        if let metrics {
            let total = metrics.transactionMetrics.reduce(Int64(0)) { acc, txn in
                acc + Int64(txn.countOfResponseHeaderBytesReceived) + Int64(txn.countOfResponseBodyBytesReceived)
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

// MARK: - ResourceTiming derivation

internal struct ResourceTiming {
    let dnsMs: Int
    let connectMs: Int
    let tlsMs: Int
    let ttfbMs: Int
    let responseMs: Int

    /// Derive timing from the LAST transaction metric (the one that
    /// actually delivered the response). Returns `nil` when no
    /// transaction is present.
    static func from(metrics: URLSessionTaskMetrics) -> ResourceTiming? {
        guard let txn = metrics.transactionMetrics.last else { return nil }
        return ResourceTiming(
            dnsMs: msBetween(txn.domainLookupStartDate, txn.domainLookupEndDate),
            connectMs: msBetween(txn.connectStartDate, txn.connectEndDate),
            tlsMs: msBetween(txn.secureConnectionStartDate, txn.secureConnectionEndDate),
            ttfbMs: msBetween(txn.requestEndDate, txn.responseStartDate),
            responseMs: msBetween(txn.responseStartDate, txn.responseEndDate)
        )
    }

    private static func msBetween(_ start: Date?, _ end: Date?) -> Int {
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

    private static let swizzleLock: UnsafeMutablePointer<os_unfair_lock> = {
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
