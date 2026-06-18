// Samples/EdgeRumCrashSampleApp/EdgeRumCrashSampleApp/UITestListener.swift
//
// Minimal in-process HTTP/1.1 listener used by the F19 / T19.5 crash
// UI test (EdgeRumCrashUITests). Active only when the host launches
// the app with `EDGE_RUM_UITEST=1`; in every other run the listener
// is never instantiated and the app behaves exactly as the F14 manual
// QA sample.
//
// Why it exists: an XCUI test cannot reach the SDK's HTTP transport
// from outside the process, and `URLProtocol.registerClass(_:)` does
// NOT intercept requests made through SDK-owned `URLSession`
// instances. Standing up a listener on `127.0.0.1` lets us point the
// sample's `EdgeRumConfig.endpoint` at it, capture the encoded
// batches the SDK *would* have sent, and mirror the replayed
// `app.crash` event's `session.id` into UserDefaults where the UI
// test process can read it via on-screen Text labels.
//
// The listener answers every request with `HTTP/1.1 400 Bad Request`
// so the SDK's `RetryPolicy` shortcuts to `.drop` and never retries.
// That keeps the round-trip well under 1 s — fast enough for an
// XCUI test to be non-flaky.
//
// Refs: PLAN-iOS.md §13.3 (Crash UI test), §F19/T19.5.
//

import Foundation
import Network

/// UserDefaults suite the listener writes into and `CrashHomeScreen`
/// reads from. Suffixed `.uitest` so production reads from the SDK's
/// own UserDefaults suite (`com.edge.rum.session`) are never affected.
enum CrashUITestStorage {
    static let suite = "com.edge.rum.crash.uitest"
    static let replaySessionIdKey = "replay.session.id"
    static let replayCauseKey     = "replay.cause"
    static let replayFatalKey     = "replay.fatal"
    static let replayEventNameKey = "replay.eventName"
    static let crashedSessionIdKey = "crashed.session.id"
    static let listenerPortKey    = "listener.port"

    static func defaults() -> UserDefaults {
        UserDefaults(suiteName: suite) ?? .standard
    }

    /// Wipe UI-test state so a fresh test run can't read stale values
    /// left behind by an earlier run. Called from
    /// `EdgeRumCrashSampleApp.init` on every launch under UITEST mode.
    static func reset() {
        let d = defaults()
        d.removeObject(forKey: replaySessionIdKey)
        d.removeObject(forKey: replayCauseKey)
        d.removeObject(forKey: replayFatalKey)
        d.removeObject(forKey: replayEventNameKey)
        // crashed.session.id is INTENTIONALLY preserved — it carries
        // across the crash → relaunch boundary.
    }
}

final class UITestListener {

    static let shared = UITestListener()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.edge.rum.crash.uitest.listener")

    private init() {}

    /// Bind to a random free port on 127.0.0.1, persist the chosen
    /// port to UserDefaults so the SDK config can read it back, and
    /// start accepting connections. Idempotent — multiple calls in
    /// the same process keep the first listener.
    @discardableResult
    func start() -> NWEndpoint.Port? {
        if let existing = listener?.port { return existing }
        do {
            let l = try NWListener(using: .tcp, on: .any)
            l.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            l.start(queue: queue)
            self.listener = l
            // `NWListener.port` is assigned by the time the listener
            // transitions to `.ready`. Block the calling thread for up
            // to 1 s — acceptable because `start()` runs once during
            // `EdgeRumCrashSampleApp.init`.
            var assignedPort: NWEndpoint.Port?
            for _ in 0..<100 {
                if let p = l.port { assignedPort = p; break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            if let p = assignedPort {
                CrashUITestStorage.defaults()
                    .set(Int(p.rawValue), forKey: CrashUITestStorage.listenerPortKey)
            }
            return assignedPort
        } catch {
            NSLog("UITestListener failed to bind: \(error)")
            return nil
        }
    }

    /// Block until the listener reports an assigned port, up to
    /// `timeout` seconds. Returns the port number on success, nil
    /// on timeout. Used by `EdgeRumCrashSampleApp.init` to know
    /// which port to feed into `EdgeRumConfig.endpoint`.
    func waitForPort(timeout: TimeInterval = 2.0) -> UInt16? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let raw = listener?.port?.rawValue { return raw }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    // MARK: - HTTP/1.1 handling

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receiveLoop(connection: connection, buffer: Data())
    }

    private func receiveLoop(connection: NWConnection, buffer initialBuffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = initialBuffer
            if let data, !data.isEmpty { buffer.append(data) }

            // Look for the end of HTTP headers.
            if let headersEnd = Self.indexOfHeadersTerminator(in: buffer) {
                let headerData = buffer.prefix(headersEnd)
                let bodyStart  = headersEnd + 4
                let headerString = String(data: headerData, encoding: .utf8) ?? ""
                let contentLength = Self.parseContentLength(in: headerString)

                let body: Data
                if let contentLength {
                    let needed = bodyStart + contentLength
                    if buffer.count >= needed {
                        body = buffer.subdata(in: bodyStart..<needed)
                        self.process(body: body)
                        self.reply(connection: connection)
                        return
                    } else {
                        // Need more bytes before we have the full body.
                        self.receiveLoop(connection: connection, buffer: buffer)
                        return
                    }
                } else {
                    body = buffer.suffix(from: bodyStart)
                    self.process(body: body)
                    self.reply(connection: connection)
                    return
                }
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receiveLoop(connection: connection, buffer: buffer)
        }
    }

    private static func indexOfHeadersTerminator(in data: Data) -> Int? {
        let terminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard data.count >= terminator.count else { return nil }
        return data.withUnsafeBytes { raw -> Int? in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0...(bytes.count - terminator.count) {
                if bytes[i] == terminator[0] &&
                   bytes[i + 1] == terminator[1] &&
                   bytes[i + 2] == terminator[2] &&
                   bytes[i + 3] == terminator[3] {
                    return i
                }
            }
            return nil
        }
    }

    private static func parseContentLength(in headers: String) -> Int? {
        for line in headers.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private func reply(connection: NWConnection) {
        // 400 → `RetryPolicy.decide` returns `.drop` (non-retryable
        // 4xx), so the SDK never retries. Keeps the UI-test loop
        // sub-second.
        let response = """
        HTTP/1.1 400 Bad Request\r
        Connection: close\r
        Content-Length: 0\r
        \r

        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func process(body: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
        guard let events = json["events"] as? [[String: Any]] else { return }

        for event in events {
            guard
                let name = event["eventName"] as? String, name == "app.crash",
                let attrs = event["attributes"] as? [String: Any],
                let sessionId = attrs["session.id"] as? String
            else { continue }

            let d = CrashUITestStorage.defaults()
            d.set(sessionId, forKey: CrashUITestStorage.replaySessionIdKey)
            d.set(name, forKey: CrashUITestStorage.replayEventNameKey)
            if let cause = attrs["cause"] as? String {
                d.set(cause, forKey: CrashUITestStorage.replayCauseKey)
            }
            if let fatal = attrs["crash.fatal"] as? Bool {
                d.set(fatal, forKey: CrashUITestStorage.replayFatalKey)
            }
        }
    }
}

/// Convenience: returns true when the app is running under the UI
/// test harness (`EDGE_RUM_UITEST=1`).
func isCrashUITestRun() -> Bool {
    ProcessInfo.processInfo.environment["EDGE_RUM_UITEST"] == "1"
}
