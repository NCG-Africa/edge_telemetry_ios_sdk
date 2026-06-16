// Tests/EdgeRumTests/Persistence/UserDefaultsStoreTests.swift

import XCTest
@testable import EdgeRumCore

final class InMemoryUserDefaultsStoreTests: XCTestCase {

    func testStringRoundTrip() {
        let store = InMemoryUserDefaultsStore()
        store.set("hello", forKey: "k")
        XCTAssertEqual(store.string(forKey: "k"), "hello")
    }

    func testDataRoundTrip() {
        let store = InMemoryUserDefaultsStore()
        let data = Data([0x01, 0x02, 0x03])
        store.set(data, forKey: "k")
        XCTAssertEqual(store.data(forKey: "k"), data)
    }

    func testRemoveObjectClearsValue() {
        let store = InMemoryUserDefaultsStore()
        store.set("x", forKey: "k")
        store.removeObject(forKey: "k")
        XCTAssertNil(store.string(forKey: "k"))
        XCTAssertNil(store.data(forKey: "k"))
    }

    func testMissingKeyReturnsNil() {
        let store = InMemoryUserDefaultsStore()
        XCTAssertNil(store.string(forKey: "missing"))
        XCTAssertNil(store.data(forKey: "missing"))
    }

    func testKeysAreIsolated() {
        let store = InMemoryUserDefaultsStore()
        store.set("a", forKey: "k1")
        store.set("b", forKey: "k2")
        XCTAssertEqual(store.string(forKey: "k1"), "a")
        XCTAssertEqual(store.string(forKey: "k2"), "b")
    }
}

final class UserDefaultsStoreSuiteTests: XCTestCase {

    private let suite = "com.edge.rum.tests.\(UUID().uuidString)"

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testRealUserDefaultsSuiteRoundTrip() {
        let store = UserDefaultsStore(suiteName: suite)
        XCTAssertFalse(store.usingFallback, "test suite should succeed")
        store.set("hello", forKey: "k")
        XCTAssertEqual(store.string(forKey: "k"), "hello")
    }

    func testStoresAreIndependentAcrossInstances() {
        let storeA = UserDefaultsStore(suiteName: suite)
        storeA.set("persisted", forKey: "key")

        let storeB = UserDefaultsStore(suiteName: suite)
        XCTAssertEqual(storeB.string(forKey: "key"), "persisted")
    }
}

final class EdgeRumStorageConstantsTests: XCTestCase {

    func testSessionSuiteNameIsStable() {
        XCTAssertEqual(EdgeRumStorage.sessionSuite, "com.edge.rum.session")
    }

    func testKeychainServiceIsStable() {
        XCTAssertEqual(EdgeRumStorage.keychainService, "com.edge.rum.identity")
    }

    func testKeyNamesAreStable() {
        XCTAssertEqual(EdgeRumStorage.keyDeviceId, "edge.rum.device.id")
        XCTAssertEqual(EdgeRumStorage.keyDeviceIdFallback, "edge.rum.device.id.fallback")
        XCTAssertEqual(EdgeRumStorage.keyUserId, "edge.rum.user.id")
        XCTAssertEqual(EdgeRumStorage.keySessionState, "edge.rum.session.state")
    }
}
