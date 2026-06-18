// Tests/EdgeRumTests/Persistence/KeychainStoreTests.swift
//
// Verifies the in-memory fake (used widely by the IdentityProvider
// tests) AND smoke-tests the real `KeychainStore` against the
// simulator keychain. The simulator path is gated on availability —
// `swift test` on the macOS host can technically hit the real keychain
// but values may leak across runs, so we use a unique service per
// test and clean up in tearDown.

import XCTest
@testable import EdgeRumCore

final class InMemoryKeychainStoreTests: XCTestCase {

    func testReadReturnsNilForMissingKey() throws {
        let store = InMemoryKeychainStore()
        let value = try store.read(service: "svc", account: "acct")
        XCTAssertNil(value)
    }

    func testWriteThenReadRoundTrips() throws {
        let store = InMemoryKeychainStore()
        try store.write("hello", service: "svc", account: "acct")
        XCTAssertEqual(try store.read(service: "svc", account: "acct"), "hello")
    }

    func testWriteReplacesExistingValue() throws {
        let store = InMemoryKeychainStore()
        try store.write("first", service: "svc", account: "acct")
        try store.write("second", service: "svc", account: "acct")
        XCTAssertEqual(try store.read(service: "svc", account: "acct"), "second")
    }

    func testDeleteRemovesValue() throws {
        let store = InMemoryKeychainStore()
        try store.write("hello", service: "svc", account: "acct")
        try store.delete(service: "svc", account: "acct")
        XCTAssertNil(try store.read(service: "svc", account: "acct"))
    }

    func testDeleteOnMissingKeyIsNoOp() throws {
        let store = InMemoryKeychainStore()
        XCTAssertNoThrow(try store.delete(service: "svc", account: "acct"))
    }

    func testServiceAndAccountAreIsolated() throws {
        let store = InMemoryKeychainStore()
        try store.write("a", service: "svc1", account: "acct")
        try store.write("b", service: "svc2", account: "acct")
        try store.write("c", service: "svc1", account: "other")

        XCTAssertEqual(try store.read(service: "svc1", account: "acct"), "a")
        XCTAssertEqual(try store.read(service: "svc2", account: "acct"), "b")
        XCTAssertEqual(try store.read(service: "svc1", account: "other"), "c")
    }

    func testFailureInjectionThrowsOnAllOperations() {
        let store = InMemoryKeychainStore(failure: .unexpectedStatus(-25300))
        XCTAssertThrowsError(try store.read(service: "svc", account: "acct"))
        XCTAssertThrowsError(try store.write("x", service: "svc", account: "acct"))
        XCTAssertThrowsError(try store.delete(service: "svc", account: "acct"))
    }
}

#if os(iOS)
/// Smoke tests against the real keychain. Only run on iOS — macOS
/// SwiftPM test runs would need an explicit entitlement to use the
/// generic password class predictably.
final class RealKeychainStoreTests: XCTestCase {

    private let service = "com.edge.rum.tests.keychain.\(UUID().uuidString)"
    private let account = "test"

    /// XCTest bundles on the iOS Simulator run without the Keychain
    /// entitlement that real apps get; `SecItem*` returns
    /// `errSecMissingEntitlement` (-34018). These smoke tests still
    /// exercise the real `KeychainStore` on physical devices and in
    /// host-app contexts; on simulator we surface the limitation via
    /// `XCTSkip` so the matrix CI job stays green. Real-device perf
    /// lab covers the missing path.
    private static let missingEntitlementStatus: OSStatus = -34018

    private func skipIfMissingEntitlement(_ error: Error) throws {
        if let kc = error as? KeychainError,
           case let .unexpectedStatus(status) = kc,
           status == Self.missingEntitlementStatus {
            throw XCTSkip("iOS Simulator XCTest bundle lacks the Keychain entitlement — KeychainStore covered by manual real-device QA")
        }
    }

    override func tearDownWithError() throws {
        do {
            try KeychainStore().delete(service: service, account: account)
        } catch {
            try skipIfMissingEntitlement(error)
            throw error
        }
    }

    func testWriteThenReadRoundTripsAgainstRealKeychain() throws {
        let store = KeychainStore()
        do {
            try store.write("device_1717234876123_a1b2c3d4e5f60718_ios",
                            service: service, account: account)
        } catch {
            try skipIfMissingEntitlement(error)
            throw error
        }
        let read = try store.read(service: service, account: account)
        XCTAssertEqual(read, "device_1717234876123_a1b2c3d4e5f60718_ios")
    }

    func testDeleteRemovesValue() throws {
        let store = KeychainStore()
        do {
            try store.write("payload", service: service, account: account)
        } catch {
            try skipIfMissingEntitlement(error)
            throw error
        }
        try store.delete(service: service, account: account)
        XCTAssertNil(try store.read(service: service, account: account))
    }
}
#endif
