import XCTest
@testable import EdgeRum
import EdgeRumCore

/// Unit tests for `Sampler`. The single load-bearing rule is the
/// forced-emit allowlist: `session.started`, `session.finalized`,
/// `app.crash`, `network_change` always pass — even with
/// `sampleRate = 0`.
///
/// Refs: PLAN-iOS.md §9.6, §F3/T3.4.
final class SamplerTests: XCTestCase {

    // MARK: sampleRate = 1.0

    func testSampleRateOneIncludesEverything() {
        let s = Sampler(sampleRate: 1.0, entropy: { 0.999 })
        XCTAssertTrue(s.included)
        XCTAssertTrue(s.shouldEmit(eventName: "navigation"))
        XCTAssertTrue(s.shouldEmit(eventName: "http.request"))
    }

    // MARK: sampleRate = 0.0

    func testSampleRateZeroDropsRegularEvents() {
        let s = Sampler(sampleRate: 0.0, entropy: { 0.0 })
        XCTAssertFalse(s.included)
        XCTAssertFalse(s.shouldEmit(eventName: "navigation"))
        XCTAssertFalse(s.shouldEmit(eventName: "http.request"))
        XCTAssertFalse(s.shouldEmit(eventName: "user.interaction"))
    }

    func testSampleRateZeroStillEmitsForcedEvents() {
        let s = Sampler(sampleRate: 0.0, entropy: { 0.0 })
        XCTAssertTrue(s.shouldEmit(eventName: "session.started"),
                      "session.started must bypass the sampler")
        XCTAssertTrue(s.shouldEmit(eventName: "session.finalized"),
                      "session.finalized must bypass the sampler")
        XCTAssertTrue(s.shouldEmit(eventName: "app.crash"),
                      "app.crash must bypass the sampler")
        XCTAssertTrue(s.shouldEmit(eventName: "network_change"),
                      "network_change must bypass the sampler")
    }

    // MARK: deterministic entropy

    func testEntropyBelowRateIncludes() {
        let s = Sampler(sampleRate: 0.5, entropy: { 0.49 })
        XCTAssertTrue(s.included)
    }

    func testEntropyAtOrAboveRateExcludes() {
        let s = Sampler(sampleRate: 0.5, entropy: { 0.50 })
        XCTAssertFalse(s.included)
        let t = Sampler(sampleRate: 0.5, entropy: { 0.999 })
        XCTAssertFalse(t.included)
    }

    // MARK: out-of-range rates are clamped

    func testNegativeRateClampedToZero() {
        let s = Sampler(sampleRate: -1.0, entropy: { 0.0 })
        XCTAssertFalse(s.included)
        XCTAssertTrue(s.shouldEmit(eventName: "app.crash"))
    }

    func testRateAboveOneClampedToOne() {
        let s = Sampler(sampleRate: 2.0, entropy: { 0.999 })
        XCTAssertTrue(s.included)
    }

    // MARK: forced-emit allowlist exact match

    func testForcedEmitAllowlistContents() {
        XCTAssertEqual(
            Sampler.forcedEmitAllowlist,
            ["session.started", "session.finalized", "app.crash", "network_change"]
        )
    }

    // MARK: secure uniform double

    func testSecureUniformDoubleInRange() {
        // 200 samples is plenty for a sanity check — we only care
        // that values stay in [0, 1).
        for _ in 0..<200 {
            let v = Sampler.secureUniformDouble()
            XCTAssertGreaterThanOrEqual(v, 0.0)
            XCTAssertLessThan(v, 1.0)
        }
    }
}
