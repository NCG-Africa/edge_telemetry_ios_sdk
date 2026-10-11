// Tests/EdgeRumContractTests/LocalHTTPStub.swift
//
// #252: a real HTTP server on 127.0.0.1 that answers each POST from a
// script of statuses, so the failed-send tests exercise the production
// URLSession path (sockets, headers, connection drops) rather than a
// URLProtocol. `nil` in the script closes the connection without a
// response — a network error, status 0 to the SDK. Past the end of the
// script every request gets `fallback`.

import Foundation
import Network

final class LocalHTTPStub: @unchecked Sendable {

    struct Reply {
        var status: Int?
        var headers: [String: String] = [:]
        static func status(_ s: Int, _ headers: [String: String] = [:]) -> Reply { Reply(status: s, headers: headers) }
        static let networkError = Reply(status: nil)
    }

    struct Request {
        let path: String
        let headers: [String: String]
        let body: Data
        let receivedAt: Date
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "local-http-stub")
    private let lock = NSLock()
    private var script: [Reply] = []
    private var _requests: [Request] = []
    var fallback = Reply.status(200)

    /// Base URL of the running server, e.g. `http://127.0.0.1:53211`.
    private(set) var baseURL = URL(fileURLWithPath: "/")

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] in self?.serve($0) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else {
            throw URLError(.cannotConnectToHost)
        }
        baseURL = URL(string: "http://127.0.0.1:\(port.rawValue)")!  // port is set once ready
    }

    deinit { listener.cancel() }

    /// Replies for the next requests, in order.
    func script(_ replies: Reply...) {
        lock.lock(); script.append(contentsOf: replies); lock.unlock()
    }

    var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    @discardableResult
    func waitForRequests(_ count: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while requests.count < count, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        return requests.count >= count
    }

    // MARK: HTTP/1.1, one request per connection

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.respond(to: request, on: connection)
            } else if done || error != nil {
                connection.cancel()
            } else {
                self.read(connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: Request, on connection: NWConnection) {
        lock.lock()
        _requests.append(request)
        let reply = script.isEmpty ? fallback : script.removeFirst()
        lock.unlock()
        guard let status = reply.status else {
            connection.cancel()
            return
        }
        var head = "HTTP/1.1 \(status) Stub\r\nContent-Length: 0\r\nConnection: close\r\n"
        for (k, v) in reply.headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    /// A complete request (headers + Content-Length body), or nil if
    /// more bytes are needed.
    private static func parse(_ buffer: Data) -> Request? {
        guard let split = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[..<split.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let path = lines.removeFirst().split(separator: " ").dropFirst().first.map(String.init) ?? ""
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buffer[split.upperBound...]
        guard body.count >= length else { return nil }
        return Request(path: path, headers: headers, body: Data(body.prefix(length)), receivedAt: Date())
    }
}
