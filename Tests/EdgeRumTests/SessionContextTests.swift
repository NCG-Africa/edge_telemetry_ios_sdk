import XCTest
@testable import EdgeRum
import EdgeRumCore

/// Unit tests for `SessionManager` + `SessionState`.
///
/// Refs: CLAUDE.md "Session and ID rules", §F3/T3.3.
final class SessionContextTests: XCTestCase {

    // MARK: ID format

    func testSessionIdHasCorrectShape() {
        let epochMs: Int64 = 1_717_234_870_002
        let bytes = Data([0xff, 0x00, 0x99, 0x88, 0xaa, 0xbb, 0xcc, 0xdd])
        let id = SessionManager.formatSessionId(epochMs: epochMs, random: bytes)
        XCTAssertEqual(id, "session_1717234870002_ff009988aabbccdd_ios")
    }

    func testSessionIdHexIsExactly16Chars() {
        let id = SessionManager.formatSessionId(epochMs: 1, random: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]))
        let hex = id
            .replacingOccurrences(of: "session_1_", with: "")
            .replacingOccurrences(of: "_ios", with: "")
        XCTAssertEqual(hex.count, 16, "Hex section must be 16 chars — 8 bytes × 2 hex per byte")
    }

    func testIdFormatMatchesRegex() {
        let id = SessionManager.formatSessionId(epochMs: 1234, random: Data([0xab, 0xcd, 0xef, 0x12, 0x34, 0x56, 0x78, 0x9a]))
        let pattern = #"^session_\d+_[0-9a-f]{16}_ios$"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: id.utf16.count)
        XCTAssertNotNil(regex?.firstMatch(in: id, options: [], range: range))
    }

    func testDeviceIdHasCorrectShape() {
        let id = DeviceIdentitySnapshot.newId(
            at: Date(timeIntervalSince1970: 1_717_234_876.123),
            randomBytes: { Data([0xa1, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6, 0x07, 0x18]) }
        )
        XCTAssertEqual(id, "device_1717234876123_a1b2c3d4e5f60718_ios")
    }

    func testUserIdHasNoIosSuffix() {
        let id = UserContextSnapshot.newAnonymousId(
            at: Date(timeIntervalSince1970: 1_717_100_000.000),
            randomBytes: { Data([0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe, 0xf0, 0x0d]) }
        )
        XCTAssertEqual(id, "user_1717100000000_deadbeefcafef00d")
        XCTAssertFalse(id.hasSuffix("_ios"))
    }

    // MARK: Lifecycle

    func testTouchCreatesSessionOnFirstCall() {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_000_000))
        let m = SessionManager(
            store: InMemorySessionStore(),
            clock: clock,
            randomBytes: { Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]) }
        )
        let (state, rotated) = m.touch()
        XCTAssertTrue(rotated)
        XCTAssertEqual(state.sequence, 0)
        XCTAssertEqual(state.startTime, state.lastActiveAt)
        XCTAssertTrue(state.id.hasPrefix("session_"))
        XCTAssertTrue(state.id.hasSuffix("_ios"))
    }

    func testTouchKeepsSessionWithinIdleWindow() {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_000_000))
        let m = SessionManager(store: InMemorySessionStore(), clock: clock)
        let first = m.touch()
        clock.advance(by: 29 * 60) // 29 minutes — below idle threshold
        let second = m.touch()
        XCTAssertEqual(first.state.id, second.state.id)
        XCTAssertFalse(second.rotated)
        XCTAssertGreaterThan(second.state.lastActiveAt, first.state.lastActiveAt)
    }

    func testTouchRotatesSessionAfter30MinIdle() {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_000_000))
        let m = SessionManager(store: InMemorySessionStore(), clock: clock)
        let first = m.touch()
        clock.advance(by: 31 * 60) // 31 minutes — past idle threshold
        let second = m.touch()
        XCTAssertNotEqual(first.state.id, second.state.id)
        XCTAssertTrue(second.rotated)
    }

    func testIncrementSequence() {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_000_000))
        let m = SessionManager(store: InMemorySessionStore(), clock: clock)
        let initial = m.touch().state
        m.incrementSequence()
        m.incrementSequence()
        let current = m.currentState()
        XCTAssertEqual(current?.sequence, 2)
        XCTAssertEqual(current?.id, initial.id, "Sequence increments must not rotate session")
    }
}
