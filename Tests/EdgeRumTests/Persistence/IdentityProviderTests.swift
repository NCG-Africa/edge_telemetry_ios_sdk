// Tests/EdgeRumTests/Persistence/IdentityProviderTests.swift
//
// Covers issue #42 (T4.2) acceptance: reinstalling the host app on
// the simulator regenerates `device.id`. We simulate that by clearing
// the Keychain row and re-resolving — the new id must differ and
// must match the device regex.

import XCTest
@testable import EdgeRumCore

final class IdentityProviderTests: XCTestCase {

    // MARK: Helpers

    private func makeProvider(
        keychain: KeychainStoring? = nil,
        defaults: UserDefaultsStoring? = nil,
        clock: Clock? = nil,
        randomBytes: (() -> Data)? = nil
    ) -> (IdentityProvider, InMemoryKeychainStore, InMemoryUserDefaultsStore, FixedClock) {
        let kc = (keychain as? InMemoryKeychainStore) ?? InMemoryKeychainStore()
        let ud = (defaults as? InMemoryUserDefaultsStore) ?? InMemoryUserDefaultsStore()
        let fc = (clock as? FixedClock) ?? FixedClock(Date(timeIntervalSince1970: 1_717_234_876.123))
        let rb = randomBytes ?? { Data([0xa1, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6, 0x07, 0x18]) }
        let provider = IdentityProvider(
            keychain: kc,
            defaults: ud,
            clock: fc,
            randomBytes: rb
        )
        return (provider, kc, ud, fc)
    }

    // MARK: Generation

    func testFirstResolveGeneratesAndPersistsBothIds() throws {
        let (provider, keychain, defaults, _) = makeProvider()
        let snapshot = provider.resolve()

        XCTAssertTrue(IdentityFormat.isValid(snapshot.deviceId, kind: .device))
        XCTAssertTrue(IdentityFormat.isValid(snapshot.userId, kind: .user))
        XCTAssertFalse(snapshot.deviceIdFromFallback)

        // Persisted to the right slots.
        let persistedDevice = try keychain.read(
            service: EdgeRumStorage.keychainService,
            account: EdgeRumStorage.keychainAccountDeviceId
        )
        XCTAssertEqual(persistedDevice, snapshot.deviceId)
        XCTAssertEqual(defaults.string(forKey: EdgeRumStorage.keyUserId), snapshot.userId)
        XCTAssertNil(defaults.string(forKey: EdgeRumStorage.keyDeviceIdFallback))
    }

    func testResolveIsIdempotent() {
        let (provider, _, _, _) = makeProvider()
        let first = provider.resolve()
        let second = provider.resolve()
        XCTAssertEqual(first.deviceId, second.deviceId)
        XCTAssertEqual(first.userId, second.userId)
    }

    // MARK: Reinstall — Keychain cleared

    func testClearingKeychainRegeneratesDeviceId() throws {
        let (provider, keychain, _, _) = makeProvider()
        let original = provider.resolve().deviceId

        // Simulate uninstall + reinstall — Keychain row cleared by
        // iOS on most modern installs. UserDefaults survives, so
        // user.id should persist; only device.id should rotate.
        try keychain.delete(
            service: EdgeRumStorage.keychainService,
            account: EdgeRumStorage.keychainAccountDeviceId
        )

        // Use a new provider with a different random seed so the new
        // id is observably different from the old one.
        let differentRandom: () -> Data = {
            Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])
        }
        let fresh = IdentityProvider(
            keychain: keychain,
            defaults: InMemoryUserDefaultsStore(),
            clock: FixedClock(Date(timeIntervalSince1970: 1_717_234_999.000)),
            randomBytes: differentRandom
        )
        let regenerated = fresh.resolve().deviceId

        XCTAssertNotEqual(regenerated, original)
        XCTAssertTrue(IdentityFormat.isValid(regenerated, kind: .device))
    }

    // MARK: Keychain failure → UserDefaults fallback

    func testKeychainFailureFallsBackToUserDefaults() {
        let failingKeychain = InMemoryKeychainStore(failure: .unexpectedStatus(-25300))
        let defaults = InMemoryUserDefaultsStore()
        let provider = IdentityProvider(
            keychain: failingKeychain,
            defaults: defaults,
            clock: FixedClock(Date(timeIntervalSince1970: 1_717_234_876.123)),
            randomBytes: { Data([0xa1, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6, 0x07, 0x18]) }
        )

        let snapshot = provider.resolve()
        XCTAssertTrue(snapshot.deviceIdFromFallback)
        XCTAssertEqual(
            defaults.string(forKey: EdgeRumStorage.keyDeviceIdFallback),
            snapshot.deviceId
        )
    }

    func testFallbackPersistsAcrossResolves() {
        let failingKeychain = InMemoryKeychainStore(failure: .unexpectedStatus(-25300))
        let defaults = InMemoryUserDefaultsStore()
        let provider = IdentityProvider(
            keychain: failingKeychain,
            defaults: defaults
        )

        let first = provider.resolve()
        let second = provider.resolve()
        XCTAssertEqual(first.deviceId, second.deviceId)
        XCTAssertTrue(second.deviceIdFromFallback)
    }

    // MARK: Malformed persisted values regenerate

    func testMalformedDeviceIdInKeychainTriggersRegeneration() throws {
        let keychain = InMemoryKeychainStore()
        try keychain.write(
            "device_NOT_AN_EPOCH_aaaaaaaaaaaaaaaa_ios",
            service: EdgeRumStorage.keychainService,
            account: EdgeRumStorage.keychainAccountDeviceId
        )
        let provider = IdentityProvider(
            keychain: keychain,
            defaults: InMemoryUserDefaultsStore()
        )
        let snapshot = provider.resolve()
        XCTAssertTrue(IdentityFormat.isValid(snapshot.deviceId, kind: .device))
        XCTAssertNotEqual(snapshot.deviceId, "device_NOT_AN_EPOCH_aaaaaaaaaaaaaaaa_ios")

        // The Keychain slot should now hold the new value too.
        let persisted = try keychain.read(
            service: EdgeRumStorage.keychainService,
            account: EdgeRumStorage.keychainAccountDeviceId
        )
        XCTAssertEqual(persisted, snapshot.deviceId)
    }

    func testMalformedUserIdInDefaultsTriggersRegeneration() {
        let defaults = InMemoryUserDefaultsStore()
        defaults.set("user_NOT_VALID", forKey: EdgeRumStorage.keyUserId)
        let provider = IdentityProvider(
            keychain: InMemoryKeychainStore(),
            defaults: defaults
        )
        let snapshot = provider.resolve()
        XCTAssertTrue(IdentityFormat.isValid(snapshot.userId, kind: .user))
        XCTAssertNotEqual(snapshot.userId, "user_NOT_VALID")
        XCTAssertEqual(defaults.string(forKey: EdgeRumStorage.keyUserId), snapshot.userId)
    }

    func testFallbackClearsWhenKeychainStartsWorking() throws {
        // Start with fallback in place.
        let failing = InMemoryKeychainStore(failure: .unexpectedStatus(-25300))
        let defaults = InMemoryUserDefaultsStore()
        let provider = IdentityProvider(keychain: failing, defaults: defaults)
        _ = provider.resolve()
        XCTAssertNotNil(defaults.string(forKey: EdgeRumStorage.keyDeviceIdFallback))

        // Switch to a working keychain by recovering the in-memory one.
        failing.failure = nil
        let recovered = IdentityProvider(keychain: failing, defaults: defaults)
        let snapshot = recovered.regenerateDeviceId()
        XCTAssertTrue(IdentityFormat.isValid(snapshot, kind: .device))
        XCTAssertNil(defaults.string(forKey: EdgeRumStorage.keyDeviceIdFallback))
    }

    // MARK: Explicit regenerate hooks

    func testRegenerateDeviceIdReplacesPersistedValue() throws {
        let keychain = InMemoryKeychainStore()
        let defaults = InMemoryUserDefaultsStore()
        let counter = CountingRandomBytes()
        let provider = IdentityProvider(
            keychain: keychain,
            defaults: defaults,
            clock: FixedClock(Date(timeIntervalSince1970: 1_717_234_876.123)),
            randomBytes: counter.next
        )
        let first = provider.resolve().deviceId
        let regenerated = provider.regenerateDeviceId()
        XCTAssertNotEqual(first, regenerated)
        let persisted = try keychain.read(
            service: EdgeRumStorage.keychainService,
            account: EdgeRumStorage.keychainAccountDeviceId
        )
        XCTAssertEqual(persisted, regenerated)
    }

    func testRegenerateUserIdReplacesPersistedValue() {
        let keychain = InMemoryKeychainStore()
        let defaults = InMemoryUserDefaultsStore()
        let counter = CountingRandomBytes()
        let provider = IdentityProvider(
            keychain: keychain,
            defaults: defaults,
            clock: FixedClock(Date(timeIntervalSince1970: 1_717_234_876.123)),
            randomBytes: counter.next
        )
        let first = provider.resolve().userId
        let regenerated = provider.regenerateUserId()
        XCTAssertNotEqual(first, regenerated)
        XCTAssertEqual(defaults.string(forKey: EdgeRumStorage.keyUserId), regenerated)
    }
}

/// Deterministic counter-incrementing random bytes — produces a
/// different 8-byte sequence on each call so the byte→hex segment of
/// generated IDs is observably different across calls.
final class CountingRandomBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var counter: UInt64 = 0

    func next() -> Data {
        lock.lock(); defer { lock.unlock() }
        counter &+= 1
        var value = counter.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
