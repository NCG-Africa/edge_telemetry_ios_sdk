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

    // MARK: T5.5 acceptance — statistical distribution

    /// PLAN-iOS.md §F5/T5.5 acceptance:
    /// "sampleRate = 0.5 over 10k synthetic sessions yields 5000 ± 200."
    /// We feed a seeded LCG instead of `SecRandomCopyBytes` so the test
    /// is deterministic — the production path uses real entropy via
    /// `Sampler.secureUniformDouble`.
    func test10kSessionsAt50PercentHits5000Plus200() {
        var seed: UInt64 = 0xCAFEBABE_DEADBEEF
        var included = 0
        for _ in 0..<10_000 {
            // 64-bit LCG (Numerical Recipes constants).
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            // Top 53 bits → [0, 1) double, same approach as the
            // production `Sampler.secureUniformDouble`.
            let mantissa = seed >> 11
            let u = Double(mantissa) * (1.0 / Double(1 << 53))
            let s = Sampler(sampleRate: 0.5, entropy: { u })
            if s.included { included += 1 }
        }
        XCTAssertGreaterThanOrEqual(included, 4_800)
        XCTAssertLessThanOrEqual(included, 5_200)
    }

    /// At `sampleRate = 0` every session is excluded — but the forced
    /// allowlist still emits. The combined check pins both halves of
    /// the T5.5 contract in one place.
    func testExcludedSessionsStillEmitForcedAllowlist() {
        let s = Sampler(sampleRate: 0.0)
        XCTAssertFalse(s.included)
        for name in Sampler.forcedEmitAllowlist {
            XCTAssertTrue(s.shouldEmit(eventName: name),
                          "\(name) should bypass the sampler")
        }
    }
}
