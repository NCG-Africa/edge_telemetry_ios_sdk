// Sources/EdgeRumCore/Transport/HTTPTransportSink.swift
//
// The `TransportSink` the production `Recorder` uses once
// `EdgeRum.start(_:)` has run. Glues `BatchTransport` + `RetryPolicy`
// + `OfflineQueue` + `BackgroundUploader` together:
//
//   send(envelope) → encode → BatchTransport.post
//     ↳ success → ack the Recorder, drain any leftover offline files
//     ↳ failure → RetryPolicy.decide
//        ↳ .retry(after:) → asyncAfter, attempt N+1
//        ↳ .toOfflineQueue → write payload to OfflineQueue
//        ↳ .drop          → log + discard
//
// Drains the offline queue on three triggers (CLAUDE.md "Offline
// queue rules"):
//
//   1. `EdgeRum.enable()`                    — explicit host wake-up
//   2. `NWPathMonitor` transitions to .satisfied
//   3. F11's `didBecomeActive` (wired later — `drainOfflineQueue()`
//      is the public entry point)
//
// The sink keeps a `weak` reference back to the `Recorder` so it can
// call `didAckBatch()` on 2xx without retaining the singleton in a
// cycle (the Recorder owns the sink via `installTransport`).
//
// Refs: PLAN-iOS.md §9, §F5/T5.1–T5.4; CLAUDE.md "Transport rules"
//       + "Offline queue rules".
//

import Foundation
import Network
import os.log

public final class HTTPTransportSink: TransportSink, @unchecked Sendable {

    private let transport: BatchSending
    private let retryPolicy: RetryPolicy
    private let offlineQueue: OfflineQueueing?
    private let backgroundUploader: BackgroundUploading?
    private let queue: DispatchQueue
    private let apiKey: String
    private let userAgent: String
    private let log: OSLog
    private let debug: Bool

    private weak var recorder: Recorder?

    // Network drain trigger
    private let pathObserver: NetworkPathObserver?
    private let pathObserverLock = NSLock()
    private var lastPathSatisfied: Bool = false

    public init(
        transport: BatchSending,
        retryPolicy: RetryPolicy = RetryPolicy(),
        offlineQueue: OfflineQueueing? = OfflineQueue(),
        backgroundUploader: BackgroundUploading? = nil,
        apiKey: String,
        userAgent: String,
        debug: Bool = false,
        queue: DispatchQueue = DispatchQueue(label: "edge.rum.transport", qos: .utility),
        pathObserver: NetworkPathObserver? = NetworkPathObserver(),
        log: OSLog = OSLog(subsystem: "com.edge.rum", category: "HTTPTransportSink")
    ) {
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.offlineQueue = offlineQueue
        self.backgroundUploader = backgroundUploader
        self.apiKey = apiKey
        self.userAgent = userAgent
        self.debug = debug
        self.queue = queue
        self.pathObserver = pathObserver
        self.log = log
    }

    /// Late-bind the recorder so `didAckBatch` can fire on 2xx.
    public func attach(recorder: Recorder) {
        self.recorder = recorder
        // Start watching for `.satisfied` transitions once the sink is
        // fully wired. Pre-attach observation would race with a
        // recorder-less drain attempt.
        startPathObserver()
    }

    // MARK: TransportSink

    public func send(_ envelope: EventEnvelope, reason: FlushReason) {
        queue.async { [weak self] in
            self?.encodeAndSend(envelope: envelope, reason: reason)
        }
    }

    public func drainOfflineQueue() {
        queue.async { [weak self] in
            self?.drainNow()
        }
    }

    // MARK: Internals

    private func encodeAndSend(envelope: EventEnvelope, reason: FlushReason) {
        let data: Data
        do {
            data = try Self.encoder.encode(envelope)
        } catch {
            if debug {
                os_log(
                    "HTTPTransportSink encode failed: %{public}@",
                    log: log,
                    type: .info,
                    String(describing: error)
                )
            }
            return
        }
        attempt(data: data, attempt: 1)
    }

    private func attempt(data: Data, attempt: Int) {
        transport.post(data) { [weak self] outcome in
            guard let self else { return }
            self.queue.async {
                self.handle(outcome: outcome, data: data, attempt: attempt)
            }
        }
    }

    private func handle(outcome: BatchSendOutcome, data: Data, attempt: Int) {
        switch outcome {
        case .success:
            recorder?.didAckBatch()
            // Opportunistic drain — a successful live send is a strong
            // signal that the offline queue can move too.
            drainNow()
        case let .failure(status, retryAfter):
            let decision = retryPolicy.decide(
                attempt: attempt,
                status: status,
                retryAfter: retryAfter
            )
            switch decision {
            case let .retry(after):
                queue.asyncAfter(deadline: .now() + after) { [weak self] in
                    self?.attempt(data: data, attempt: attempt + 1)
                }
            case .toOfflineQueue:
                if let offlineQueue {
                    _ = offlineQueue.enqueue(data)
                    if debug {
                        os_log(
                            "HTTPTransportSink batch handed to offline queue after %d attempts",
                            log: log,
                            type: .info,
                            attempt
                        )
                    }
                } else if debug {
                    os_log(
                        "HTTPTransportSink dropped batch — offline queue unavailable",
                        log: log,
                        type: .info
                    )
                }
            case .drop:
                if debug {
                    os_log(
                        "HTTPTransportSink dropped batch — status %d non-retryable",
                        log: log,
                        type: .info,
                        status
                    )
                }
            }
        }
    }

    private func drainNow() {
        guard let offlineQueue else { return }
        _ = offlineQueue.drain { [weak self] payload in
            guard let self else { return false }
            // Block until the per-file POST resolves so the next file
            // doesn't fire concurrently — the drain has to be
            // sequential per spec. Sendable container is the Swift 6
            // / strict-concurrency-safe alternative to a captured
            // `var` mutated from inside the post callback.
            let semaphore = DispatchSemaphore(value: 0)
            let outcomeBox = OutcomeBox()
            self.transport.post(payload) { outcome in
                if case .success = outcome { outcomeBox.markSuccess() }
                semaphore.signal()
            }
            semaphore.wait()
            let ok = outcomeBox.isSuccess
            if ok { self.recorder?.didAckBatch() }
            return ok
        }
    }

    /// Sendable box for the success flag shared between the drain
    /// callback and the post completion handler. Swift 6 strict
    /// concurrency rejects mutating a captured `var` from inside the
    /// completion closure even when a `DispatchSemaphore` is forcing
    /// the writes to happen-before the reads.
    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _success = false

        func markSuccess() {
            lock.lock(); _success = true; lock.unlock()
        }

        var isSuccess: Bool {
            lock.lock(); defer { lock.unlock() }
            return _success
        }
    }

    private func startPathObserver() {
        guard let pathObserver else { return }
        pathObserver.start { [weak self] context, _ in
            guard let self else { return }
            let satisfied = context.type != .none
            self.pathObserverLock.lock()
            let wasSatisfied = self.lastPathSatisfied
            self.lastPathSatisfied = satisfied
            self.pathObserverLock.unlock()
            if satisfied && !wasSatisfied {
                self.drainOfflineQueue()
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []
        return e
    }()
}
