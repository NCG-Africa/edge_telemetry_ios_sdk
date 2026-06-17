// Sources/EdgeRumCore/Sampler.swift
//
// Per-session probabilistic filter. PLAN-iOS.md §9.6:
//
//     Per-session uniform random vs `sampleRate`. Excluded sessions
//     emit only `session.started`, `session.finalized`, `app.crash`,
//     and `network_change`.
//
// One coin flip per session. The forced-emit allowlist always passes
// regardless of the flip. F3 issue #39 acceptance:
//
//     `sampleRate = 0` still emits the forced-emit set.
//
// Refs: PLAN-iOS.md §9.6, §F3/T3.4.
//

import Foundation
import Security

public struct Sampler: Sendable {

    /// Wire `eventName` values that bypass the sampling decision.
    public static let forcedEmitAllowlist: Set<String> = [
        "session.started",
        "session.finalized",
        "app.crash",
        "network_change"
    ]

    /// Whether this session is included in the sample. Computed once
    /// at construction time so the decision is stable for the whole
    /// session lifetime.
    public let included: Bool

    public init(sampleRate: Double, entropy: () -> Double = Sampler.secureUniformDouble) {
        let clamped = min(max(sampleRate, 0.0), 1.0)
        if clamped >= 1.0 {
            self.included = true
        } else if clamped <= 0.0 {
            self.included = false
        } else {
            self.included = entropy() < clamped
        }
    }

    /// Returns `true` when the event should be emitted. Forced-emit
    /// names bypass the sampling decision.
    public func shouldEmit(eventName: String) -> Bool {
        if Self.forcedEmitAllowlist.contains(eventName) {
            return true
        }
        return included
    }

    /// Returns `true` when a metric should be emitted. Metrics never
    /// have a forced-emit allowlist — they all follow the per-session
    /// decision.
    public func shouldEmit(metricName: String) -> Bool {
        _ = metricName
        return included
    }

    // MARK: Entropy

    /// `Double` in `[0, 1)` derived from 8 bytes of `SecRandomCopyBytes`
    /// entropy. Used as the default `entropy` source for production.
    public static func secureUniformDouble() -> Double {
        var bytes = [UInt8](repeating: 0, count: 8)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            arc4random_buf(&bytes, bytes.count)
        }
        // Top 53 bits of a 64-bit integer give a uniform Double in
        // [0, 1) without quantisation artefacts.
        let u64 = bytes.withUnsafeBytes { ptr -> UInt64 in
            ptr.load(as: UInt64.self)
        }
        let mantissa = u64 >> 11
        return Double(mantissa) * (1.0 / Double(1 << 53))
    }
}
