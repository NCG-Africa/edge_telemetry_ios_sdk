// Sources/EdgeRumCore/SdkHealth.swift
//
// F32 — process-scoped SDK health (#219, roadmap tranche 7). Cumulative
// totals since process start, never deltas: any one envelope that
// lands is correct, so nine in ten may be lost without corrupting the
// number. Resets on process death (the queue outlives the process, so
// uploads are not a session's property).
//
// Session-scoped counters (`sdk.events_generated`,
// `sdk.events_dropped.sampled|unknown_name`) live on the Recorder
// beside `sdk.thread_time_ms`.
//
// Wire-only: nothing in the public module reads this.
//
// Refs: docs/catalogue/ios-data-catalogue.md § 2.2; W8 (#196).

import Foundation

public final class SdkHealth: @unchecked Sendable {

    /// The process's counters, shared by the Recorder and the transport.
    public static let shared = SdkHealth()

    /// A process-scoped counter; the raw value is its wire key.
    public enum Counter: String, CaseIterable, Sendable {
        case eventsUploaded = "sdk.events_uploaded"
        case batchesUploaded = "sdk.batches_uploaded"
        case uploadFailures = "sdk.upload_failures"
        case queueOverflow = "sdk.events_dropped.queue_overflow"
        case encodeFailure = "sdk.events_dropped.encode_failure"
        case nonRetryable = "sdk.events_dropped.non_retryable"
        case enqueueFailure = "sdk.events_dropped.enqueue_failure"
        case queueDepthMax = "sdk.queue_depth_max"
        case storageBytesMax = "sdk.storage_bytes_max"

        /// Always on the wire; every other counter is a marker,
        /// omitted when zero.
        var required: Bool {
            switch self {
            case .eventsUploaded, .batchesUploaded, .queueDepthMax, .storageBytesMax: return true
            default: return false
            }
        }
    }

    /// A subsystem that failed to install — blind for the process.
    public enum Capability: String, Sendable {
        case interactionSwizzle = "interaction_swizzle"
        case httpSwizzle = "http_swizzle"
        case crashReporter = "crash_reporter"
        case hangObserver = "hang_observer"
        case offlineQueue = "offline_queue"
        case keychain
    }

    private let lock = NSLock()
    private var counts: [Counter: Int] = [:]
    private var failed: Set<String> = []

    /// A fresh, all-zero set — production uses `shared`.
    public init() {}

    /// Add `n` to a cumulative counter.
    public func add(_ counter: Counter, _ n: Int = 1) {
        lock.lock(); counts[counter, default: 0] += n; lock.unlock()
    }

    /// High-water mark: keeps the larger of the stored and given value.
    public func raise(_ counter: Counter, to value: Int) {
        lock.lock(); counts[counter] = max(counts[counter] ?? 0, value); lock.unlock()
    }

    /// Mark `capability` failed for the rest of the process.
    public func fail(_ capability: Capability) {
        lock.lock(); failed.insert(capability.rawValue); lock.unlock()
    }

    /// Envelope fields: required counters always, markers when > 0,
    /// `sdk.capabilities_failed` (sorted, comma-joined) when any failed.
    public func snapshot() -> [String: AttributeValue] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: AttributeValue] = [:]
        // Omit, never falsify: no queue means its marks were never read.
        let queueBlind = failed.contains(Capability.offlineQueue.rawValue)
        for counter in Counter.allCases {
            if queueBlind && (counter == .queueDepthMax || counter == .storageBytesMax) { continue }
            let n = counts[counter] ?? 0
            if counter.required || n > 0 { out[counter.rawValue] = .int(n) }
        }
        if !failed.isEmpty {
            out["sdk.capabilities_failed"] = .string(failed.sorted().joined(separator: ","))
        }
        return out
    }
}
