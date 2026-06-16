// Sources/EdgeRumCore/TransportSink.swift
//
// Internal seam between the F3 Recorder and the F4 transport layer.
// F3 ships `NoopTransportSink` (drops envelopes silently) so the
// Recorder is testable end-to-end via a `RecordingTransportSink` in
// the contract tests. F4 replaces the default with `HTTPTransportSink`
// that POSTs the encoded JSON to `<endpoint>/collector/telemetry`.
//
// Refs: PLAN-iOS.md §F3 (pipeline), §F4 (transport).
//

import Foundation

public enum FlushReason: String, Sendable {
    case batchSize        // buffer reached `config.batchSize`
    case timer            // `config.flushInterval` elapsed
    case immediate        // error or `session.finalized`
    case shutdown         // Recorder.stop() / shutdown()
    case manual           // host called a flush hook
}

public protocol TransportSink: Sendable {
    func send(_ envelope: EventEnvelope, reason: FlushReason)
}

/// Default sink used in F3 — drops payloads. F4 replaces it.
public struct NoopTransportSink: TransportSink, Sendable {
    public init() {}
    public func send(_ envelope: EventEnvelope, reason: FlushReason) {
        // Intentional no-op.
        _ = envelope
        _ = reason
    }
}

/// In-memory sink used by tests. Thread-safe; captures every envelope
/// it would have sent so contract tests can assert wire shape.
public final class RecordingTransportSink: TransportSink, @unchecked Sendable {

    private let lock = NSLock()
    private var _envelopes: [(EventEnvelope, FlushReason)] = []

    public init() {}

    public func send(_ envelope: EventEnvelope, reason: FlushReason) {
        lock.lock(); _envelopes.append((envelope, reason)); lock.unlock()
    }

    public var envelopes: [EventEnvelope] {
        lock.lock(); defer { lock.unlock() }
        return _envelopes.map { $0.0 }
    }

    public var sends: [(envelope: EventEnvelope, reason: FlushReason)] {
        lock.lock(); defer { lock.unlock() }
        return _envelopes
    }

    public func reset() {
        lock.lock(); _envelopes.removeAll(); lock.unlock()
    }
}
