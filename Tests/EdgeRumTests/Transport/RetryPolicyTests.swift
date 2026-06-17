// Tests/EdgeRumTests/Transport/RetryPolicyTests.swift
//
// Covers PLAN-iOS.md §9.3 / §F5/T5.2 truth table:
//
//   - Schedule 0 / 2 / 8 / 30s for status 0 / 429 / 503.
//   - 5xx other than 503 → treat as 503.
//   - Non-retryable 4xx (other than 429) → .drop.
//   - Retry-After overrides the schedule; cap at 60s.
//   - After the last schedule slot, the policy returns .toOfflineQueue.
//

import XCTest
@testable import EdgeRumCore

final class RetryPolicyTests: XCTestCase {

    func testDefaultScheduleMatchesSpec() {
        XCTAssertEqual(RetryPolicy.defaultSchedule, [0, 2, 8, 30])
        XCTAssertEqual(RetryPolicy.retryAfterCap, 60)
    }

    func testStatus0FollowsSchedule() {
        let policy = RetryPolicy()
        XCTAssertEqual(policy.decide(attempt: 1, status: 0), .retry(after: 2))
        XCTAssertEqual(policy.decide(attempt: 2, status: 0), .retry(after: 8))
        XCTAssertEqual(policy.decide(attempt: 3, status: 0), .retry(after: 30))
        XCTAssertEqual(policy.decide(attempt: 4, status: 0), .toOfflineQueue)
    }

    func testStatus503FollowsSchedule() {
        let policy = RetryPolicy()
        XCTAssertEqual(policy.decide(attempt: 1, status: 503), .retry(after: 2))
        XCTAssertEqual(policy.decide(attempt: 4, status: 503), .toOfflineQueue)
    }

    func testStatus429FollowsSchedule() {
        let policy = RetryPolicy()
        XCTAssertEqual(policy.decide(attempt: 1, status: 429), .retry(after: 2))
        XCTAssertEqual(policy.decide(attempt: 4, status: 429), .toOfflineQueue)
    }

    func test5xxOtherThan503IsTreatedAs503() {
        let policy = RetryPolicy()
        for status in [500, 502, 504, 599] {
            XCTAssertEqual(
                policy.decide(attempt: 1, status: status),
                .retry(after: 2),
                "status \(status) should be treated as 503"
            )
        }
    }

    func testNonRetryable4xxDrops() {
        let policy = RetryPolicy()
        for status in [400, 401, 403, 404, 418, 422] {
            XCTAssertEqual(
                policy.decide(attempt: 1, status: status),
                .drop,
                "status \(status) should be dropped"
            )
        }
    }

    func testRetryAfterOverridesSchedule() {
        let policy = RetryPolicy()
        XCTAssertEqual(
            policy.decide(attempt: 1, status: 429, retryAfter: 15),
            .retry(after: 15)
        )
    }

    func testRetryAfterCapsAt60Seconds() {
        let policy = RetryPolicy()
        XCTAssertEqual(
            policy.decide(attempt: 1, status: 503, retryAfter: 90),
            .retry(after: 60)
        )
    }

    func testRetryAfterNumericParse() {
        XCTAssertEqual(RetryPolicy.parseRetryAfter("15"), 15)
        XCTAssertEqual(RetryPolicy.parseRetryAfter("  42 "), 42)
        XCTAssertEqual(RetryPolicy.parseRetryAfter("0"), 0)
        XCTAssertEqual(RetryPolicy.parseRetryAfter(nil), nil)
        XCTAssertEqual(RetryPolicy.parseRetryAfter(""), nil)
        XCTAssertEqual(RetryPolicy.parseRetryAfter("garbage"), nil)
    }

    func testRetryAfterHttpDateParse() throws {
        let now = Date(timeIntervalSince1970: 1_717_000_000)
        // 30 seconds after `now` in RFC 1123 form.
        let future = now.addingTimeInterval(30)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let header = f.string(from: future)
        let parsed = try XCTUnwrap(RetryPolicy.parseRetryAfter(header, now: now))
        XCTAssertEqual(parsed, 30, accuracy: 1)
    }

    func testNegativeRetryAfterClampsToZero() {
        let policy = RetryPolicy()
        XCTAssertEqual(
            policy.decide(attempt: 1, status: 429, retryAfter: -5),
            .retry(after: 0)
        )
    }

    /// T5.2 acceptance — "Mock server returning 503 yields four
    /// attempts then offline-queue." Re-asserts the full sequence at
    /// the policy level.
    func testFourAttemptsThenOfflineQueueAcceptance() {
        let policy = RetryPolicy()
        XCTAssertEqual(policy.decide(attempt: 1, status: 503), .retry(after: 2))
        XCTAssertEqual(policy.decide(attempt: 2, status: 503), .retry(after: 8))
        XCTAssertEqual(policy.decide(attempt: 3, status: 503), .retry(after: 30))
        XCTAssertEqual(policy.decide(attempt: 4, status: 503), .toOfflineQueue)
    }
}
