// Sources/EdgeRumCore/Persistence/IdentityProvider.swift
//
// Resolves the two SDK-owned, persisted identity strings:
//
//   - `device.id` lives in Keychain
//     (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). If the
//     Keychain write fails (rare, but observed on simulators with
//     locked entitlements), we fall back to the same UserDefaults
//     suite as `user.id`/`session.id`, persisting under a separate
//     "fallback" key so we can tell at read time whether the value
//     came from Keychain or from the fallback.
//
//   - `user.id` lives in the UserDefaults suite
//     `com.edge.rum.session`. iCloud-sync is intentionally not enabled.
//
// Each persisted value is validated against the format regex from
// `IdentityFormat` on load. A mismatch (corrupt, manually edited, or
// pre-format-change value) triggers a transparent regeneration —
// callers see the new value, the old value is overwritten.
//
// Refs: CLAUDE.md "Session and ID rules → Storage"; PLAN-iOS.md
//       §8.2 / §F4/T4.2.
//

import Foundation
import os.log

public struct IdentitySnapshot: Sendable, Hashable {
    public let deviceId: String
    public let userId: String

    /// `true` when `deviceId` came from the UserDefaults fallback
    /// (Keychain write failed). Exposed so the Recorder can emit one
    /// diagnostic log line at startup in debug mode.
    public let deviceIdFromFallback: Bool

    public init(deviceId: String, userId: String, deviceIdFromFallback: Bool) {
        self.deviceId = deviceId
        self.userId = userId
        self.deviceIdFromFallback = deviceIdFromFallback
    }
}

public final class IdentityProvider: @unchecked Sendable {

    private let keychain: KeychainStoring
    private let defaults: UserDefaultsStoring
    private let clock: Clock
    private let randomBytes: () -> Data
    private let log: OSLog

    private let lock = NSLock()

    public init(
        keychain: KeychainStoring = KeychainStore(),
        defaults: UserDefaultsStoring = UserDefaultsStore(suiteName: EdgeRumStorage.sessionSuite),
        clock: Clock = SystemClock(),
        randomBytes: @escaping () -> Data = SessionManager.secureRandomBytes,
        log: OSLog = OSLog(subsystem: "com.edge.rum", category: "IdentityProvider")
    ) {
        self.keychain = keychain
        self.defaults = defaults
        self.clock = clock
        self.randomBytes = randomBytes
        self.log = log
    }

    /// Returns the resolved snapshot, creating + persisting any
    /// missing or invalid identifier. Idempotent — calling twice
    /// returns the same values.
    public func resolve() -> IdentitySnapshot {
        lock.lock(); defer { lock.unlock() }
        let (deviceId, fromFallback) = resolveDeviceId()
        let userId = resolveUserId()
        return IdentitySnapshot(
            deviceId: deviceId,
            userId: userId,
            deviceIdFromFallback: fromFallback
        )
    }

    /// Force-regenerate the `device.id` value. Intended for tests and
    /// for the unlikely "user requested a reset" host-app code path.
    /// Returns the freshly-generated id.
    @discardableResult
    public func regenerateDeviceId() -> String {
        lock.lock(); defer { lock.unlock() }
        let fresh = DeviceIdentitySnapshot.newId(at: clock.now, randomBytes: randomBytes)
        persistDeviceId(fresh)
        return fresh
    }

    /// Force-regenerate the `user.id` value.
    @discardableResult
    public func regenerateUserId() -> String {
        lock.lock(); defer { lock.unlock() }
        let fresh = UserContextSnapshot.newAnonymousId(at: clock.now, randomBytes: randomBytes)
        defaults.set(fresh, forKey: EdgeRumStorage.keyUserId)
        return fresh
    }

    // MARK: device.id

    private func resolveDeviceId() -> (id: String, fromFallback: Bool) {
        if let valid = readValidDeviceIdFromKeychain() {
            return (valid, false)
        }
        if let valid = readValidDeviceIdFromFallback() {
            return (valid, true)
        }
        let fresh = DeviceIdentitySnapshot.newId(at: clock.now, randomBytes: randomBytes)
        let usedFallback = persistDeviceId(fresh)
        return (fresh, usedFallback)
    }

    private func readValidDeviceIdFromKeychain() -> String? {
        do {
            guard let raw = try keychain.read(
                service: EdgeRumStorage.keychainService,
                account: EdgeRumStorage.keychainAccountDeviceId
            ) else { return nil }
            return IdentityFormat.validate(raw, kind: .device)
        } catch {
            os_log(
                "IdentityProvider keychain read failed: %{public}@",
                log: log,
                type: .info,
                String(describing: error)
            )
            return nil
        }
    }

    private func readValidDeviceIdFromFallback() -> String? {
        guard let raw = defaults.string(forKey: EdgeRumStorage.keyDeviceIdFallback) else {
            return nil
        }
        return IdentityFormat.validate(raw, kind: .device)
    }

    /// Persists `id` to Keychain. On Keychain failure, persists to the
    /// UserDefaults fallback key. Returns `true` if the fallback was
    /// used.
    @discardableResult
    private func persistDeviceId(_ id: String) -> Bool {
        do {
            try keychain.write(
                id,
                service: EdgeRumStorage.keychainService,
                account: EdgeRumStorage.keychainAccountDeviceId
            )
            // Clear any prior fallback value so the next launch picks
            // up the Keychain copy.
            defaults.removeObject(forKey: EdgeRumStorage.keyDeviceIdFallback)
            return false
        } catch {
            os_log(
                "IdentityProvider keychain write failed; falling back to UserDefaults: %{public}@",
                log: log,
                type: .info,
                String(describing: error)
            )
            defaults.set(id, forKey: EdgeRumStorage.keyDeviceIdFallback)
            return true
        }
    }

    // MARK: user.id

    private func resolveUserId() -> String {
        if let existing = defaults.string(forKey: EdgeRumStorage.keyUserId),
           let valid = IdentityFormat.validate(existing, kind: .user) {
            return valid
        }
        let fresh = UserContextSnapshot.newAnonymousId(at: clock.now, randomBytes: randomBytes)
        defaults.set(fresh, forKey: EdgeRumStorage.keyUserId)
        return fresh
    }
}
