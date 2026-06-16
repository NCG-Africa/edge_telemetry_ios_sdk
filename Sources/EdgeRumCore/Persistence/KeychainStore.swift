// Sources/EdgeRumCore/Persistence/KeychainStore.swift
//
// Thin wrapper around the Security framework for storing the single
// `device.id` value. Designed for replace-write semantics — the
// IdentityProvider only ever stores one item per service so we use a
// `kSecClassGenericPassword` row keyed on (service, account).
//
// Accessibility: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
// — survives between launches once the device is unlocked once, is not
// included in iCloud backup, and does not migrate to another device.
// This matches CLAUDE.md "Session and ID rules → Storage".
//
// We expose a `KeychainStoring` protocol so IdentityProvider tests can
// inject a deterministic in-memory fake (and trigger the "Keychain
// write failed" fallback path without simulating a real SecItemAdd
// error).
//
// Refs: CLAUDE.md "Session and ID rules → Storage";
//       PLAN-iOS.md §8.2 / §F4/T4.2.
//

import Foundation
import Security

public protocol KeychainStoring: Sendable {
    /// Returns the persisted string for the (service, account), or
    /// `nil` if the slot is empty. Throws on unexpected `OSStatus`.
    func read(service: String, account: String) throws -> String?

    /// Atomically replaces the value at (service, account). Adds the
    /// row if missing; updates it otherwise. Throws on `OSStatus`
    /// errors other than `errSecItemNotFound`.
    func write(_ value: String, service: String, account: String) throws

    /// Removes the row at (service, account). Returns silently when
    /// the row is absent — that's the desired idempotent semantic.
    func delete(service: String, account: String) throws
}

public enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case unexpectedData
}

/// Production `KeychainStoring` backed by `SecItem*`. Marked `final`
/// because there is no scenario in which we want to subclass this —
/// callers should inject a different `KeychainStoring` conformer
/// instead.
///
/// `@unchecked Sendable` because the only stored property is a
/// `CFString` constant pointer (one of the immutable
/// `kSecAttrAccessible*` symbols) — Apple ships them as global
/// constants and they are safe to read from any thread.
public final class KeychainStore: KeychainStoring, @unchecked Sendable {

    private let accessibility: CFString

    public init(accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) {
        self.accessibility = accessibility
    }

    public func read(service: String, account: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedData
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func write(_ value: String, service: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]

        let updateAttributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: accessibility
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            break
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData] = data
        addQuery[kSecAttrAccessible] = accessibility

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    public func delete(service: String, account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

/// In-memory `KeychainStoring` for tests. Optional failure injection
/// so we can exercise the IdentityProvider's UserDefaults fallback
/// without needing a real Keychain failure on the simulator.
public final class InMemoryKeychainStore: KeychainStoring, @unchecked Sendable {

    public struct Key: Hashable, Sendable {
        public let service: String
        public let account: String
        public init(service: String, account: String) {
            self.service = service
            self.account = account
        }
    }

    private let lock = NSLock()
    private var values: [Key: String] = [:]

    /// When non-nil, every call throws this error. Used by tests to
    /// drive the IdentityProvider into its UserDefaults fallback
    /// branch.
    public var failure: KeychainError?

    public init(failure: KeychainError? = nil) {
        self.failure = failure
    }

    public func read(service: String, account: String) throws -> String? {
        if let failure { throw failure }
        lock.lock(); defer { lock.unlock() }
        return values[Key(service: service, account: account)]
    }

    public func write(_ value: String, service: String, account: String) throws {
        if let failure { throw failure }
        lock.lock(); defer { lock.unlock() }
        values[Key(service: service, account: account)] = value
    }

    public func delete(service: String, account: String) throws {
        if let failure { throw failure }
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: Key(service: service, account: account))
    }
}
