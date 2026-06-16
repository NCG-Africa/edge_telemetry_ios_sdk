// Sources/EdgeRumCore/Transport/RetryPolicy.swift
//
// Pure-value retry decision for `HTTPTransportSink`. Encodes the
// schedule from CLAUDE.md "Transport rules" and PLAN-iOS.md §9.3:
//
//     Attempt 1: immediate
//     Attempt 2: +2s
//     Attempt 3: +8s
//     Attempt 4: +30s → push to OfflineQueue
//
//     Retry on: status 0 (network error), 429 (respect Retry-After
//     capped at 60s), 503. 5xx other than 503 → treat as 503.
//     Never retry: other 4xx. Drop the batch and log when debug == true.
//
// Stateless — the `HTTPTransportSink` owns the attempt counter and
// asks the policy what to do after each response.
//
// Refs: PLAN-iOS.md §9.3, §F5/T5.2; CLAUDE.md "Transport rules".
//

import Foundation

public enum RetryDecision: Equatable, Sendable {
    /// Wait this many seconds, then retry the batch.
    case retry(after: TimeInterval)

    /// Stop retrying online and hand the encoded payload to the
    /// offline queue for later replay.
    case toOfflineQueue

    /// Drop the batch outright (non-retryable 4xx response).
    case drop
}

public struct RetryPolicy: Sendable, Equatable {

    /// Per-attempt delay schedule (seconds). Attempt N reads index N-1.
    /// After the last entry the policy returns `.toOfflineQueue`.
    public static let defaultSchedule: [TimeInterval] = [0, 2, 8, 30]

    /// Upper bound on a server-supplied `Retry-After` (seconds).
    /// Matches CLAUDE.md "cap at 60s".
    public static let retryAfterCap: TimeInterval = 60

    public let schedule: [TimeInterval]
    public let retryAfterCap: TimeInterval

    public init(
        schedule: [TimeInterval] = RetryPolicy.defaultSchedule,
        retryAfterCap: TimeInterval = RetryPolicy.retryAfterCap
    ) {
        self.schedule = schedule
        self.retryAfterCap = retryAfterCap
    }

    /// Decide what to do after attempt `attempt` (1-indexed) saw
    /// `status` and (optionally) `Retry-After`.
    ///
    /// - Parameters:
    ///   - attempt: 1 for the first response, 2 for the second, etc.
    ///     The policy returns `.toOfflineQueue` once `attempt` reaches
    ///     `schedule.count` (i.e. all retries have been exhausted).
    ///   - status: HTTP status code. Use `0` for network-level failures
    ///     (DNS, TLS, connection reset, timeout).
    ///   - retryAfter: parsed `Retry-After` header, if present. Overrides
    ///     the schedule (still capped at `retryAfterCap`).
    public func decide(
        attempt: Int,
        status: Int,
        retryAfter: TimeInterval? = nil
    ) -> RetryDecision {
        let effectiveStatus = Self.normalize(status: status)

        // 2xx never reaches the policy — `HTTPTransportSink` shortcuts
        // success before calling in. Guard anyway so the truth table
        // is exhaustive.
        if (200...299).contains(effectiveStatus) {
            return .drop
        }

        // Non-retryable 4xx. 429 is the one retryable 4xx.
        if (400...499).contains(effectiveStatus), effectiveStatus != 429 {
            return .drop
        }

        // We've reached / passed the end of the schedule.
        if attempt >= schedule.count {
            return .toOfflineQueue
        }

        // Honour Retry-After when present; otherwise consume the next
        // slot of the static schedule.
        let scheduled = schedule[attempt]
        let delay: TimeInterval
        if let retryAfter {
            delay = min(max(retryAfter, 0), retryAfterCap)
        } else {
            delay = scheduled
        }
        return .retry(after: delay)
    }

    /// Map status codes to the retry-eligible set. `0` and `429` and
    /// `503` pass through; other 5xx are treated as 503; everything
    /// else falls through to the caller for `.drop` / `.retry`
    /// classification by the regular truth table.
    public static func normalize(status: Int) -> Int {
        if status == 0 || status == 429 || status == 503 {
            return status
        }
        if (500...599).contains(status) {
            return 503
        }
        return status
    }

    // MARK: Retry-After parsing

    /// Parse a `Retry-After` header value. Accepts both the numeric
    /// (delta-seconds) and HTTP-date forms per RFC 7231 §7.1.3.
    /// Returns `nil` when the value is absent or unparseable.
    public static func parseRetryAfter(_ raw: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw, !raw.isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(trimmed) {
            return max(0, seconds)
        }
        if let date = httpDateFormatter.date(from: trimmed) {
            return max(0, date.timeIntervalSince(now))
        }
        return nil
    }

    private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()
}
