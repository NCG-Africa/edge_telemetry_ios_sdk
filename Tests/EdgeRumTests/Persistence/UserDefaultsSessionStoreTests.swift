// Tests/EdgeRumTests/Persistence/UserDefaultsSessionStoreTests.swift
//
// Cross-instance load, sequence persistence, idle rotation across
// a simulated process restart. Issue #43 acceptance covers the
// 3-ACK sequence increment via the in-memory store; this file proves
// the persisted store behaves identically.

import XCTest
@testable import EdgeRumCore

final class UserDefaultsSessionStoreTests: XCTestCase {

    func testLoadReturnsNilWhenEmpty() {
        let defaults = InMemoryUserDefaultsStore()
        let store = UserDefaultsSessionStore(defaults: defaults)
        XCTAssertNil(store.load())
    }

    func testSaveThenLoadRoundTrips() {
        let defaults = InMemoryUserDefaultsStore()
        let store = UserDefaultsSessionStore(defaults: defaults)
        let state = SessionState(
            id: "session_1717234876123_a1b2c3d4e5f60718_ios",
            startTime: Date(timeIntervalSince1970: 1_717_234_876.123),
            sequence: 7,
            lastActiveAt: Date(timeIntervalSince1970: 1_717_235_000.456)
        )
        store.save(state)
        let loaded = store.load()
        XCTAssertEqual(loaded, state)
    }

    func testStateSurvivesAcrossStoreInstances() {
        // Simulates a "process restart" — both store instances point at
        // the same underlying defaults wrapper.
        let defaults = InMemoryUserDefaultsStore()
        let state = SessionState(
            id: "session_1717234876123_a1b2c3d4e5f60718_ios",
            startTime: Date(timeIntervalSince1970: 1_717_234_876.123),
            sequence: 2,
            lastActiveAt: Date(timeIntervalSince1970: 1_717_234_876.123)
        )
        UserDefaultsSessionStore(defaults: defaults).save(state)

        let loaded = UserDefaultsSessionStore(defaults: defaults).load()
        XCTAssertEqual(loaded, state)
    }

    func testCorruptBlobYieldsNilAndClearsStorage() {
        let defaults = InMemoryUserDefaultsStore()
        defaults.set("not valid json".data(using: .utf8)!,
                     forKey: EdgeRumStorage.keySessionState)
        let store = UserDefaultsSessionStore(defaults: defaults)

        XCTAssertNil(store.load())
        XCTAssertNil(defaults.data(forKey: EdgeRumStorage.keySessionState))
    }

    // MARK: SessionManager-level behaviour against the persisted store

    func testSessionManagerReusesPersistedStateWithinIdleWindow() {
        let defaults = InMemoryUserDefaultsStore()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.123))
        let store = UserDefaultsSessionStore(defaults: defaults)
        let manager = SessionManager(
            store: store,
            clock: clock,
            randomBytes: { Data([0xa1, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6, 0x07, 0x18]) }
        )

        let first = manager.touch().state
        XCTAssertEqual(first.sequence, 0)

        // Advance 10 minutes (still under 30-min idle threshold).
        clock.advance(by: 10 * 60)

        // Recreate the manager pointing at the same persisted store —
        // simulates a process restart well within the idle window.
        let revived = SessionManager(
            store: UserDefaultsSessionStore(defaults: defaults),
            clock: clock,
            randomBytes: { Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]) }
        )
        let resumed = revived.touch()
        XCTAssertFalse(resumed.rotated)
        XCTAssertEqual(resumed.state.id, first.id)
        XCTAssertEqual(resumed.state.sequence, 0)
    }

    func testSessionManagerRotatesAfterIdleThresholdAcrossRestart() {
        let defaults = InMemoryUserDefaultsStore()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.123))
        let store = UserDefaultsSessionStore(defaults: defaults)
        let manager = SessionManager(
            store: store,
            clock: clock,
            randomBytes: { Data([0xa1, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6, 0x07, 0x18]) }
        )
        let original = manager.touch().state

        // Push past the 30-min idle threshold.
        clock.advance(by: SessionManager.idleRotationInterval + 1)

        let revived = SessionManager(
            store: UserDefaultsSessionStore(defaults: defaults),
            clock: clock,
            randomBytes: { Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]) }
        )
        let rotated = revived.touch()
        XCTAssertTrue(rotated.rotated)
        XCTAssertNotEqual(rotated.state.id, original.id)
        XCTAssertEqual(rotated.state.sequence, 0)
    }

    func testSequenceIncrementPersists() {
        let defaults = InMemoryUserDefaultsStore()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.123))
        let manager = SessionManager(
            store: UserDefaultsSessionStore(defaults: defaults),
            clock: clock,
            randomBytes: { Data([0xa1, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6, 0x07, 0x18]) }
        )
        _ = manager.touch()
        manager.incrementSequence()
        manager.incrementSequence()
        manager.incrementSequence()

        // Re-open via a fresh store + manager.
        let revived = SessionManager(
            store: UserDefaultsSessionStore(defaults: defaults),
            clock: clock
        )
        XCTAssertEqual(revived.currentState()?.sequence, 3)
    }
}
