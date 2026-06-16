// Tests/EdgeRumTests/Transport/MockURLProtocol.swift
//
// `URLProtocol` subclass that intercepts requests on the URLSession we
// inject into `BatchTransport` so transport tests can drive HTTP
// responses without spinning up a real server. Each test installs a
// `responder` closure; the closure receives the request and returns the
// `(status, body, headers)` triple to send back.
//
// Pattern adapted from Apple's `Foundation` URLSession test helpers:
// register the class on `URLSessionConfiguration.protocolClasses` *as
// the first entry* so it wins over the default protocol implementations.
//
// Refs: PLAN-iOS.md §F5/T5.1; CLAUDE.md "Testing conventions".
//

import Foundation
import XCTest

final class MockURLProtocol: URLProtocol {

    /// Test-injected response handler. The closure runs synchronously
    /// inside `startLoading`; the caller is free to capture state from
    /// the incoming request to drive assertions.
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> (Int, Data?, [String: String])) = { _ in
        (200, nil, [:])
    }

    /// Records every request the protocol intercepts so tests can
    /// inspect headers / body without threading through the responder.
    private static let recordedLock = NSLock()
    nonisolated(unsafe) private static var _recorded: [URLRequest] = []

    static var recorded: [URLRequest] {
        recordedLock.lock(); defer { recordedLock.unlock() }
        return _recorded
    }

    static func reset() {
        recordedLock.lock()
        _recorded.removeAll()
        recordedLock.unlock()
        responder = { _ in (200, nil, [:]) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recordedLock.lock()
        Self._recorded.append(self.request)
        Self.recordedLock.unlock()

        let (status, body, headers) = Self.responder(self.request)
        let url = request.url ?? URL(string: "https://invalid.test/")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// Configure a `URLSession` so it routes every request through
    /// `MockURLProtocol`.
    static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    /// Pull the request body — `URLProtocol` strips the original
    /// `httpBody` when it streams via `HTTPBodyStream`. Tests use this
    /// to compare the encoded envelope verbatim.
    static func requestBody(_ req: URLRequest) -> Data? {
        if let body = req.httpBody { return body }
        guard let stream = req.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let chunkSize = 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: chunkSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
