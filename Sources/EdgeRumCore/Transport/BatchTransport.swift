// Sources/EdgeRumCore/Transport/BatchTransport.swift
//
// HTTP driver for a single `EventEnvelope` POST. Owns the `URLSession`
// used by the foreground send path (created up-front, before any
// swizzles install — PLAN-iOS.md §9.2) and produces a structured
// `BatchSendOutcome` that the surrounding `HTTPTransportSink` feeds
// to `RetryPolicy`.
//
// The wire contract is checked here at the point each request is
// built — endpoint path, headers, encoding — so the F4 contract test
// can exercise it without spinning up a full Recorder.
//
// Refs: PLAN-iOS.md §7.1, §9.2, §F5/T5.1; CLAUDE.md "Transport rules".
//

import Foundation
import os.log

public enum BatchSendOutcome: Sendable, Equatable {
    /// 2xx response. The caller should invoke `Recorder.didAckBatch()`.
    case success(status: Int)

    /// Non-2xx response. `status` carries the actual HTTP code; for
    /// network-level failures (`URLError`, transport drop) it is `0`.
    /// `retryAfter` is the parsed `Retry-After` header, when present.
    case failure(status: Int, retryAfter: TimeInterval?)
}

public protocol BatchSending: AnyObject, Sendable {
    /// Build the request, POST it, and resolve with a structured
    /// outcome. The closure is invoked on a background queue owned by
    /// `URLSession`.
    func post(_ payload: Data, completion: @escaping @Sendable (BatchSendOutcome) -> Void)

    /// Endpoint composed at construction time, exposed for tests +
    /// for the offline replay path so a queued payload reaches the
    /// same URL.
    var url: URL { get }
}

public final class BatchTransport: BatchSending, @unchecked Sendable {

    // MARK: Constants

    /// `POST <endpoint>/collector/telemetry` — pinned by §7.1 and
    /// matched across web/Android/iOS SDKs.
    public static let collectorPath = "collector/telemetry"

    /// Header marking our own requests so HTTPCapture (F8) can filter
    /// them out and prevent self-instrumentation.
    public static let internalHeaderName = "X-Edge-Rum-Internal"

    /// `taskDescription` set on every `URLSessionTask` for the same
    /// defence-in-depth reason. Read by F8 once it lands.
    public static let internalTaskDescription = "edge-rum-internal"

    // MARK: Config

    public let url: URL
    public let apiKey: String

    private let session: URLSession
    private let userAgent: String
    private let log: OSLog
    private let debug: Bool

    public init(
        endpoint: URL,
        apiKey: String,
        sdkVersion: String,
        deviceModel: String,
        osVersion: String,
        session: URLSession? = nil,
        debug: Bool = false,
        log: OSLog = OSLog(subsystem: "com.edge.rum", category: "BatchTransport")
    ) {
        self.url = BatchTransport.makeCollectorURL(endpoint: endpoint)
        self.apiKey = apiKey
        self.userAgent = BatchTransport.makeUserAgent(
            sdkVersion: sdkVersion,
            deviceModel: deviceModel,
            osVersion: osVersion
        )
        self.log = log
        self.debug = debug

        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            // Created *before* HTTPCapture's URLProtocol registers so
            // our own traffic never enters the recording path.
            cfg.protocolClasses = cfg.protocolClasses ?? []
            cfg.httpAdditionalHeaders = nil
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: cfg)
        }
    }

    public func post(_ payload: Data, completion: @escaping @Sendable (BatchSendOutcome) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: BatchTransport.internalHeaderName)

        let task = session.dataTask(with: request) { [debug, log] _, response, error in
            if let error {
                if debug {
                    os_log(
                        "BatchTransport network error: %{public}@",
                        log: log,
                        type: .info,
                        String(describing: error)
                    )
                }
                completion(.failure(status: 0, retryAfter: nil))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(status: 0, retryAfter: nil))
                return
            }
            let status = http.statusCode
            if (200...299).contains(status) {
                completion(.success(status: status))
                return
            }
            let retryAfterRaw = http.value(forHTTPHeaderField: "Retry-After")
            let retryAfter = RetryPolicy.parseRetryAfter(retryAfterRaw)
            completion(.failure(status: status, retryAfter: retryAfter))
        }
        task.taskDescription = BatchTransport.internalTaskDescription
        task.resume()
    }

    // MARK: Helpers

    /// Append the `collector/telemetry` path to the host-supplied
    /// endpoint, honoring trailing slashes.
    public static func makeCollectorURL(endpoint: URL) -> URL {
        endpoint.appendingPathComponent(collectorPath)
    }

    public static func makeUserAgent(
        sdkVersion: String,
        deviceModel: String,
        osVersion: String
    ) -> String {
        "EdgeRum-iOS/\(sdkVersion) (\(deviceModel); iOS \(osVersion))"
    }
}
