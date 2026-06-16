// Sources/EdgeRumCore/Transport/BackgroundUploader.swift
//
// Background-`URLSession` companion to `BatchTransport`. Drains
// pending uploads after the host app is suspended, so a payload that
// was mid-flight when the user hit the home button still reaches the
// backend the next time iOS gives the SDK CPU.
//
// Wiring:
//
//   1. Host app forwards
//      `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
//      → `EdgeRum.handleBackgroundEvents(identifier:completion:)`.
//   2. `handleBackgroundEvents` calls `attachCompletion(_:for:)` here.
//   3. Once the backing `URLSession` finishes its pending tasks the
//      delegate fires `urlSessionDidFinishEvents` which invokes the
//      stored completion and clears it.
//
// We deliberately keep the foreground `BatchTransport` and the
// background uploader as separate sessions — the background
// configuration's body-from-file constraint makes it a poor fit for
// the live retry path, and using two sessions keeps the live happy
// path single-task-per-batch (CLAUDE.md "Transport rules").
//
// Refs: PLAN-iOS.md §9.5, §F5/T5.4; CLAUDE.md "Transport rules"
//       ("background flush" paragraph).
//

import Foundation
import os.log

public protocol BackgroundUploading: AnyObject, Sendable {
    /// Identifier the host app must forward into
    /// `EdgeRum.handleBackgroundEvents(identifier:completion:)`.
    var sessionIdentifier: String { get }

    /// Enqueue a payload for background upload. The body is written
    /// to a temp file because `URLSessionConfiguration.background`
    /// requires `uploadTask(with:fromFile:)`.
    @discardableResult
    func enqueue(_ payload: Data, url: URL, apiKey: String, userAgent: String) -> Bool

    /// Store the system-supplied completion. Called from
    /// `EdgeRum.handleBackgroundEvents`. The closure runs once the
    /// session reports `urlSessionDidFinishEvents`.
    func attachCompletion(_ completion: @escaping @Sendable () -> Void, for identifier: String)
}

public final class BackgroundUploader: NSObject, BackgroundUploading, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {

    /// Background session identifier shared across iOS launches.
    /// PLAN-iOS.md §9.5 pins this string.
    public static let defaultSessionIdentifier = "com.edge.rum.upload"

    public let sessionIdentifier: String

    private let log: OSLog
    private let debug: Bool
    private let lock = NSLock()
    private var _completion: (@Sendable () -> Void)?
    private let fileManager: FileManager
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    public init(
        sessionIdentifier: String = BackgroundUploader.defaultSessionIdentifier,
        fileManager: FileManager = .default,
        debug: Bool = false,
        log: OSLog = OSLog(subsystem: "com.edge.rum", category: "BackgroundUploader")
    ) {
        self.sessionIdentifier = sessionIdentifier
        self.fileManager = fileManager
        self.debug = debug
        self.log = log
        super.init()
    }

    @discardableResult
    public func enqueue(_ payload: Data, url: URL, apiKey: String, userAgent: String) -> Bool {
        // Background uploads need the body on disk. Write to the
        // temporary directory under a UUID-keyed name.
        let tmpURL = fileManager.temporaryDirectory
            .appendingPathComponent("edge-rum-\(UUID().uuidString).json", isDirectory: false)
        do {
            try payload.write(to: tmpURL, options: .atomic)
        } catch {
            if debug {
                os_log(
                    "BackgroundUploader temp write failed: %{public}@",
                    log: log,
                    type: .info,
                    String(describing: error)
                )
            }
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: BatchTransport.internalHeaderName)

        let task = session.uploadTask(with: request, fromFile: tmpURL)
        task.taskDescription = BatchTransport.internalTaskDescription
        task.resume()
        return true
    }

    public func attachCompletion(
        _ completion: @escaping @Sendable () -> Void,
        for identifier: String
    ) {
        guard identifier == sessionIdentifier else {
            // The host forwarded a different background session — not
            // ours. Invoke the completion anyway so the system gets its
            // ack; ignoring it would leave the app spinning.
            DispatchQueue.main.async(execute: completion)
            return
        }
        lock.lock()
        _completion = completion
        lock.unlock()
    }

    // MARK: URLSessionDelegate

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let completion = _completion
        _completion = nil
        lock.unlock()
        guard let completion else { return }
        DispatchQueue.main.async(execute: completion)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // No retry inside the background uploader — if the task failed
        // the payload will replay from the offline queue on next
        // foreground.
        if let error, debug {
            os_log(
                "BackgroundUploader task failed: %{public}@",
                log: log,
                type: .info,
                String(describing: error)
            )
        }
    }
}
