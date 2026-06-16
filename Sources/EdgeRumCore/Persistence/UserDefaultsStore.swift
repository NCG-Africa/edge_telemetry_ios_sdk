// Sources/EdgeRumCore/Persistence/UserDefaultsStore.swift
//
// Thin protocol-backed wrapper around `UserDefaults` so the
// IdentityProvider, UserDefaultsSessionStore, and any future
// preference reader share a single seam that tests can fake.
//
// Production callers use `UserDefaultsStore(suiteName:)` against
// the shared suite name `EdgeRumStorage.sessionSuite` ("com.edge.rum.session").
//
// The suite is created lazily on first access; if the suite cannot be
// created (sandboxed test environment, permissions issue), we fall
// back to `UserDefaults.standard` so the SDK still functions. The
// fallback is observable via `usingFallback` so the IdentityProvider
// can emit a debug log when it kicks in.
//
// Refs: CLAUDE.md "Session and ID rules → Storage"; PLAN-iOS.md §F4/T4.2.
//

import Foundation

public protocol UserDefaultsStoring: Sendable {
    func string(forKey key: String) -> String?
    func data(forKey key: String) -> Data?
    func set(_ value: String, forKey key: String)
    func set(_ value: Data, forKey key: String)
    func removeObject(forKey key: String)
}

public enum EdgeRumStorage {
    /// UserDefaults suite where session triple + user.id +
    /// Keychain-fallback device.id live.
    public static let sessionSuite = "com.edge.rum.session"

    /// Keychain service name used for `device.id`.
    public static let keychainService = "com.edge.rum.identity"

    /// Keychain account name used for `device.id`.
    public static let keychainAccountDeviceId = "device.id"

    /// UserDefaults keys.
    public static let keyDeviceId = "edge.rum.device.id"
    public static let keyDeviceIdFallback = "edge.rum.device.id.fallback"
    public static let keyUserId = "edge.rum.user.id"
    public static let keySessionState = "edge.rum.session.state"
}

public final class UserDefaultsStore: UserDefaultsStoring, @unchecked Sendable {

    private let defaults: UserDefaults
    public let usingFallback: Bool

    public init(suiteName: String) {
        if let suite = UserDefaults(suiteName: suiteName) {
            self.defaults = suite
            self.usingFallback = false
        } else {
            self.defaults = .standard
            self.usingFallback = true
        }
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        self.usingFallback = false
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    public func set(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    public func set(_ value: Data, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    public func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}

/// In-memory `UserDefaultsStoring` for tests. Deterministic, no disk
/// side-effects across test runs.
public final class InMemoryUserDefaultsStore: UserDefaultsStoring, @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [String: Any] = [:]

    public init() {}

    public func string(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key] as? String
    }

    public func data(forKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storage[key] as? Data
    }

    public func set(_ value: String, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }

    public func set(_ value: Data, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }

    public func removeObject(forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }
}
