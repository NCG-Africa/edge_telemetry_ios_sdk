// Sources/EdgeRumCore/Persistence/IdentityFormat.swift
//
// Compiled regex validators for the three persisted identity strings.
// F4 calls `validate(persisted:)` after loading a value from
// Keychain / UserDefaults — any mismatch (corrupt data, an older
// format, a manually edited value) regenerates the id transparently
// so the wire never carries a malformed identifier.
//
// Format rules (CLAUDE.md "Session and ID rules"):
//   device.id   "device_<epochMs>_<16 hex>_ios"
//   session.id  "session_<epochMs>_<16 hex>_ios"
//   user.id     "user_<epochMs>_<16 hex>"        (no `_ios` suffix)
//
// The 16 hex chars come from `SecRandomCopyBytes(8)` formatted `%02x`.
// `UUID()` is NOT used — its 128-bit hex section breaks the regex
// the backend dispatcher relies on for cross-platform routing.
//
// Refs: CLAUDE.md "Session and ID rules"; PLAN-iOS.md §F4/T4.1.
//

import Foundation

public enum IdentityKind: Sendable, Hashable {
    case device
    case session
    case user
}

public enum IdentityFormat {

    public static let devicePattern = #"^device_\d+_[0-9a-f]{16}_ios$"#
    public static let sessionPattern = #"^session_\d+_[0-9a-f]{16}_ios$"#
    public static let userPattern = #"^user_\d+_[0-9a-f]{16}$"#

    public static func pattern(for kind: IdentityKind) -> String {
        switch kind {
        case .device: return devicePattern
        case .session: return sessionPattern
        case .user: return userPattern
        }
    }

    /// Returns `true` when `value` matches the regex for `kind`. Used
    /// by the IdentityProvider load path to decide whether a persisted
    /// id is still trustworthy.
    public static func isValid(_ value: String, kind: IdentityKind) -> Bool {
        let pattern = pattern(for: kind)
        guard let regex = compiledRegex(for: pattern) else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }

    /// Convenience: returns `value` if valid, otherwise `nil`. Lets
    /// callers `??` straight into a fresh generator.
    public static func validate(_ value: String, kind: IdentityKind) -> String? {
        isValid(value, kind: kind) ? value : nil
    }

    // MARK: Private

    private static let regexCache = RegexCache()

    private static func compiledRegex(for pattern: String) -> NSRegularExpression? {
        regexCache.regex(for: pattern)
    }

    private final class RegexCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [String: NSRegularExpression] = [:]

        func regex(for pattern: String) -> NSRegularExpression? {
            lock.lock(); defer { lock.unlock() }
            if let cached = cache[pattern] { return cached }
            guard let compiled = try? NSRegularExpression(pattern: pattern) else {
                return nil
            }
            cache[pattern] = compiled
            return compiled
        }
    }
}
